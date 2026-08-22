# =========================================================================
# post-install.ps1 -- Windows Server 2025 golden image (Desktop Experience)
# Runs in audit mode (auditUser pass), once, before sysprep /generalize +
# ForceShutdownNow captures the image. Everything here lands in the image.
#
# Based on the stock windows2k25-autounattend post-install (virtio + QGA),
# plus: enable the INBOX OpenSSH Server (2025 ships it installed -- corrected
# 2026-06-18 after a GitHub-zip install was found to break the inbox firewall
# rule's app-lock) and a host-key wipe. 2025 needs NO edition conversion /
# no <servicing> block, so there is no Set-Edition (which broke sysprep on the
# 2022 attempt) -- this is clean.
# =========================================================================

# --- virtio guest drivers (required: KubeVirt disk/NIC) ------------------
Start-Process msiexec -Wait -ArgumentList "/i E:\virtio-win-gt-x64.msi /qn /passive /norestart"

# --- QEMU Guest Agent (LOAD-BEARING for the VSS lab; Trilio drives VSS via it) -
Start-Process msiexec -Wait -ArgumentList "/i E:\guest-agent\qemu-ga-x86_64.msi /qn /passive /norestart"

# --- NIC MTU 1400, set early (insurance) ---------------------------------
# Windows ignores the DHCP-advertised MTU and stays at 1500; on a 1400 OVN
# overlay that black-holes large HTTPS transfers and activation (slmgr /ato ->
# 0x80072EE2). Isolated to MTU by an A/B test 2026-06-18 (1400 -> 4.6 MB in
# 1.4 s; 1500 -> stall/timeout, same URL/path).
# NOTE: this bake-time setting does NOT survive sysprep /generalize (the clone
# re-enumerates its NIC), so the EFFECTIVE fix is clone-side in unattend.xml
# Order 4 (before /ato). Kept here as harmless early insurance in case anything
# in audit mode ever needs the network -- today nothing does (SSH is inbox,
# virtio/QGA come from the local ISO).
netsh interface ipv4 set subinterface "Ethernet" mtu=1400 store=persistent

# --- OpenSSH Server: USE THE INBOX install (Server 2025 ships it) ----------
# Windows Server 2025 ships OpenSSH Server as an *installed* inbox capability
# (OpenSSH.Server = Installed; binaries at %SystemRoot%\system32\OpenSSH;
# `sshd` service registered; a predefined firewall rule 'OpenSSH-Server-In-TCP'
# app-locked to %SystemRoot%\system32\OpenSSH\sshd.exe). So NO download is
# needed -- and do NOT GitHub-zip install: that drops a second sshd in
# C:\Program Files\OpenSSH and repoints the service there, away from the path
# the inbox firewall rule expects, which silently blocks inbound SSH (caught
# 2026-06-18 validating a clone of the prior bake). Just enable the inbox
# service and broaden its (already app-matched) firewall rule to all profiles
# -- the KubeVirt masquerade network is classified "Public" in the guest, and a
# Private-only rule would drop all inbound SSH while sshd answers on loopback.
# (Server 2022 does NOT ship OpenSSH inbox -> its golden recipe keeps the
# GitHub-zip + uniquely-named port-based rule approach.)
Set-Service -Name sshd -StartupType Automatic    # Automatic, but do NOT start now
Get-NetFirewallRule -DisplayName 'OpenSSH*' -ErrorAction SilentlyContinue |
  Set-NetFirewallRule -Profile Any -Enabled True
# DefaultShell = PowerShell (so SSH sessions land in PS, not cmd)
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force

# =========================================================================
# Image slimming (part 2 of 2) -- shrink what gets captured into the golden
# =========================================================================
# Part 1 ran in the `specialize` pass of win2k25-golden-autounattend.xml: it
# disabled the pagefile via the registry. Windows Setup then rebooted twice
# (specialize -> oobeSystem/Reseal=Audit -> audit mode), which RELEASED
# pagefile.sys -- an active pagefile cannot be deleted, which is why the
# disable has to happen a pass earlier than this script.
#
# Why bother: every byte here is paid for FOUR times -- the golden DV, the
# containerDisk push/pull to the registry, every clone's root disk, and every
# Trilio backup of every clone. The 2026-05 golden (~21 Gi virtual) backed up
# at 17.85 GiB / 7m52s; a RAM-sized pagefile was a large chunk of that.

$freeBefore = (Get-PSDrive C).Free

# Hibernation: deletes hiberfil.sys IMMEDIATELY (no reboot needed). Server
# SKUs often ship with hibernation already off -- then this is a harmless no-op.
powercfg.exe /hibernate off 2>&1 | Out-Null

# The now-released pagefile (and the compressed-memory swapfile).
Remove-Item 'C:\pagefile.sys','C:\swapfile.sys' -Force -ErrorAction SilentlyContinue

# WinSxS component store: drop superseded components. /ResetBase makes the
# installed updates non-uninstallable -- fine for a disposable lab golden.
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet /NoRestart

# Transient caches that have no business being in a golden image.
Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Users\*\AppData\Local\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Logs\CBS\*' -Recurse -Force -ErrorAction SilentlyContinue
Clear-RecycleBin -Force -ErrorAction SilentlyContinue

# Re-arm AUTOMATIC pagefile management. NOTE: this write does NOT reliably
# survive `sysprep /generalize` -- a clone of the 2026-08-22 bake came up with
# AutomaticManagedPagefile=False and NO pagefile at all, which SQL Server needs.
# So this is best-effort belt-and-braces only; the AUTHORITATIVE fix is
# clone-side, in docs/unattend.xml FirstLogonCommands, which sets it via WMI on
# first boot. Do not remove that step on the assumption this one works.
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v AutomaticManagedPagefile /t REG_DWORD /d 1 /f

# TRIM: tell the virtio blk layer which blocks are free again, so they read as
# unallocated in the captured disk instead of as stale data. This is what turns
# the deletions above into an actually smaller image / backup.
Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue

# --- Remove the WinRE recovery partition so C: is the LAST partition -------
# Windows Setup silently appends a ~789 MB Recovery partition AFTER the OS
# partition, even though this answer file defines the layout explicitly. That
# is fatal for a golden image: a clone provisioned on a BIGGER disk gets its
# extra space as a tail BEYOND the recovery partition, so C: has no CONTIGUOUS
# free space and can never be extended -- the extra capacity is stranded.
# (Caught 2026-08-22: a 24 Gi clone of the 20 Gi golden stranded 4 GB, and
# Get-PartitionSupportedSize reported max == current.)
#
# `reagentc /disable` first relocates winre.wim into C:\Windows\System32\Recovery,
# so only the separate recovery PARTITION goes away.
#
# ⚠️ Implemented with diskpart, NOT the Storage module. `Get-Partition
# -DiskNumber 0` was verified to return NOTHING in a non-interactive SYSTEM
# context (2026-08-22) -- a Get-Partition-based version would silently no-op
# and cost a whole rebake to discover. diskpart is a standalone binary and was
# verified working in the same context. `delete partition override` is also
# mandatory: recovery partitions are protected and a plain delete refuses.
reagentc.exe /disable 2>&1 | Out-Null

$lp = "select disk 0" + [char]13 + [char]10 + "list partition"
$lp | Out-File -FilePath 'C:\Windows\Temp\lp.txt' -Encoding ascii
$parts = & diskpart.exe /s 'C:\Windows\Temp\lp.txt'
$recNums = @($parts | Select-String -Pattern '^\s*Partition\s+(\d+)\s+Recovery' |
             ForEach-Object { $_.Matches[0].Groups[1].Value })
foreach ($n in $recNums) {
  ("select disk 0" + [char]13 + [char]10 + "select partition " + $n + [char]13 + [char]10 + "delete partition override") |
    Out-File -FilePath 'C:\Windows\Temp\delrec.txt' -Encoding ascii
  & diskpart.exe /s 'C:\Windows\Temp\delrec.txt' | Out-Null
}

# `reagentc /disable` RELOCATES winre.wim (~500 MB) onto C: rather than
# discarding it, which would quietly eat much of the space just reclaimed. A
# lab clone has no use for the recovery environment, so drop the image too.
Remove-Item 'C:\Windows\System32\Recovery\Winre.wim' -Force -ErrorAction SilentlyContinue

# Re-list to confirm the removal actually happened (for the report below).
$lp | Out-File -FilePath 'C:\Windows\Temp\lp.txt' -Encoding ascii
$partsAfter = & diskpart.exe /s 'C:\Windows\Temp\lp.txt'
$recLeft = @($partsAfter | Select-String -Pattern '^\s*Partition\s+\d+\s+Recovery').Count
Remove-Item 'C:\Windows\Temp\lp.txt','C:\Windows\Temp\delrec.txt' -Force -ErrorAction SilentlyContinue

# NOTE: C: is deliberately NOT extended here. The golden stays sized to the
# build disk; each CLONE extends C: into its own free tail on first boot
# (docs/unattend.xml FirstLogonCommands). One golden then serves any clone size.

# Breadcrumb so a clone can confirm this pass ran. Records ABSOLUTE facts, not
# a free-space delta: the biggest saving -- never creating a pagefile -- happens
# back in the `specialize` pass, before this script starts measuring, so a delta
# reads as "~0 reclaimed" even when everything worked.
$c = Get-PSDrive C
# Detect the pagefile via WMI, NOT Test-Path. `Test-Path C:\pagefile.sys`
# returns False even when the pagefile exists -- it is a protected system file --
# so a Test-Path check silently reports "absent - correct" and would hide a
# slimming failure (verified 2026-08-22: Test-Path False while
# Win32_PageFileUsage reported C:\pagefile.sys at 1408 MB).
$pf = (Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue |
       Select-Object -First 1 -ExpandProperty AllocatedBaseSize)
@(
  "golden build: win2k25 (Server 2025 Standard, Desktop Experience)"
  "slimming pass ran  : $(Get-Date -Format s)"
  "C: size            = $([math]::Round(($c.Used + $c.Free)/1GB,2)) GiB"
  "C: used            = $([math]::Round($c.Used/1GB,2)) GiB"
  "C: free            = $([math]::Round($c.Free/1GB,2)) GiB"
  "pagefile           = $(if ($pf) { 'PRESENT ' + $pf + ' MB - slimming FAILED' } else { 'absent - correct' })"
  "recovery partitions= $recLeft (expected 0)"
  "recovery removed   = $($recNums.Count)"
) | Set-Content -Path 'C:\golden-build-report.txt' -Encoding ASCII

# --- Host-key wipe (each clone MUST generate unique SSH host keys) --------
# install-sshd.ps1 / any sshd start can create keys in C:\ProgramData\ssh.
# Captured into the image, every clone would share them. Last chance before
# generalize -- wipe; sshd regenerates per-clone on first boot. Do NOT bake
# authorized_keys (key upload stays a per-clone step).
Stop-Service sshd -ErrorAction SilentlyContinue
Remove-Item 'C:\ProgramData\ssh\ssh_host_*' -Force -ErrorAction SilentlyContinue

# --- Rename cached unattend.xml to avoid it being picked up by sysprep ----
mv C:\Windows\Panther\unattend.xml C:\Windows\Panther\unattend.install.xml

# --- Eject CD so the unattend.xml on it isn't picked up by sysprep --------
(New-Object -COMObject Shell.Application).NameSpace(17).ParseName("F:").InvokeVerb("Eject")
