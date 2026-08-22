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

# Re-arm AUTOMATIC pagefile management so CLONES get a proper pagefile (SQL
# Server wants one). Windows creates the file at BOOT, not on this write, so
# the captured image stays clean while every clone self-provisions one.
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v AutomaticManagedPagefile /t REG_DWORD /d 1 /f

# TRIM: tell the virtio blk layer which blocks are free again, so they read as
# unallocated in the captured disk instead of as stale data. This is what turns
# the deletions above into an actually smaller image / backup.
Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue

# Leave a breadcrumb so a clone can confirm the slimming pass actually ran.
$freeAfter = (Get-PSDrive C).Free
@(
  "golden build: win2k25 (Server 2025 Standard, Desktop Experience)"
  "slimming pass ran: $(Get-Date -Format s)"
  "C: free before = $([math]::Round($freeBefore/1GB,2)) GiB"
  "C: free after  = $([math]::Round($freeAfter /1GB,2)) GiB"
  "reclaimed      = $([math]::Round(($freeAfter-$freeBefore)/1GB,2)) GiB"
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
