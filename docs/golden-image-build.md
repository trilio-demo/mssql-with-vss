# Golden Image Build — Bake-In Brief

A focused checklist for building a **Windows Server 2022** golden image from
ISO so it drops cleanly into the lab's VM-prep flow. The point of building our
own image (vs. the stock engineering golden image) is to:

1. **Kill the 180-day evaluation clock** — install from a real ISO with a
   proper edition/key so there's no eval expiry → no KubeVirt restart loop →
   no `slmgr /rearm` dance (retires § 4f of `windows-vm-prep.md`).
2. **Bake in the services** so per-VM prep shrinks: QGA, virtio drivers, and
   OpenSSH Server all preinstalled (collapses § 4e's three SSH install paths).

This brief assumes you already have a working **image-capture pipeline**
(boot ISO → install → customize → `sysprep /generalize` → capture disk). It
documents *what to add to that process* and the *capture-time gotchas* — not
how to stand up the pipeline itself.

> Pairs with [`windows-vm-prep.md`](windows-vm-prep.md). When this image is
> live and verified, § 4e collapses to "sshd preinstalled — just upload your
> key" and § 4f (eval/rearm) disappears.

---

## What this image must contain (the bake list)

Do all of this in the capture VM **before** the final sysprep, in roughly this
order. Each block is idempotent enough to re-run if your pipeline replays.

### 1. Edition / activation — solves the eval clock

Install from the ISO as a **licensed (non-eval) edition**, or convert during
build:

```powershell
# Confirm what you booted
DISM /online /Get-CurrentEdition          # want: ServerStandard / ServerDatacenter, NOT *Eval

# If the ISO gave you an Eval edition, convert (GVLK shown = Datacenter KMS):
DISM /online /Set-Edition:ServerDatacenter /ProductKey:WX4NM-KYWYW-QJJR4-XV3QB-6VM33 /AcceptEula
# Reboots automatically; re-check Get-CurrentEdition after.
```

> On a **fresh-from-ISO** install the DISM servicing stack is healthy, so this
> conversion actually works — unlike the old engineering golden image where
> DISM was broken and edition conversion silently no-op'd. That broken-DISM
> behavior is the whole reason we're rebuilding from ISO.

If you have a KMS host or MAK key for the lab, activate against it now so
clones come up Licensed.

### 2. virtio-win drivers — required for KubeVirt

The VM won't see its disk/NIC correctly on OCPv without these. Mount the
`virtio-win` ISO and install the full driver set + the guest tools:

```powershell
# E: = mounted virtio-win ISO
pnputil /add-driver E:\*.inf /subdirs /install        # all virtio drivers
# or run the virtio-win guest-tools MSI for drivers + tray apps
Start-Process msiexec -Wait -ArgumentList '/i E:\virtio-win-gt-x64.msi /qn /norestart'
```

### 3. QEMU Guest Agent (QGA) — load-bearing for the whole VSS lab

**Do not skip or forget this.** QGA is what Trilio signals to drive Windows
VSS freeze/thaw. No QGA → no application-consistent backup → the lab's entire
premise fails. SSH is a convenience; QGA is the point.

```powershell
# From the virtio-win ISO guest-agent folder:
Start-Process msiexec -Wait -ArgumentList '/i E:\guest-agent\qemu-ga-x86_64.msi /qn /norestart'
Get-Service QEMU-GA      # expect Running / Automatic after install
```

### 4. OpenSSH Server — preinstall so per-VM prep is one step

On a healthy fresh ISO build, the capability install works (the
"capability-lies / binary-never-lands" failure was an artifact of the broken
golden image, not OpenSSH):

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Test-Path 'C:\Windows\System32\OpenSSH\sshd.exe'      # MUST be True

# Register the service and set it to start automatically on every clone
powershell.exe -ExecutionPolicy Bypass -File 'C:\Windows\System32\OpenSSH\install-sshd.ps1'
Set-Service -Name sshd -StartupType Automatic

# Inbound TCP/22 firewall rule
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22

# Make PowerShell the default SSH shell (so sessions land in PS, not cmd)
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -PropertyType String -Force
```

> **Do NOT `Start-Service sshd` during the build** (or if you do, see the
> host-key cleanup in the capture gotchas below). Set it Automatic and let it
> first-start on each clone — that's what gives every clone unique host keys.

---

## Capture-time gotchas (read before sysprep)

These are the things that bite a generalized image. Handle them in the window
between "bake list done" and "`sysprep /generalize`".

### Delete SSH host keys before generalize

If sshd ever started during the build, it generated host keys at
`C:\ProgramData\ssh\ssh_host_*`. Captured into the image, **every clone would
share the same host keys** — a security smell and a source of SSH
host-key-mismatch warnings on your workstation. Remove them; sshd regenerates
unique keys on each clone's first boot:

```powershell
Stop-Service sshd -ErrorAction SilentlyContinue
Remove-Item 'C:\ProgramData\ssh\ssh_host_*' -Force -ErrorAction SilentlyContinue
```

### Do NOT bake `authorized_keys` into the image

If this image is shared, a baked-in `administrators_authorized_keys` means one
private key unlocks every clone. Leave key upload as a **per-clone post step**
(it stays in `windows-vm-prep.md` § 4e key-auth block). Password auth set via
the unattend works clone-wide and is fine for the lab.

### Protect the rearm count

In your generalize-pass unattend, keep `<SkipRearm>1</SkipRearm>` so a future
sysprep re-run doesn't burn the limited eval-rearm count. (Moot once you're on
a properly licensed edition per step 1, but harmless and matches the prep
doc's unattend.)

### Sysprep generalize + OOBE + shutdown

Standard capture invocation:

```powershell
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /unattend:C:\path\to\unattend.xml
```

The per-VM unattend in [`unattend.xml`](unattend.xml) handles the
*specialize/oobeSystem* passes at clone time (auto-logon, RDP enable, data-disk
init). Your **build-time** generalize unattend is separate and only needs the
`generalize` pass + `<SkipRearm>`.

---

## Post-build verification (on a test clone, before blessing the image)

Provision one VM from the new image via `windows-vm-prep.md` and confirm:

```powershell
DISM /online /Get-CurrentEdition          # ServerStandard/Datacenter, NOT *Eval
slmgr /xpr                                 # Licensed (or KMS grace), NOT Notification mode
Get-Service QEMU-GA                        # Running / Automatic
Get-Service sshd                           # Running / Automatic
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'   # Enabled
```

Also confirm from your workstation that **each** clone presents a *different*
SSH host key (i.e. host keys are not shared) — connect to two clones and check
they don't collide in `known_hosts`.

---

## What this retires in `windows-vm-prep.md`

Once this image is live and the test clone passes:

- **§ 4e (Install OpenSSH Server)** → shrinks to: "sshd is preinstalled and
  Automatic; upload your public key (key-auth block) if you want key login."
  The three install paths (capability / GitHub zip / RDP drag-and-drop) go
  away.
- **§ 4f (Verify edition conversion / rearm)** → removed entirely; the image
  is licensed, no eval clock, no restart loop.
- **§ 4a (Verify QGA)** stays — still worth a one-line confirmation, but it
  should always pass now.

Hold those prep-doc edits until this image exists and the test clone is
verified. Don't edit the doc against an image that isn't built yet.
