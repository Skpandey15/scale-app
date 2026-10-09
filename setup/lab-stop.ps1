<#
.SYNOPSIS
  Stops the Scale App lab gracefully and hands the memory back to Windows.

.DESCRIPTION
  Stops the k3d cluster (graceful: databases get to shut down cleanly), stops Docker, then shuts down the WSL VM so Windows gets
  its RAM back immediately. Data is kept on the persistent volumes; start again with setup\lab-start.ps1.
  Use -KeepWsl to leave the WSL VM running (e.g. if you have other WSL work open).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup\lab-stop.ps1
#>
[CmdletBinding()]
param([string]$Distro = 'Ubuntu-24.04', [switch]$KeepWsl)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-windows.ps1')
$script:Distro = $Distro

if (-not (Test-WslInstalled) -or -not ((Get-WslDistros) -contains $Distro)) { Write-Skip "$Distro not installed: nothing to stop"; return }
$running = (& wsl.exe --list --running 2>$null | Out-String) -replace "`0", ''
if ($running -notmatch [regex]::Escape($Distro)) { Write-Skip 'WSL is not running: nothing to stop'; return }
$wslUser = (& wsl.exe -d $Distro -- whoami | Out-String).Trim()

Write-Step 'Stopping the cluster gracefully (first shrinking the saved state so the next start is safe)'
$stop = @'
if docker info >/dev/null 2>&1 && command -v k3d >/dev/null 2>&1; then
  # The saved replica counts are what the next start brings up. Never leave an autoscaler run-away or Kafka UI in it.
  kubectl --request-timeout=30s -n scale scale deploy/backend --replicas=3 >/dev/null 2>&1 || true
  kubectl --request-timeout=30s -n scale scale deploy/catalog --replicas=2 >/dev/null 2>&1 || true
  kubectl --request-timeout=30s -n scale scale deploy/kafka-ui --replicas=0 >/dev/null 2>&1 || true
  k3d cluster stop scale 2>&1 | tail -n 2
else
  echo "[skip] Docker is not running"
fi
true
'@
$null = Invoke-WslBash -User $wslUser -Script $stop -Describe 'k3d cluster stop scale'

Write-Step 'Stopping Docker'
$null = Invoke-WslBash -User root -Script 'systemctl stop docker.socket docker.service; true' -Describe 'stop Docker'

if (-not $KeepWsl) {
    Write-Step 'Shutting down the WSL VM (returns its memory to Windows)'
    & wsl.exe --shutdown
    Start-Sleep -Seconds 3
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Ok ('Windows now has {0:N1} GB free of {1:N1} GB' -f ($os.FreePhysicalMemory / 1MB), ($os.TotalVisibleMemorySize / 1MB))
}
Write-Host '    Start it again with: powershell -ExecutionPolicy Bypass -File setup\lab-start.ps1'
