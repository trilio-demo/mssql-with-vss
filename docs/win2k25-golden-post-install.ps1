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
