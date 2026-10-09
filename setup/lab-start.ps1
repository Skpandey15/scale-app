<#
.SYNOPSIS
  Starts the Scale App lab ON DEMAND (Windows + WSL2).

.DESCRIPTION
  On a 16 GB PC the full cluster needs ~6.5 GB, so it must not auto-start every time WSL starts: Docker is disabled at boot on
  such a PC (see setup/README.md). This script starts Docker and then the cluster (ops/lab-up.sh = `k3d cluster start`),
  and finally checks that the app answers. If the saved state was oversized after a crash or overload, use -Recover to run the
  emergency path (ops/recover.sh), which shrinks the workloads first.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup\lab-start.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup\lab-start.ps1 -Recover
#>
[CmdletBinding()]
param([string]$Distro = 'Ubuntu-24.04', [switch]$Recover)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-windows.ps1')
$script:Distro = $Distro
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not (Test-WslInstalled) -or -not ((Get-WslDistros) -contains $Distro)) { throw "WSL distribution $Distro not found. Run setup\install-windows.ps1 first." }
$wslUser = (& wsl.exe -d $Distro -- whoami | Out-String).Trim()

Write-Step 'Starting Docker'
$c = Invoke-WslBash -User root -Script @'
systemctl start docker
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 0.5; done
docker info >/dev/null 2>&1
'@ -Describe 'start Docker'
if ($c -ne 0) { throw 'Could not start Docker inside WSL.' }

$wslRepo = (Convert-ToWslPath $RepoRoot).Replace("'", "'\''")
if ($Recover) {
    Write-Step 'Emergency start (ops/recover.sh): shrink workloads first, then start the workers'
    $c = Invoke-WslBash -User $wslUser -Script "cd '$wslRepo'`nbash ops/recover.sh`n" -Describe 'run ops/recover.sh'
} else {
    Write-Step 'Starting the cluster (ops/lab-up.sh), takes a few minutes'
    $c = Invoke-WslBash -User $wslUser -Script "cd '$wslRepo'`nbash ops/lab-up.sh`n" -Describe 'run ops/lab-up.sh'
}
if ($c -ne 0) { Write-Warn2 'The start script reported a problem (see above). If the machine was overloaded before, re-run with -Recover.' }

Write-Step 'Checking that the app answers (up to 2 minutes)'
$up = $false
for ($i = 0; $i -lt 24 -and -not $up; $i++) {
    try { $up = ((Invoke-WebRequest 'http://localhost:8088/api/posts' -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) } catch { Start-Sleep -Seconds 5 }
}
if (-not $up) { Write-Warn2 'The app is not answering yet. Check: wsl -d Ubuntu-24.04 -- kubectl -n scale get pods'; return }
Write-Ok 'app answers on http://localhost:8088'

Write-Step 'Lab is up'
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ('    Windows RAM free: {0:N1} GB of {1:N1} GB' -f ($os.FreePhysicalMemory / 1MB), ($os.TotalVisibleMemorySize / 1MB))
Write-Host '    App:        http://localhost:8088'
Write-Host '    Catalog:    http://localhost:8088/catalog/api/titles?q=matrix'
Write-Host '    Stop it:    powershell -ExecutionPolicy Bypass -File setup\lab-stop.ps1   (gives the memory back to Windows)'
