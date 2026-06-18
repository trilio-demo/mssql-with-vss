# Golden Image Build — Windows Server 2025

How to build the lab's **Windows Server 2025** golden image from an ISO using
the Red Hat **`windows-efi-installer`** Tekton pipeline, so it drops cleanly
into the VM-prep flow. The point of building our own image (vs. the stock
engineering golden image) is to produce **self-sufficient clones**:

1. **virtio + QGA + OpenSSH baked in** — per-VM prep shrinks to "upload your
   key." QGA is load-bearing for the VSS lab (Trilio drives Windows VSS
   freeze/thaw through it); SSH is convenience.
2. **No reliance on a healthy in-image servicing stack or Microsoft Update
   egress at clone time** — everything that needs the network is done **once**,
   at bake time.

> Pairs with [`win2k25-vm-prep.md`](win2k25-vm-prep.md), which consumes the
> resulting image. This brief is the *build* side; that doc is the *clone* side.

**Source-of-truth files (edit these, then rebuild — see the procedure):**

| File | Role |
|---|---|
| [`win2k25-golden-autounattend.xml`](win2k25-golden-autounattend.xml) | Build answer file — windowsPE install → audit mode → `sysprep /generalize` → shutdown/capture. |
| [`win2k25-golden-post-install.ps1`](win2k25-golden-post-install.ps1) | Runs once in **audit mode**: virtio + QGA + OpenSSH + firewall + host-key wipe. |
| [`win2k25-golden-dataimportcron.yaml`](win2k25-golden-dataimportcron.yaml) | Downstream — publishes the distributed containerDisk as a catalog boot source. |

---

## ⚠️ The eval clock is solved by **activation**, not by a licensed ISO

This is the single most important correction over earlier (2022) thinking.

A freshly generalized **evaluation** clone boots into an "Initial grace period"
that is the **activate-within-10-days** deadline — *not* a 10-day eval. Running
**`slmgr /ato`** (online activation) flips it to the full **~180-day** timed
eval. **No licensed/VL ISO and no product key are required**, and you must
**not** try to convert the edition inline (see build-breakers below).

- **Build side:** leave the image **generalized and unactivated**. Do nothing
  about licensing here.
- **Clone side:** [`unattend.xml`](unattend.xml) Order 4 runs `slmgr /ato` on
  first boot (after the MTU fix, which the activation HTTPS call depends on).
  Each clone self-activates to ~180 days. See `win2k25-vm-prep.md` § 4.

The old `golden-image-build.md` premise — "install a licensed edition to kill
the eval clock" — was **wrong** and led to the `dism /Set-Edition` build-hang.
Do not reintroduce it.

---

## What the two answer files do

The PowerShell is in the repo files above; this is the *why* so you can review
a change before rebaking. Don't duplicate the scripts into procedure runbooks —
edit the files and rebuild.

### `win2k25-golden-autounattend.xml` (build answer file)
- **windowsPE**: wipes disk 0, lays EFI/MSR/Primary, injects the virtio
  `viostor` + `NetKVM` drivers from the mounted virtio ISO (`E:\…\2k25\amd64`),
  and selects the edition via **`/IMAGE/INDEX = 2`** (Standard, Desktop
  Experience). Empty `<ProductKey>` — eval, activated later by the clone.
- **oobeSystem** reseals into **Audit** mode.
- **auditUser** runs `F:\post-install.ps1` once, then **generalizes with
  `ForceShutdownNow`** — that shutdown is what the pipeline captures as the
  golden disk.

### `win2k25-golden-post-install.ps1` (audit-mode customize)
Everything here lands in the image:
- **virtio-win guest drivers** (KubeVirt disk/NIC) + **QEMU Guest Agent**.
- **NIC MTU → 1400, set early** (insurance). Generalize resets it, so it does
  *not* carry to the clone — clone-side MTU is `unattend.xml` Order 4's job (the
  effective fix for activation + large transfers; see win2k25-vm-prep.md § 4a).
  Kept in the bake as harmless early insurance.
- **OpenSSH Server: use the INBOX install.** Windows Server **2025 ships OpenSSH
  Server installed inbox** (`OpenSSH.Server` = Installed; binaries at
  `system32\OpenSSH`; `sshd` registered; a predefined firewall rule app-locked
  to `system32\OpenSSH\sshd.exe`). So the 2025 recipe does **not** download
  anything — it just sets `sshd` `Automatic` and broadens the existing
  (already app-matched) firewall rule to `-Profile Any` (the masquerade net is
  classified `Public`; a Private-only rule silently drops inbound SSH).
  **Do NOT GitHub-zip install on 2025** — it drops a second sshd in
  `C:\Program Files\OpenSSH` and repoints the service there, breaking the inbox
  rule's app-lock and silently blocking inbound SSH (caught 2026-06-18 by
  validating a clone before distribution). *Server **2022** does NOT ship OpenSSH
  inbox → its golden recipe keeps the **GitHub-zip + a uniquely-named,
  port-based (`-LocalPort 22`, no `-Program`) `-Profile Any` rule** instead.*
- **Host-key wipe** before generalize so every clone gets unique SSH host keys
  (the inbox capability install may have pre-generated host keys → wipe them).
  Does **not** bake `authorized_keys` (key upload stays per-clone).

---

## Build procedure (configmap + pipeline)

Run on a cluster with the **OpenShift Pipelines** operator and the
**`redhat-pipelines`** Tekton Hub catalog enabled. Pick a build namespace:

```bash
NS=win-golden-build
```

### 1. Build the answer-file ConfigMap

The pipeline mounts this ConfigMap as the sysprep CD (drive `F:`). It needs
**both** keys — `autounattend.xml` and `post-install.ps1` — keyed exactly so
(`F:\post-install.ps1` is hard-referenced from the answer file). Recreate it
straight from the repo files so the image always matches what's committed:

```bash
oc create configmap windows2k25-autounattend-golden \
  --from-file=autounattend.xml=docs/win2k25-golden-autounattend.xml \
  --from-file=post-install.ps1=docs/win2k25-golden-post-install.ps1 \
  -n "$NS" --dry-run=client -o yaml | oc apply -f -
```

> Re-run this after **any** edit to either source file, then re-run the
> pipeline. (Editing the file on your Mac alone changes nothing — the pipeline
> reads the ConfigMap, not your working tree.)

### 2. Run the `windows-efi-installer` pipeline

Easiest from the console: **Pipelines → Pipelines → Create → from the
`redhat-pipelines` catalog → `windows-efi-installer`** (lab used **v4.21.0**,
resolved via the hub resolver; bump the PipelineRun timeout to ~**2h**). The
PipelineRun form prompts for parameters; the ones that matter (names may vary
slightly by pipeline version — map by function):

| Parameter (function) | Value |
|---|---|
| Autounattend ConfigMap name | **`windows2k25-autounattend-golden`** (from step 1) |
| Windows ISO download URL | a **current Server 2025 eval ISO** URL |
| virtio container-disk image | the cluster's virtio-win containerDisk |
| Output base DataVolume name | **`win2k25`** |
| Preference / instance type | Windows 2025 / a sane default (e.g. `u1.large`) |
| Target DV size / StorageClass | ≥ 21 Gi on a working SC (Block/RWX ideal) |

The pipeline boots the ISO into an installer VM, runs the answer file +
post-install, generalizes, shuts down, and captures the result into the
`win2k25` DataVolume.

### 3. Monitor — and the two hangs you will hit

- **`wait-for-vmi-status` task hangs** after the build VM should have powered
  off (VMI finalizers don't release). Clear it by force-deleting the launcher
  pod:
  ```bash
  oc delete pod -l vm.kubevirt.io/name=<build-vm-name> -n "$NS" --grace-period=0 --force
  ```
- **Image-picker hang in windowsPE** (Setup sits on the edition-select screen).
  Microsoft refreshes the eval ISO periodically and the image *Description*
  strings drift — which is exactly why the answer file selects by
  **`/IMAGE/INDEX`** (index 2 = Standard Desktop Experience), not by
  `/Image/Description`. Catch a stuck install fast with a screenshot instead of
  waiting out the timeout:
  ```bash
  virtctl vnc screenshot <build-vm-name> -n "$NS" --output=/tmp/build.png
  ```
  If a future ISO reorders indexes, confirm with
  `dism /Get-ImageInfo /ImageFile:<install.wim>` and adjust `/IMAGE/INDEX`.

### 4. Output

A generalized, **unactivated** `win2k25` DataVolume — the golden master. Verify
it on a test clone (below), then distribute it.

---

## Build-breakers learned the hard way (do NOT reintroduce)

| Anti-pattern | What happens | Do instead |
|---|---|---|
| `dism /Set-Edition` (inline edition conversion) before sysprep | Set-Edition stages a pending-reboot; `sysprep /generalize` refuses (`hr=0x8007139f`); the VM never powers off → `wait-for-vmi-status` hangs forever | **No edition conversion.** Boot the eval ISO, pick the edition via `/IMAGE/INDEX`, activate per-clone with `slmgr /ato`. |
| GitHub-zip OpenSSH install on **Server 2025** | 2025 already ships OpenSSH Server inbox (`system32\OpenSSH`) with an app-locked firewall rule; a zip install drops a second sshd in `C:\Program Files\OpenSSH` and repoints the service there, breaking the rule's app-lock → inbound SSH silently blocked (caught 2026-06-18) | **2025: use the inbox install** — `Set-Service sshd Automatic` + broaden the existing rule to `-Profile Any`. No download. |
| OpenSSH via `Add-WindowsCapability` (Windows-Update FOD) on **Server 2022** | FOD endpoint (`fe2.update.microsoft.com`) is commonly blocked; on the old golden image DISM also lied (`Installed`, no binaries) | **2022 only** (it has no inbox OpenSSH): **GitHub release zip** + a uniquely-named, port-based `-Profile Any` rule — `github.com` + CDN reachable, no FOD/DISM dependency. |
| Treating the 10-day clock as the eval length | Wasted effort chasing licensed ISOs / `slmgr /rearm` | It's the **activate-by** deadline; `slmgr /ato` unlocks ~180 days. |
| Starting sshd during the build without wiping host keys | Every clone ships identical SSH host keys | Set sshd `Automatic` but don't start it; **wipe `C:\ProgramData\ssh\ssh_host_*`** before generalize. |
| Large download before setting MTU | Stalls/timeouts that look like an egress block | Set NIC **MTU 1400 first** (already first in `post-install.ps1`). |

---

## Post-build verification (on a test clone, before blessing the image)

Provision one VM from `win2k25` via `win2k25-vm-prep.md` and confirm:

```powershell
Get-ComputerInfo | Select WindowsProductName, OsHardwareAbstractionLayer  # 2025, Desktop
Get-Service QEMU-GA      # Running / Automatic
Get-Service sshd         # Running / Automatic
slmgr /xpr               # after Order-4 /ato: ~180 days, NOT Notification mode
Get-NetFirewallRule -DisplayName 'OpenSSH*' | Select DisplayName, Profile, Enabled  # Profile = Any
```

Also confirm two clones present **different** SSH host keys (no `known_hosts`
collision) — proves the host-key wipe worked.

---

## After the image is built — distribute it

The golden DV lives on the build cluster. To make it consumable everywhere,
package it as an OCI **containerDisk** (disk at `/disk/`), push to a registry
all clusters reach (lab uses `ghcr.io/trilio-demo/win2k25-golden:<date-tag>`),
and consume via a `registry:` DataVolume or the
[`win2k25-golden-dataimportcron.yaml`](win2k25-golden-dataimportcron.yaml)
catalog boot source. Build the containerDisk **in-cluster** (a buildah Job) —
the Mac `virtctl vmexport download` is unreliable on multi-GB pulls. Full
consume-side setup (GHCR secrets, the two-namespace pull-secret gotcha) is in
`win2k25-vm-prep.md` § 1–2.

---

## What this retires in `win2k25-vm-prep.md`

Once a rebaked image is built **and** distributed, and a test clone passes:

- **§ 5c (firewall `-Profile Any`)** → becomes baked; drop it as a per-clone
  step. *(The currently-distributed `:2026-06-16` containerDisk predates the
  firewall fix, so § 5c is still required until the next rebake+push.)*
- **§ 5 SSH install** is already "baked — just upload your key"; nothing to
  change there.
- **§ 4 (MTU + activation)** stays — clone-side, still required.

Hold prep-doc edits until the rebaked image is live and verified.
