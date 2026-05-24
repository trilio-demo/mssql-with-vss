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
4. **Disks:** keep the default boot disk, then **Add disk**:
   - Name: `data`
   - Source: Blank
   - Size: **40 GiB**
   - StorageClass: leave as default (picks up `px-csi-replicated`).
   - Type: Disk (block / virtio).
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

### 4b. Initialize and format the data disk

The OCPv catalog template attaches a **virtio-win drivers CD-ROM** as a
containerDisk (Balloon, NetKVM, viostor, vioscsi, etc.). Windows grabs the
first free letter for it — usually `D:` — before our data disk is online.
Reassign it to `X:` first so `D:` is free for the data disk:

```powershell
Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='D:'" |
  Set-CimInstance -Property @{DriveLetter='X:'}
```

Then initialize and format the data disk:

```powershell
Get-Disk | Where-Object PartitionStyle -eq 'RAW' |
  Initialize-Disk -PartitionStyle GPT -PassThru |
  New-Partition -DriveLetter D -UseMaximumSize |
  Format-Volume -FileSystem NTFS -NewFileSystemLabel "Data" -Confirm:$false
```

`D:` should now exist and be empty (and the virtio CD lives on `X:`).

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
   - **Default instance** (`MSSQLSERVER`).
   - **Mixed Mode** auth. Strong `sa` password. Add Administrator as a SQL admin.
   - **Data directories:** point everything at `D:\` —
     `D:\MSSQL\Data`, `D:\MSSQL\Log`, `D:\MSSQL\Backup`. Keeps the FLR story
     clean (SQL files live on the data disk, not `C:`).
3. Install **SSMS** (Management Studio) separately — also free, link on the
   same page.
4. Verify the **VSS Writer** service:

   ```powershell
   Get-Service SQLWriter
   ```

   Status: `Running`, StartType: `Automatic` (default). **This is the writer
   QGA's freeze signal will engage.**

5. Sanity check the engine:

   ```powershell
   sqlcmd -S . -E -Q "SELECT @@VERSION;"
   ```

   Should return a Developer Edition banner.

## 7. Done-state checklist

- [ ] VM running on `ocp-px` in `mssql-vss-lab`, Windows Server 2022, hostname `mssql-lab`.
- [ ] `D:` data disk formatted, empty, ready for SQL data files.
- [ ] `Get-Service QEMU-GA` → `Running`.
- [ ] RDP works from your Mac (port 3389 reachable, can log in as Administrator).
- [ ] `ssh administrator@<vm-endpoint>` works from your Mac (lands in PowerShell).
- [ ] `Get-Service SQLWriter` → `Running`.
- [ ] `sqlcmd -S . -E -Q "SELECT @@VERSION;"` returns a Developer Edition banner.
- [ ] Note the access path (direct? VPN? jump host?) so we can wire up
      `~/.ssh/config` if needed.

When all eight boxes are checked, ping me — next session configures the
Trilio backup target, writes the Python generator (`pyodbc`), and runs the
first backup.
