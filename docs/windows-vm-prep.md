# Windows VM Prep — Reference Guide

Standalone reference for preparing a Windows Server 2022 VM on OpenShift
Virtualization to host MS SQL Server for the Trilio-VSS lab. Designed to be
reused across OpenShift clusters and storage backends.

## Goal

A fresh Windows Server **2022** VM in a fresh namespace on your OCPv cluster,
cloned from a Windows Server 2022 golden image, with:

- A separate data disk (`D:`) for SQL data files (clean FLR story).
- **QEMU Guest Agent (QGA)** running — what Trilio signals to drive Windows VSS.
- **RDP (3389)** and **OpenSSH Server (22)** both up automatically on first
  boot, reachable from your workstation.
- **MS SQL Server Developer Edition** installed, with the
  **`SQLWriter`** service running.

## Prerequisites

- `oc` and **`virtctl`** CLI installed locally; logged in to your OpenShift
  cluster with permissions to write `DataVolume` resources in the
  `openshift-virtualization-os-images` namespace.
- A Windows Server 2022 golden image (`win2k22.img`) accessible locally.
  Most teams capture this from a generalized Sysprep-ready VM; a sample
  workflow is in the OpenShift Virtualization docs ("Creating a Windows VM
  using a golden image").
- Cluster prereqs:
  - OpenShift Virtualization (CNV) installed (`openshift-cnv` namespace).
  - Trilio operator installed (only needed once you get to the backup step).
  - A CSI **block-mode** StorageClass with **VolumeSnapshot** support
    (`is-default-virt-class=true` annotation makes the catalog flow easier).
    Tested against Portworx (`px-csi-replicated` / `px-csi-snapclass`) and
    TopoLVM (`lvms-topolvm-immediate`). Any CSI driver that supports
    `VolumeSnapshotClass` should work.
- VM egress requirements depend on which OpenSSH install path you pick in
  § 4e. The unattend itself doesn't need any internet egress. See § 4e for
  the three paths and their network requirements.

> ### ⚠️ Heads-up: Windows Server evaluation clock
>
> Most Windows Server 2022 golden images captured from a stock Microsoft ISO
> are **Datacenter Evaluation** builds. The 180-day eval clock starts when
> the image was captured, **not** when you boot a clone — so on a long-lived
> golden image the eval is usually already expired before you ever provision
> a VM from it. When eval expires, Windows force-reboots every ~60 minutes
> (visible as a KubeVirt restart loop under `runStrategy: Always`).
>
> The Sysprep unattend in § 3 includes a `<ProductKey>` (Server 2022
> Datacenter GVLK) + a DISM `Set-Edition` fallback that *attempts* to
> convert the install out of Eval. On a healthy golden image this works and
> the VM ends up as `ServerDatacenter` (KMS). On golden images with a
> **broken DISM servicing stack** (observed on the engineering image this
> project tested against), neither conversion fires and the VM stays on
> Eval — `slmgr /rearm` then buys a fresh grace period (the rearm cycle
> covers ~50 days of lab work; details in § 4f).

---

## 1. Upload the golden image as a DataVolume

Lands in the shared catalog namespace `openshift-virtualization-os-images`.
Subsequent VM clones land on the cluster's default virt StorageClass (the one
annotated `is-default-virt-class=true`).

Set two variables before running, then upload:

```bash
# Absolute path to the golden-image file on your workstation.
# Don't use `~` — tilde expansion is unreliable inside --image-path=~/...
IMG_PATH="$HOME/Downloads/win2k22.img"

# Block-mode, CSI snapshot-capable StorageClass on your cluster.
# Examples: px-csi-replicated (Portworx), lvms-topolvm-immediate (TopoLVM),
# ocs-storagecluster-ceph-rbd-virtualization (ODF).
STORAGE_CLASS="<your-block-storage-class>"

virtctl image-upload dv win2k22 \
  --size=20Gi \
  --image-path="$IMG_PATH" \
  --storage-class="$STORAGE_CLASS" \
  --access-mode=ReadWriteOnce \
  --volume-mode=block \
  --insecure \
  --namespace=openshift-virtualization-os-images
```

> **Why RWO block?** The image only needs to be written once (by the CDI
> upload pod), then read by clone operations. RWX isn't required. If the
> upload errors with "PVC not provisioned" against an RWX-only class, fall
> back to RWO — orphaned RWX-only storage classes (ODF on clusters without
> a `cephcluster` CRD, etc.) are a common cause.

CDI upload-proxy throughput is highly cluster-dependent — anywhere from
1 MB/s to 100 MB/s — so a 20 GiB upload can take minutes to hours. Track
progress with:

```bash
oc -n openshift-virtualization-os-images get dv win2k22 -w
```

## 2. Verify the catalog source is available

```
OpenShift Console → Virtualization → Catalog → Microsoft Windows Server 2022 VM
```

The tile should show **"Source available"**. If not, check:

```bash
oc -n openshift-virtualization-os-images get datavolume win2k22
oc -n openshift-virtualization-os-images get datasource win2k22
```

Both should be `Succeeded` / `Ready`.

## 3. Create the VM (fresh namespace + data disk + Sysprep)

```bash
oc new-project mssql-vss-lab
```

> ### ⚠️ Keep VM and disk names short — some storage backends derive volume names from them
>
> The catalog flow suggests **random `adjective-animal-NN` names** for both
> the VM (e.g. `win2k22-coffee-rat-79`) and any blank disk you add (e.g.
> `disk-amaranth-turkey-13`). Some CSI backends build their internal volume
> name by concatenating the namespace + VM name + disk name, then prepend
> their own prefix and append a random suffix — e.g. DRBD/LINSTOR produced:
>
> ```
> drbd-mssql-vss-lab-dv-win2k22-coffee-rat-79-disk-amaranth-turkey-13-a5vdrk
> ```
>
> That derived name has a hard length cap (**63 chars** on the backend we
> hit), and the auto-generated names overflow it — provisioning fails with a
> name-too-long error. (The provisioner is expected to handle long names
> natively in a future release; until then, treat the cap as a hard
> constraint.)
>
> **Fix: set short, explicit names.** This guide uses VM name **`mssql`** and
> data-disk name **`data`**. With namespace `mssql-vss-lab` that yields a
> derived name well under 63 chars. The fixed overhead the backend adds
> (`drbd-` prefix, `-dv-`, `-<random>` suffix ≈ 16 chars) plus the namespace
> leaves you ~34 chars for VM name + disk name combined — `mssql` + `data` is
> nowhere near it. **Do not accept the random `adjective-animal-NN` names.**

In the OCP Console:

1. **Virtualization → Catalog → Microsoft Windows Server 2022 VM** → *Create
   VirtualMachine*.
2. **VirtualMachine name:** overwrite the suggested random name with a short
   explicit one — **`mssql`** (see the length-cap callout above). This name
   propagates into the boot-disk and any add-on-disk volume names, so keeping
   it short here is what keeps the backend's derived name under 63 chars.
3. **Project / Namespace:** `mssql-vss-lab`.
4. **CPU / Memory:** **1 vCPU, 4 GB RAM** — the lean lab floor for Desktop
   Experience + SQL together (cap SQL with `sp_configure 'max server memory',
   2048` so it doesn't starve the GUI). Bump it here, or any time later in the
   UI, if you want more — no rebuild needed.
5. **Boot disk:** keep the catalog default source, but set its size to
   **32 GiB**. This is a hard floor, not a preference: Windows Server's
   documented minimum is 32 GB, and you can't provision a clone root smaller
   than the golden DV's virtual size (~20 Gi here) — CDI clones grow, never
   shrink below source.
6. **Data disk: this step is mandatory for SQL — don't skip.** **Add disk**
   (the form section is at the bottom of the page; easy to miss):
   - Name: **`data`** — type this explicitly; **don't leave the
     auto-suggested `disk-<adjective-animal-NN>`**, or the derived volume
     name overflows the 63-char cap (this is the field that bit us).
   - Source: Blank
   - Size: **10 GiB** — ample for `demo_db` (8 MB mdf/ldf) plus `.bak`/`.trn`
     artifacts; grow it if you load real data.
   - StorageClass: leave as default (picks up the cluster's default virt class).
   - Type: Disk (block / virtio).

   > If you forgot this and the VM is already created, you can add it
   > post-create: Console → your VM → **Disks** tab → **Add disk** with the
   > same fields. Stop/start the VM after attaching (some attach flows are
   > hot-add capable but it's cleaner to cycle). The unattend's
   > FirstLogonCommand only runs on first boot — if the disk wasn't present
   > then, you'll need to format it manually post-attach (the one-liner is
   > in § 4b's "No `D:` volume?" callout).
7. Click **Customize VirtualMachine**.
8. **Scripts** tab → **Sysprep** → paste the unattend XML below.
9. **Untick "Start this VirtualMachine after creation"** so you can adjust
   firmware before first boot (next step). Then click **Create VirtualMachine**.

### 3a. Disable Secure Boot before first boot

The catalog template defaults to UEFI **with Secure Boot on**. Many Windows
golden images carry a bootloader signing chain that doesn't match the keys
OVMF's secboot variant trusts — Secure Boot rejects it and the VM parks at
the TianoCore splash. Patch it off before starting.

```bash
# The explicit name you set in § 3 step 2. (If you let the catalog generate
# one anyway, grab it with:
#   VM=$(oc -n mssql-vss-lab get vm -o jsonpath='{.items[0].metadata.name}')
# — but a long generated name may have already failed provisioning. See the
# length-cap callout in § 3.)
VM=mssql

# Disable Secure Boot + SMM (KubeVirt couples them — must toggle together)
oc -n mssql-vss-lab patch vm "$VM" --type=merge -p '{
  "spec":{"template":{"spec":{"domain":{
    "firmware":{"bootloader":{"efi":{"secureBoot":false}}},
    "features":{"smm":{"enabled":false}}
  }}}}}'

# Start the VM
virtctl start "$VM" -n mssql-vss-lab
```

> If you forget and start with Secure Boot on, the VM will sit at TianoCore
> indefinitely. `virtctl stop` will hang in `Stopping` (no OS to receive
> ACPI shutdown); recover with `virtctl stop --force --grace-period=0`,
> then if the VMI is still wedged with finalizers,
> `oc patch vmi <name> --type=merge -p '{"metadata":{"finalizers":null}}'`.
> If the next start fails with `unable to create virt-launcher client
> connection: can not add ghost record`, restart virt-handler on the VM's
> node: `oc -n openshift-cnv delete pod virt-handler-<id>`.

### Sysprep `unattend.xml`

The canonical file is [`docs/unattend.xml`](unattend.xml) — heavily commented
so anyone reusing it understands what each block does. Copy its contents
verbatim into the Console's Sysprep field at step 6 above.

**Before you paste**, replace both `<Value>YOUR-LAB-PASSWORD</Value>` blocks
with a real throwaway lab password. The `<AutoLogon>` password and the
`<UserAccounts><AdministratorPassword>` MUST match — if they don't, you boot
to the Windows logon screen instead of straight to the desktop.

**What the unattend does:**

| Pass | What | Why |
|---|---|---|
| `generalize` | `<SkipRearm>1</SkipRearm>` | Protects the limited eval-rearm count if a future Sysprep re-runs against this VM. |
| `specialize` | `<ProductKey>` (Server 2022 Datacenter GVLK) | Converts the install from `ServerDatacenterEval` to `ServerDatacenter` (KMS). No more eval clock — on healthy images. |
| `specialize` | `<ExtendOSPartition>` | Grows C: to consume all unallocated space on the cloned OS disk. |
| `oobeSystem` | `<OOBE>` skip-everything flags | Skips every first-boot wizard page. Boots straight to desktop. |
| `oobeSystem` | `<AutoLogon>` + `<AdministratorPassword>` | Logs Administrator in automatically so `FirstLogonCommands` actually fires. |

**`FirstLogonCommands` run on first boot, in Order:**

| Order | What | Why |
|---|---|---|
| 1 | Move CDs off `D:`/`E:`, then init/format data disk as `D:` NTFS DATA | Fixes the CD-letter race that breaks the data-disk init if `New-Partition -DriveLetter D` runs while the `virtio-win` CD-ROM is parked on `D:`. |
| 2 | `dism /Set-Edition` fallback | Best-effort if the `specialize`-pass `<ProductKey>` didn't trigger conversion. No-op on broken-DISM golden images. |
| 3 | Enable RDP firewall + `fDenyTSConnections=0` | RDP works immediately on first boot, no manual step. |

**OpenSSH Server is NOT installed by the unattend.** Earlier revisions of
this file had Orders 4-6 download `OpenSSH-Win64.zip` from GitHub. That
approach broke in two ways: (a) the download to the release CDN
(`objects.githubusercontent.com`) stalled and timed out — *originally
diagnosed as a CDN egress block, but isolated to the **NIC MTU** by an A/B
test on 2026-06-18: at the guest's default 1500 MTU the transfer
black-holes on a 1400 OVN overlay; at 1400 the same download completes
(4.6 MB in 1.4 s). `api.github.com` "worked" throughout because its small
requests fit; only the large CDN transfer was affected. See § 4e Path B.*
And (b) on the test image, the `FirstLogonCommands` chain halted between
Order 3 and Order 4 with no diagnostic surface, leaving Orders 4-6 unfired —
a separate, still-unexplained failure not attributable to MTU. SSH install
is now a post-boot step with three install paths (§ 4e); choose whichever
matches your cluster's egress posture.

## 4. First-boot post-config

OCPv Console → Virtualization → VirtualMachines → your VM → **Console (VNC)**.
Wait for Sysprep to finish; you should land at the desktop auto-logged-in as
Administrator. Open PowerShell (as Administrator).

### 4a. Verify QGA — most critical service for this lab

```powershell
Get-Service QEMU-GA
```

Status: `Running`, StartType: `Automatic`. **If it's not running, stop here
and figure out why.** No QGA → no VSS coordination → no application-consistent
backup. The golden image should have it pre-installed.

### 4b. Verify the data disk and detach the CDs

The unattend's `FirstLogonCommands` (Order 1) auto-initializes the blank
data disk as `D:` (NTFS, label `DATA`). Verify:

```powershell
Get-Volume -DriveLetter D
```

Expect `FileSystem: NTFS`, `FileSystemLabel: DATA`, `DriveType: Fixed`,
free space ≈ the size you specified in § 3 step 6.

> **No `D:` volume?** Two likely causes: (a) § 3 step 6 was skipped and there
> is no blank data disk to initialize — `Get-Disk | Where-Object
> PartitionStyle -in 'RAW','Uninitialized'` will return nothing; attach
> a 10 GiB blank disk and re-run the FirstLogonCommand manually:
> `Get-Disk | Where-Object {$_.PartitionStyle -eq 'RAW' -or $_.PartitionStyle -eq 'Uninitialized'} | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter D | Format-Volume -FileSystem NTFS -NewFileSystemLabel DATA -Confirm:$false -Force`.
> (b) Windows assigned `D:` to the virtio-win CD before the FirstLogonCommand
> ran — detach the CDs (below), then re-run the disk init.

**Detach the CDs.** The OCPv catalog template attaches two CD-ROMs:

- `virtio-win-*` (containerDisk) — Balloon / NetKVM / viostor / vioscsi
  drivers. Already installed by Sysprep; dead weight after first boot.
- `unattendCD` — the Sysprep `unattend.xml` you pasted in § 3. Only consumed
  on first boot.

Console → your VM → **Disks** tab → kebab on `virtio-win` and `unattendCD`
rows → **Detach**. Removes installer noise and prevents drive-letter
contention on subsequent reboots.

### 4c. Set hostname (forces a reboot)

```powershell
Rename-Computer -NewName "mssql-lab" -Force -Restart
```

Continue at 4d after the reboot.

### 4d. Verify RDP

The unattend's `FirstLogonCommands` (Order 3) already enabled the firewall
rule and set `fDenyTSConnections=0`. Verify:

```powershell
(Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections   # expect 0
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Where-Object Enabled -eq True | Measure-Object | Select-Object -Expand Count   # expect > 0
```

If either is wrong (rare — unattend Order 3 didn't fire), re-run:

```powershell
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
```

### 4e. Install OpenSSH Server

The unattend in § 3 deliberately does **not** install OpenSSH — install paths
are too cluster-egress-dependent to bake into a one-size-fits-all answer
file. Pick the path that matches what your VM can reach:

| Path | When to use | Requires VM egress to |
|---|---|---|
| **A. Capability install** (preferred) | Healthy golden image, cluster allows Microsoft Update | `*.windowsupdate.com`, `*.windows.com` |
| **B. GitHub zip** | Broken DISM (capability state lies) or no Microsoft Update egress, but cluster allows GitHub | `api.github.com` AND `objects.githubusercontent.com` / `github.com` |
| **C. RDP drag-and-drop** | Locked-down cluster; nothing on the public internet is reachable | None — the file moves over the RDP channel |

Run Path A first; if it fails, fall back to B; if both are blocked, use C.

#### Path A — `Add-WindowsCapability` (Microsoft Update path)

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Test-Path 'C:\Windows\System32\OpenSSH\sshd.exe'   # MUST return True
```

> **Trust but verify.** On DISM-broken golden images we've seen this command
> report success and the capability state move to `Installed`, but `sshd.exe`
> never lands on disk. If `Test-Path` returns False, treat Path A as failed
> and move to Path B.

If `sshd.exe` is present, register and start:

```powershell
powershell.exe -ExecutionPolicy Bypass -File 'C:\Windows\System32\OpenSSH\install-sshd.ps1'
```

Then run the [common service registration block](#common-service-registration)
below.

#### Path B — GitHub `OpenSSH-Win64.zip` download (in-VM)

```powershell
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$r = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest' -UseBasicParsing -Headers @{ 'User-Agent' = 'curl' }
$a = $r.assets | Where-Object name -eq 'OpenSSH-Win64.zip'
$zip = 'C:\Windows\Temp\OpenSSH-Win64.zip'
Invoke-WebRequest -Uri $a.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
if (Test-Path 'C:\Program Files\OpenSSH') { Remove-Item 'C:\Program Files\OpenSSH' -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath 'C:\Program Files' -Force
Rename-Item 'C:\Program Files\OpenSSH-Win64' 'C:\Program Files\OpenSSH'
powershell.exe -ExecutionPolicy Bypass -File 'C:\Program Files\OpenSSH\install-sshd.ps1'
```

> **Set the NIC MTU first.** This is a large transfer, so on a 1400-overlay
> cluster it black-holes at the guest's default 1500 MTU — the request
> *starts* then stalls to the timeout. Run § 4a's MTU fix
> (`netsh interface ipv4 set subinterface "Ethernet" mtu=1400 store=persistent`)
> **before** the download. (Verified 2026-06-18: 1500 → stall/timeout;
> 1400 → 4.6 MB in 1.4 s, same URL/path.)
>
> **If it still hangs after the MTU fix**, you may have a genuine CDN egress
> block. Note `Test-NetConnection objects.githubusercontent.com -Port 443`
> is **not** a reliable check — TCP/443 connects fine (small packets) under
> both an MTU black-hole *and* a working path, so it returns `True` either
> way. The real test is whether the **download** completes after MTU=1400.
> If it doesn't, drop to Path C.

Then run the [common service registration block](#common-service-registration)
below.

#### Path C — RDP drag-and-drop (no in-VM egress required)

On your workstation, download the zip:

```bash
WORKSTATION_DOWNLOAD_DIR="$HOME/Downloads"
curl -fsSL \
  -o "$WORKSTATION_DOWNLOAD_DIR/OpenSSH-Win64.zip" \
  https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip
```

RDP into the VM as Administrator. Drag `OpenSSH-Win64.zip` from your local
file manager into the RDP window — it lands on the Windows desktop. (Most
RDP clients support this; if yours doesn't, copy the file in your file
manager, click into the RDP File Explorer, and paste.)

Then in the VM PowerShell:

```powershell
$zip = "$env:USERPROFILE\Desktop\OpenSSH-Win64.zip"
Test-Path $zip   # MUST be True
if (Test-Path 'C:\Program Files\OpenSSH') { Remove-Item 'C:\Program Files\OpenSSH' -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath 'C:\Program Files' -Force
Rename-Item 'C:\Program Files\OpenSSH-Win64' 'C:\Program Files\OpenSSH'
powershell.exe -ExecutionPolicy Bypass -File 'C:\Program Files\OpenSSH\install-sshd.ps1'
```

Then run the common service registration block below.

#### Common service registration

After any of Paths A/B/C has placed binaries on disk and run `install-sshd.ps1`,
finish with:

```powershell
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
    -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -PropertyType String -Force | Out-Null

Get-Service sshd | Format-List Name, Status, StartType
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Format-List Name, Enabled, Direction, Action
```

Expect `Status: Running`, `StartType: Automatic`, and the firewall rule
present with `Enabled: True`.

#### Public-key auth (recommended)

For local Administrators, SSH keys go in a single shared file, **not** the
user's `~/.ssh/`:

```
C:\ProgramData\ssh\administrators_authorized_keys
```

> **Encoding gotcha — read this before you write the file.** PowerShell's
> `Set-Content`, `Out-File`, `>` redirection, and most Windows text editors
> default to **UTF-16 LE with a BOM**. OpenSSH can't parse that and silently
> falls back to password auth (key login just fails with no useful error).
> Always write this file as plain ASCII.

On your workstation, copy the public key to clipboard:

```bash
# macOS
pbcopy < "$HOME/.ssh/id_ed25519.pub"
# Linux (Wayland)
wl-copy < "$HOME/.ssh/id_ed25519.pub"
# Linux (X11)
xclip -selection clipboard < "$HOME/.ssh/id_ed25519.pub"
```

In the VM (RDP or VNC console PowerShell), paste the key into `$key` and
write it via `[System.IO.File]::WriteAllText` with explicit ASCII encoding:

```powershell
$key = "ssh-ed25519 AAAA...your-key-here... user@host"   # paste from clipboard
[System.IO.File]::WriteAllText(
    "C:\ProgramData\ssh\administrators_authorized_keys",
    $key.Trim() + "`n",
    [System.Text.Encoding]::ASCII
)
```

Verify the file is ASCII (not UTF-16):

```powershell
Format-Hex C:\ProgramData\ssh\administrators_authorized_keys | Select-Object -First 1
```

First bytes should be `73 73 68` (`ssh`...). If you see `FF FE` at the start
and `00` after every character, it's UTF-16 — rewrite it with the
`WriteAllText` block above.

Permissions matter — file must be owned by `Administrators` or `SYSTEM` with
no other write access:

```powershell
$acl = Get-Acl C:\ProgramData\ssh\administrators_authorized_keys
$acl.SetAccessRuleProtection($true, $false)
$rules = @(
  New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","Allow")
  New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","Allow")
)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
$rules | ForEach-Object { $acl.AddAccessRule($_) }
Set-Acl -Path C:\ProgramData\ssh\administrators_authorized_keys -AclObject $acl
Restart-Service sshd
```

Password auth also works if you'd rather skip keys for the lab.

### 4f. Verify the edition conversion (Eval → Datacenter)

The Sysprep unattend in § 3 attempts to convert the install from
`ServerDatacenterEval` to `ServerDatacenter` (KMS). Confirm it took.

**Required first step — do not skip:** set the default Windows Script Host
to `cscript`. `slmgr.vbs` defaults to `wscript.exe` which renders results
as **GUI popup dialogs** — visible to interactive users but invisible to
PowerShell and SSH sessions. Without this, `slmgr /xpr` and `slmgr /dlv`
return nothing on stdout and you'll think they're broken.

```powershell
cscript //nologo //h:cscript //s
# Expect: "The default script host is now set to cscript.exe."
```

Once per machine; no reboot required. Now check the edition:

```powershell
DISM /online /Get-CurrentEdition           # expect: ServerDatacenter (NOT ServerDatacenterEval)
slmgr /xpr                                 # expect: KMS grace or activated, NOT "Notification mode"
slmgr /dlv | Select-String 'License Status','Partial Product Key'
```

**Healthy output looks like:**

```
Current Edition : ServerDatacenter
License Status: Licensed   (or "Initial grace period ends ..." against a KMS server)
Partial Product Key: 6VM33     (last 5 of the GVLK)
```

**If `Get-CurrentEdition` still shows `ServerDatacenterEval`** — the
specialize-pass `<ProductKey>` and the FirstLogonCommands DISM fallback
both failed to convert. Run the conversion manually:

```powershell
DISM /online /Set-Edition:ServerDatacenter /ProductKey:WX4NM-KYWYW-QJJR4-XV3QB-6VM33 /AcceptEula
# Reboots automatically on completion (5-15 min)
```

After the reboot, re-check `DISM /online /Get-CurrentEdition`. If it still
sticks on Eval, the install is unusual — fall back to the rearm path:
`slmgr /rearm` + `Restart-Computer` will buy 10-180 days at a time (depending
on whether the eval has already expired), with 4 rearms remaining on a fresh
clone of the current image.

> Do the verification (and any manual conversion) **before** the SQL install —
> a forced reboot mid-install will corrupt the SQL files.

## 5. Expose RDP and SSH from the cluster

**Easiest:** in the OCP Console, **Virtualization → VirtualMachines →
your VM → Details**, use the **Create RDP service** and **Create SSH service**
buttons. The Console generates a NodePort `Service` with the correct
selector (`vm.kubevirt.io/name: <vm-name>`) automatically.

If you'd rather apply YAML — note the selector key. The catalog-template
VM's launcher pod has `kubevirt.io/domain` set to the **VM resource name**
(`mssql`, from § 3 step 2), *not* the Windows hostname (`mssql-lab`, from
§ 4c). Use `vm.kubevirt.io/name` to be unambiguous:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mssql-lab-rdp
  namespace: mssql-vss-lab
spec:
  type: NodePort
  selector:
    vm.kubevirt.io/name: <your-vm-resource-name>   # not the Windows hostname
  ports:
    - { name: rdp, port: 3389, targetPort: 3389, protocol: TCP }
---
apiVersion: v1
kind: Service
metadata:
  name: mssql-lab-ssh
  namespace: mssql-vss-lab
spec:
  type: NodePort
  selector:
    vm.kubevirt.io/name: <your-vm-resource-name>
  ports:
    - { name: ssh, port: 22, targetPort: 22, protocol: TCP }
```

### Verify connectivity from your workstation

`oc -n mssql-vss-lab get svc` shows the NodePorts assigned (e.g.
`3389:31211/TCP`, `22:31256/TCP`). `oc get nodes -o wide` shows worker IPs.
`nc -zv` is netcat probing TCP reachability from your workstation to the
cluster: `-z` = zero-I/O (just probe), `-v` = verbose. Set the variables
once, then probe + connect:

```bash
WORKER_IP=<one-of-your-worker-IPs>
RDP_NODEPORT=<from-oc-get-svc>
SSH_NODEPORT=<from-oc-get-svc>

nc -zv "$WORKER_IP" "$RDP_NODEPORT"   # expect "succeeded"
nc -zv "$WORKER_IP" "$SSH_NODEPORT"   # expect "succeeded"
```

> If `nc` says succeeded but `ssh` gets **Connection refused**, the Service
> usually has zero endpoints — `oc -n mssql-vss-lab get endpoints` shows
> `<none>`. Almost always a selector mismatch. Patch the selector:
> `oc -n <ns> patch svc <svc> --type=merge -p '{"spec":{"selector":{"kubevirt.io/domain":null,"vm.kubevirt.io/name":"<vm-name>"}}}'`

Then connect.

**RDP:** paste `<WORKER_IP>:<RDP_NODEPORT>` into your RDP client's "PC name"
field. Username `Administrator`, password = the value you put in
`<AutoLogon><Password>` / `<AdministratorPassword>` in the unattend.

**SSH:** depends on which auth you set up in § 4e.

If you uploaded a public key to `administrators_authorized_keys`, point at
the matching private key on your workstation:

```bash
SSH_KEY="$HOME/.ssh/id_ed25519"   # the key whose .pub you uploaded
ssh -i "$SSH_KEY" -p "$SSH_NODEPORT" administrator@"$WORKER_IP"
```

If you skipped the public-key step, omit `-i "$SSH_KEY"` and you'll be
prompted for the Administrator password (same one you set in the unattend):

```bash
ssh -p "$SSH_NODEPORT" administrator@"$WORKER_IP"
```

If the cluster is behind a VPN or jump host, add a `~/.ssh/config`
`ProxyJump` entry on your workstation so the `ssh` command above works
end-to-end.

## 6. Install MS SQL Server (Developer Edition)

Free, full-feature, non-production EULA. No license key, no activation.

1. Download from <https://www.microsoft.com/en-us/sql-server/sql-server-downloads>
   → **Developer**.
2. Run setup inside the VM (RDP in for the GUI):
   - **New SQL Server stand-alone installation**.
   - **Database Engine Services** feature.
   - **Default instance** (`MSSQLSERVER`) is preferred for this lab — keeps
     connection strings short (`sqlcmd -S .`) and matches the Python
     generator config. **If the installer hands you a named instance**
     (e.g. `MSSQLSERVER01`), that's fine functionally but every connection
     string downstream needs `<host>\MSSQLSERVER01` instead of just `<host>`.
     Note the instance name shown on the "Installation has completed
     successfully" screen — we'll need it for the Python generator.
   - **Mixed Mode** auth. Strong `sa` password. Add Administrator as a SQL admin.
   - **Data directories:** point everything at `D:\` —
     `D:\MSSQL\Data`, `D:\MSSQL\Log`, `D:\MSSQL\Backup`. Keeps the FLR story
     clean (SQL files live on the data disk, not `C:`). **If `D:` doesn't
     exist yet**, go back to § 3 step 6 / § 4b — the SQL data dirs on `C:` muddy
     the per-volume snapshot story.
3. Install **SSMS** (Management Studio) separately — also free, link on the
   same page (there's also an "Install SSMS" shortcut button on the SQL
   installer's completion screen).
4. Verify the **VSS Writer** service:

   ```powershell
   Get-Service SQLWriter
   ```

   Status: `Running`, StartType: `Automatic` (default). **This is the writer
   QGA's freeze signal will engage.**

5. Sanity check the engine. Pick the form that matches your install:

   ```powershell
   # Default instance (MSSQLSERVER)
   sqlcmd -S . -E -Q "SELECT @@VERSION;"

   # Named instance (e.g. MSSQLSERVER01)
   sqlcmd -S .\MSSQLSERVER01 -E -Q "SELECT @@VERSION;"
   ```

   Should return a Developer Edition banner. **If `sqlcmd -S .` returns
   "Login timeout expired" / "named pipes provider" error**, you almost
   certainly have a named instance — use the `.\<INSTANCE_NAME>` form.

## 7. Done-state checklist

- [ ] VM running on your OCPv cluster in namespace `mssql-vss-lab`, Windows
      Server 2022 (hostname `mssql-lab` if you ran the rename in § 4c; the
      Sysprep-generated `WIN-XXXXXXXX` is functionally fine too).
- [ ] `DISM /online /Get-CurrentEdition` reports `ServerDatacenter` (not
      `ServerDatacenterEval`) on healthy images. On broken-DISM images the
      Eval grace + `slmgr /rearm` fallback in § 4f also works — see that
      section for the trade-off.
- [ ] `D:` data disk formatted (NTFS, label `DATA`), empty, ready for SQL
      data files (CDs detached).
- [ ] `Get-Service QEMU-GA` → `Running`.
- [ ] RDP works from your workstation (port 3389 reachable, can log in as
      Administrator).
- [ ] `Get-Service sshd` → `Running` inside the VM (via whichever § 4e path
      worked for your cluster), and `ssh administrator@<vm-endpoint>` works
      from your workstation, landing in PowerShell.
- [ ] `Get-Service SQLWriter` → `Running`.
- [ ] `sqlcmd -S . -E -Q "SELECT @@VERSION;"` (or `-S .\<INSTANCE>` for a
      named instance) returns a Developer Edition banner.
- [ ] Access path captured (direct? VPN? jump host?) and `~/.ssh/config`
      `ProxyJump` entry added if needed.

When all nine boxes are checked, the VM is ready for the BackupPlan + restore
flow in [`docs/lab-guide.md`](lab-guide.md).
