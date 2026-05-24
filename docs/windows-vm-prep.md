# Windows VM Prep — Reference Guide

Standalone reference for preparing the Windows Server 2022 VM that will host
MS SQL Server for this lab on `ocp-px`. Follows engineering's golden-image
flow (collateral). Run through it once and the next Claude Code session can
pick up at "configure Trilio backup target + write the generator."

## Goal

A fresh Windows Server **2022** VM in a fresh namespace on `ocp-px`, built
from engineering's **golden image**, with:

- A separate data disk (`D:`) for SQL data files (clean FLR story).
- **QEMU Guest Agent (QGA)** running — what Trilio signals to drive Windows VSS.
- **RDP (3389)** and **OpenSSH Server (22)** both enabled, reachable from your Mac.
- **MS SQL Server Developer Edition** + **SSMS** installed, with the
  **`SQLWriter`** service running.

## Prerequisites

- `oc` and **`virtctl`** CLI installed locally; logged in to `ocp-px` as
  cluster-admin (or sufficient role for `openshift-virtualization-os-images`).
- The Windows Server 2022 golden image (`win2k22.img`) downloaded from the
  engineering Drive folder (URL in your earlier conversation). Save it
  locally — `~/Downloads/win2k22.img` is fine.
- Cluster prereqs verified earlier in this project:
  - OCPv (CNV) installed (`openshift-cnv`).
  - Trilio operator installed.
  - `px-csi-replicated` annotated as `is-default-virt-class=true`.
  - Snapshot class `px-csi-snapclass` available.

> ### ⚠️ Heads-up: Windows Server evaluation clock
>
> The engineering golden image is a **Windows Server 2022 Datacenter
> Evaluation** build (observed: build 20348, `fe_release.210507` from
> 2021-05). The 180-day evaluation period starts when the image was
> captured, **not** when you boot a clone — so the eval may already be
> expired or close to it on first boot.
>
> When eval expires, Windows force-reboots **every ~60 minutes**. Under
> `runStrategy: Always` this looks like a KubeVirt restart loop in the
> `virt-controller` logs (VMI moves to `Succeeded` ~1h after each start),
> but the trigger is inside Windows, not KubeVirt.
>
> Check and remediate on first boot (§ 4f below).

---

## 1. Upload the golden image as a DataVolume

Lands in the shared catalog namespace `openshift-virtualization-os-images` on
Portworx. Subsequent VM clones land on the virt-default class
(`px-csi-replicated`).

```bash
virtctl image-upload dv win2k22 \
  --size=20Gi \
  --image-path=~/Downloads/win2k22.img \
  --storage-class=px-csi-replicated \
  --access-mode=ReadWriteOnce \
  --volume-mode=block \
  --insecure \
  --namespace=openshift-virtualization-os-images
```

> **Deviation from engineering's guide.** The original guide pins the upload
> to `ocs-storagecluster-ceph-rbd-virtualization` (RWX block). On `ocp-px`
> that class exists as an orphaned shell — no `cephcluster` CRD, no
> `csi-rbdplugin-provisioner` pods, so PVCs against it stay Pending forever.
> `px-csi-replicated` (RWO block) is `ocp-px`'s working equivalent for VM
> disks; RWX isn't required for image upload (only one pod writes). Catalog
> VM clones from this boot source work normally.
>
> Worth flagging back to engineering if their guide is meant to be
> cluster-agnostic.

Expect this to take a while — the CDI upload-proxy throughput on `ocp-px`
runs around 1 MB/s, so a 20 GiB upload can take hours. Track progress with:

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

In the OCP Console:

1. **Virtualization → Catalog → Microsoft Windows Server 2022 VM** → *Create
   VirtualMachine*.
2. **Project / Namespace:** `mssql-vss-lab`.
3. **CPU / Memory:** 4 vCPU, 8 GB RAM.
4. **Disks: this step is mandatory — don't skip.** Keep the default boot
   disk, then **Add disk** (the form section is at the bottom of the page;
   easy to miss):
   - Name: `data`
   - Source: Blank
   - Size: **40 GiB**
   - StorageClass: leave as default (picks up `px-csi-replicated`).
   - Type: Disk (block / virtio).

   > If you forgot this and the VM is already created, you can add it
   > post-create: Console → your VM → **Disks** tab → **Add disk** with the
   > same fields. Stop/start the VM after attaching (some attach flows are
   > hot-add capable but it's cleaner to cycle). The post-boot RAW-disk
   > format step in § 4b silently no-ops if no spare disk is present, so
   > the absence is easy to miss until you try to install SQL on `D:`.
5. Click **Customize VirtualMachine**.
6. **Scripts** tab → **Sysprep** → paste the unattend XML below.
7. **Untick "Start this VirtualMachine after creation"** so you can adjust
   firmware before first boot (next step). Then click **Create VirtualMachine**.

### 3a. Disable Secure Boot before first boot

The catalog template defaults to UEFI **with Secure Boot on**. The
engineering team's golden image bootloader's signing chain doesn't match the
keys OVMF's secboot variant trusts, so Secure Boot rejects it and the VM
parks at the TianoCore splash. Patch it off before starting.

```bash
# Catalog templates generate a random VM name; grab it
VM=$(oc -n mssql-vss-lab get vm -o jsonpath='{.items[0].metadata.name}')

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

### Sysprep `unattend.xml` (verbatim from engineering guide)

```xml
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <ExtendOSPartition><Extend>true</Extend></ExtendOSPartition>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component
      xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      name="Microsoft-Windows-Shell-Setup"
      processorArchitecture="amd64"
      publicKeyToken="31bf3856ad364e35"
      language="neutral"
      versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <SkipUserOOBE>true</SkipUserOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <AutoLogon>
        <Password><Value>YOUR-LAB-PASSWORD</Value><PlainText>true</PlainText></Password>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
      </AutoLogon>
      <UserAccounts>
        <AdministratorPassword>
          <Value>YOUR-LAB-PASSWORD</Value><PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <TimeZone>Eastern Standard Time</TimeZone>
    </component>
  </settings>
</unattend>
```

> Replace **both** `<Value>YOUR-LAB-PASSWORD</Value>` blocks with the same
> value before pasting. AutoLogon needs the `<AutoLogon>` password and the
> `<UserAccounts><AdministratorPassword>` password to match — if they don't,
> you boot to the Windows logon screen instead of straight to the desktop.
> Throwaway VM, throwaway creds; don't reuse a real password.

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

### 4b. Clear the CD drives and format the data disk

The OCPv catalog template attaches **two CD-ROMs** to the VM:

- `virtio-win-*` (containerDisk) — Balloon / NetKVM / viostor / vioscsi
  drivers. Already installed by Sysprep; the CD is dead weight after first boot.
- `unattendCD` — the Sysprep `unattend.xml` you pasted in § 3. Only consumed
  on first boot.

Windows grabs the first two free letters for them — observed: `D:` =
virtio-win, `E:` = unattendCD. That eats the letter we want for the data
disk. Clear them out:

**Option A (clean):** detach both CDs from the VM via Console → your VM →
**Disks** tab → kebab on `virtio-win` and `unattendCD` rows → **Detach**.
This frees `D:` and `E:` permanently and removes installer noise. Recommended
once first boot is done.

**Option B (rename only):** if you'd rather keep the CDs attached, move
their drive letters out of the way from PowerShell:

```powershell
# Move the virtio-win CD out of D:
Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='D:'" |
  Set-CimInstance -Property @{DriveLetter='X:'}

# Move the unattendCD out of E: (optional — only matters if you want E: free)
Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='E:'" |
  Set-CimInstance -Property @{DriveLetter='Y:'}
```

Then initialize and format the data disk:

```powershell
Get-Disk | Where-Object PartitionStyle -eq 'RAW' |
  Initialize-Disk -PartitionStyle GPT -PassThru |
  New-Partition -DriveLetter D -UseMaximumSize |
  Format-Volume -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
```

> **No output / nothing happened?** `Get-Disk | Where-Object PartitionStyle
> -eq 'RAW'` silently returns nothing if there is no spare disk — meaning
> step 3.4 (Add disk) was skipped. Verify in **This PC** that `D:` exists
> after the format; if not, go back and attach the 40 GiB blank disk.

`D:` should now exist and be empty.

### 4c. Set hostname (forces a reboot)

```powershell
Rename-Computer -NewName "mssql-lab" -Force -Restart
```

Continue at 4d after the reboot.

### 4d. Enable RDP

```powershell
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
  -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
```

### 4e. Enable OpenSSH Server

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType 'Automatic'

if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

# Default SSH shell -> PowerShell (instead of cmd.exe)
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String -Force
```

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

On your Mac, copy the public key to clipboard:

```bash
pbcopy < ~/.ssh/id_ed25519.pub   # or whichever key you use
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

### 4f. Windows activation status (do this before SQL install)

The engineering golden image is **Datacenter Evaluation**. The 180-day eval
clock started when the image was captured (build observed:
`20348.fe_release.210507` — May 2021), not when you cloned it. The eval may
already be expired on first boot.

Check immediately after Sysprep finishes.

> **`slmgr` over SSH (or any PowerShell session) returns no output by
> default.** `slmgr.vbs` is a VBScript that defaults to `wscript.exe`, which
> renders results as GUI popup dialogs — visible on the Windows desktop,
> invisible to an SSH session. Switch the default script host to `cscript`
> once per machine so output goes to stdout:
>
> ```powershell
> cscript //nologo //h:cscript //s
> # "Command line options are saved. The default script host is now set to cscript.exe."
> ```
>
> After this, `slmgr /xpr` and `slmgr /dlv` work normally in any shell.
> (Alternative: call `cscript //nologo C:\Windows\System32\slmgr.vbs /xpr`
> explicitly each time.)

```powershell
slmgr /xpr    # "permanently activated" / "in notification mode" / "initial grace period ends ..."
slmgr /dlv    # verbose — License Status, Notification Reason, rearm count
```

**Expired-eval signature in `slmgr /dlv`:**

```
License Status: Notification
Notification Reason: 0xC004F009 (grace time expired).
Remaining Windows rearm count: 5
```

`License Status: Notification` + `0xC004F009` is the smoking gun. The
matching cluster-side symptom is the 60-minute reboot loop:

```bash
oc logs -n openshift-cnv deployment/virt-controller -f \
  | grep "<your-vm-name>"
```

Pattern in the log: `Stopping VM with VMI in phase Succeeded` → ~35s gap →
`Starting VM due to runStrategy: Always`, repeating every ~61 min. Windows
is force-rebooting; KubeVirt sees the clean shutdown as `Succeeded` and
relaunches under `runStrategy: Always`.

**Remediate (if `Remaining Windows rearm count` > 0):**

```powershell
slmgr /rearm
Restart-Computer
```

Each `/rearm` extends the eval by ~180 days. Windows Server 2022 grants 5
rearms total. After reboot, `slmgr /xpr` should report
`Initial grace period ends ...` with days remaining and the 60-min reboot
cycle stops.

If rearms are exhausted, options (in rough order of pain):

- Convert eval → retail with a real Datacenter/Standard key:
  `dism /online /set-edition:ServerStandard /productkey:XXXXX-XXXXX-XXXXX-XXXXX-XXXXX /accepteula`
- Point at a KMS/activation server you have access to.
- Rebuild the engineering golden image from a fresher Windows Server 2022 ISO.

> Do this **before** the SQL install — otherwise the next forced reboot
> can interrupt setup mid-flight.

## 5. Expose RDP and SSH from the cluster

**Easiest:** in the OCP Console, **Virtualization → VirtualMachines →
your VM → Details**, use the **Create RDP service** and **Create SSH service**
buttons. The Console generates a NodePort `Service` with the correct
selector (`vm.kubevirt.io/name: <vm-name>`) automatically.

If you'd rather apply YAML — note the selector key. The catalog-template
VM's launcher pod has `kubevirt.io/domain` set to the **VM resource name**
(e.g. `win2k22-aqua-junglefowl-90`), *not* the Windows hostname. Use
`vm.kubevirt.io/name` to be unambiguous:

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

### Verify connectivity from your Mac

`oc -n mssql-vss-lab get svc` shows the NodePorts assigned (e.g.
`3389:31211/TCP`, `22:31256/TCP`). `oc get nodes -o wide` shows worker IPs.
`nc -zv` is netcat probing TCP reachability from your Mac to the cluster:
`-z` = zero-I/O (just probe), `-v` = verbose. Substitute any worker IP and
the actual NodePorts:

```bash
nc -zv 172.31.1.56 31211   # RDP NodePort  -> expect "succeeded"
nc -zv 172.31.1.56 31256   # SSH NodePort  -> expect "succeeded"
```

> If `nc` says succeeded but `ssh` gets **Connection refused**, the Service
> usually has zero endpoints — `oc -n mssql-vss-lab get endpoints` shows
> `<none>`. Almost always a selector mismatch. Patch the selector:
> `oc -n <ns> patch svc <svc> --type=merge -p '{"spec":{"selector":{"kubevirt.io/domain":null,"vm.kubevirt.io/name":"<vm-name>"}}}'`

Then connect:

```bash
# RDP — paste 172.31.1.56:31211 into Microsoft Remote Desktop's "PC name"
# SSH
ssh administrator@172.31.1.56 -p 31256
```

If `ocp-px` is behind a VPN or jump host, capture the path now — we'll add
a `~/.ssh/config` `ProxyJump` entry next session.

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
     exist yet**, go back to § 3.4 / § 4b — the SQL data dirs on `C:` muddy
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

- [ ] VM running on `ocp-px` in `mssql-vss-lab`, Windows Server 2022 (hostname
      `mssql-lab` if you ran the rename; the Sysprep-generated `WIN-XXXXXXXX`
      is functionally fine too).
- [ ] `slmgr /xpr` reports healthy activation (not "expired", not "notification
      mode") — no 60-minute reboot loop.
- [ ] `D:` data disk formatted, empty, ready for SQL data files (CDs detached
      or moved off `D:`/`E:`).
- [ ] `Get-Service QEMU-GA` → `Running`.
- [ ] RDP works from your Mac (port 3389 reachable, can log in as Administrator).
- [ ] `ssh administrator@<vm-endpoint>` works from your Mac (lands in PowerShell).
- [ ] `Get-Service SQLWriter` → `Running`.
- [ ] `sqlcmd -S . -E -Q "SELECT @@VERSION;"` (or `-S .\<INSTANCE>` for a
      named instance) returns a Developer Edition banner.
- [ ] Note the access path (direct? VPN? jump host?) so we can wire up
      `~/.ssh/config` if needed.

When all nine boxes are checked, ping me — next session configures the
Trilio backup target, writes the Python generator (`pyodbc`), and runs the
first backup.
