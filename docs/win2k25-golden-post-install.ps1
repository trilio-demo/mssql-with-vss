# =========================================================================
# post-install.ps1 -- Windows Server 2025 golden image (Desktop Experience)
# Runs in audit mode (auditUser pass), once, before sysprep /generalize +
# ForceShutdownNow captures the image. Everything here lands in the image.
#
# Based on the stock windows2k25-autounattend post-install (virtio + QGA),
# extended with the OpenSSH bake proven working on this cluster (2026-06-15).
# 2025 needs NO edition conversion / no <servicing> block, so there is no
# Set-Edition (which broke sysprep on the 2022 attempt) -- this is clean.
# =========================================================================

# --- virtio guest drivers (required: KubeVirt disk/NIC) ------------------
Start-Process msiexec -Wait -ArgumentList "/i E:\virtio-win-gt-x64.msi /qn /passive /norestart"

# --- QEMU Guest Agent (LOAD-BEARING for the VSS lab; Trilio drives VSS via it) -
Start-Process msiexec -Wait -ArgumentList "/i E:\guest-agent\qemu-ga-x86_64.msi /qn /passive /norestart"

# --- OpenSSH Server via GitHub zip (Windows Update FOD is unreachable from
#     this bake cluster; github.com + release CDN ARE reachable -- verified
#     2026-06-15. Bake-time egress is this cluster's; once baked, clones need
#     no egress for SSH). ---------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$zip = 'C:\Windows\Temp\OpenSSH-Win64.zip'
Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip' -OutFile $zip
Expand-Archive -Path $zip -DestinationPath 'C:\Program Files\OpenSSH' -Force
# the zip extracts into a versioned subfolder (OpenSSH-Win64); flatten it
$src = (Get-ChildItem 'C:\Program Files\OpenSSH' -Directory | Select-Object -First 1).FullName
if ($src) { Move-Item "$src\*" 'C:\Program Files\OpenSSH\' -Force; Remove-Item $src -Recurse -Force }
powershell.exe -ExecutionPolicy Bypass -File 'C:\Program Files\OpenSSH\install-sshd.ps1'
Set-Service -Name sshd -StartupType Automatic    # Automatic, but do NOT start now
# Inbound 22 allow on ALL profiles. CRITICAL: KubeVirt masquerade networks are
# classified "Public" in the guest; a Private-only rule (the default some OpenSSH
# installs create) silently drops all inbound SSH from the pod/NodePort while
# sshd still answers on loopback. Force -Profile Any AND broaden any pre-existing
# OpenSSH rule the install may have created.
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
  -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any
Get-NetFirewallRule -DisplayName 'OpenSSH*' -ErrorAction SilentlyContinue | Set-NetFirewallRule -Profile Any
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
