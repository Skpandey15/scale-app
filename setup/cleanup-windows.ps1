<#
.SYNOPSIS
  Removes Scale App from Windows, in layers. By default only the app (the k3d cluster and the images built for it).

.DESCRIPTION
  Layers, from least to most destructive:
    (default)          delete the k3d cluster "scale" (ALL its data: Postgres, Mongo, Kafka, backups in the cluster) and the
                       scale-backend / scale-web / scale-catalog images.
    -RemoveBackups     also delete the off-cluster backup copy (~/scale-app-offsite-backups inside WSL).
    -RemoveTools       also uninstall Docker Engine / k3d / kubectl, but ONLY those the installer added
                       (recorded in /var/lib/scale-app-setup inside WSL). Use -Force for tools it did not add.
    -RemoveWsl         also UNREGISTER the Ubuntu distribution: deletes everything in it, permanently.
                       Only if the installer created it (or -Force). Needs you to type the distro name.
    -RestoreWslConfig  put back the .wslconfig the installer backed up (or delete the one it created).
  Windows features (WSL, Virtual Machine Platform) are never touched.

.PARAMETER DryRun  Show what would be removed, change nothing.
.PARAMETER Yes     Skip the confirmation prompt (the typed confirmation for -RemoveWsl is still required unless -Force).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup\cleanup-windows.ps1 -DryRun
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup\cleanup-windows.ps1 -RemoveTools -RemoveBackups
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [switch]$RemoveBackups,
    [switch]$RemoveTools,
    [switch]$RemoveWsl,
    [switch]$RestoreWslConfig,
    [switch]$Force,
    [switch]$Yes,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-windows.ps1')
$script:Distro   = $Distro
$script:IsDryRun = [bool]$DryRun
$state = Get-SetupState
if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed.' -ForegroundColor Magenta }

Write-Step 'What this will do'
Write-Host "    - delete the k3d cluster 'scale' and ALL data in it (Postgres, Kafka, in-cluster backups)"
Write-Host '    - delete the scale-backend, scale-web and scale-catalog Docker images'
if ($RemoveBackups)     { Write-Host '    - delete the off-cluster backup copy (~/scale-app-offsite-backups in WSL)' }
if ($RemoveTools)       { Write-Host '    - uninstall Docker Engine / k3d / kubectl that the installer added' }
if ($RemoveWsl)         { Write-Host "    - UNREGISTER $Distro (deletes everything inside it)" -ForegroundColor Yellow }
if ($RestoreWslConfig)  { Write-Host '    - restore / remove .wslconfig as the installer found it' }
if (-not (Confirm-Action 'Continue?' -Assume:$Yes)) { Write-Host 'Aborted.'; return }

$distroPresent = $false
if (Test-WslInstalled) { $distroPresent = (Get-WslDistros) -contains $Distro }
if (-not $distroPresent) {
    Write-Skip "$Distro is not installed: nothing to remove inside WSL"
} else {
    $user = (& wsl.exe -d $Distro -- whoami | Out-String).Trim()

    # ---------------------------------------------------------------- app: cluster + images (+ backups)
    Write-Step 'Removing the cluster and images'
    $app = @'
set +e
if ! docker info >/dev/null 2>&1; then
  echo "[warn] Docker is not running, so the cluster cannot be deleted now. Start Docker (sudo systemctl start docker) and re-run."
  exit 0
fi
if command -v k3d >/dev/null 2>&1 && k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx scale; then
  k3d cluster delete scale && echo "[ok] cluster deleted"
else
  echo "[skip] no cluster named scale"
fi
for img in scale-backend:1.0 scale-web:1.0 scale-catalog:1.0; do
  if docker image inspect "$img" >/dev/null 2>&1; then docker rmi -f "$img" >/dev/null && echo "[ok] removed image $img"; else echo "[skip] image $img not present"; fi
done
'@
    if ($RemoveBackups) {
        $app += @'

BK="${SCALE_OFFSITE_DIR:-$HOME/scale-app-offsite-backups}"
if [ -d "$BK" ]; then rm -rf -- "$BK" && echo "[ok] removed $BK"; else echo "[skip] no backup copy at $BK"; fi
'@
    }
    $what = 'delete the k3d cluster and the scale-backend/scale-web/scale-catalog images'
    if ($RemoveBackups) { $what += ' and the off-cluster backup copy' }
    $null = Invoke-WslBash -User $user -Script $app -Describe $what

    # ---------------------------------------------------------------- tools
    if ($RemoveTools) {
        Write-Step 'Removing tools the installer added'
        $forceFlag = if ($Force) { '1' } else { '0' }
        $tools = @'
set +e
FORCE=__FORCE__
MD=/var/lib/scale-app-setup
want() { [ "$FORCE" = 1 ] || [ -f "$MD/installed-$1" ]; }
if want kubectl && [ -f /usr/local/bin/kubectl ]; then rm -f /usr/local/bin/kubectl && echo "[ok] removed kubectl"; else echo "[skip] kubectl (not added by the installer, or absent)"; fi
if want k3d && [ -f /usr/local/bin/k3d ]; then rm -f /usr/local/bin/k3d && echo "[ok] removed k3d"; else echo "[skip] k3d (not added by the installer, or absent)"; fi
if want docker && command -v dockerd >/dev/null 2>&1; then
  systemctl disable --now docker docker.socket containerd >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras >/dev/null 2>&1
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
  rm -rf /var/lib/docker /var/lib/containerd
  echo "[ok] removed Docker Engine and its images/volumes"
else
  echo "[skip] Docker Engine (not added by the installer, or absent)"
fi
rm -f "$MD"/installed-* 2>/dev/null; rmdir "$MD" 2>/dev/null
exit 0
'@
        $tools = $tools.Replace('__FORCE__', $forceFlag)
        $null = Invoke-WslBash -User root -Script $tools -Describe 'uninstall Docker Engine / k3d / kubectl that the installer added'
    }
}

# ---------------------------------------------------------------- distro
if ($RemoveWsl) {
    Write-Step "Unregistering $Distro"
    $ours = ($state.ContainsKey('distroCreatedBySetup') -and $state['distroCreatedBySetup'])
    if (-not $distroPresent) {
        Write-Skip "$Distro is not installed"
    } elseif (-not $ours -and -not $Force) {
        Write-Warn2 "$Distro was not created by the installer, so it is NOT removed (it may hold your own files). Use -Force if you really want that."
    } elseif ($DryRun) {
        Write-Plan "wsl --unregister $Distro (this deletes the whole distribution, including your home directory)"
    } else {
        Write-Host "    This permanently deletes EVERYTHING inside $Distro." -ForegroundColor Yellow
        $typed = Read-Host "    Type the distribution name ($Distro) to confirm"
        if ($typed -eq $Distro) { & wsl.exe --unregister $Distro; Write-Ok "$Distro unregistered" }
        else { Write-Skip 'name did not match: distribution kept' }
    }
}

# ---------------------------------------------------------------- .wslconfig
if ($RestoreWslConfig) {
    Write-Step 'Restoring .wslconfig'
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    if ($state.ContainsKey('wslconfigBackup') -and (Test-Path $state['wslconfigBackup'])) {
        if ($DryRun) { Write-Plan "restore $cfg from $($state['wslconfigBackup'])" }
        else { Copy-Item $state['wslconfigBackup'] $cfg -Force; Remove-Item $state['wslconfigBackup'] -Force; Write-Ok '.wslconfig restored' }
    } elseif ($state.ContainsKey('wslconfigCreatedBySetup') -and (Test-Path $cfg)) {
        if ($DryRun) { Write-Plan "delete $cfg (the installer created it)" }
        else { Remove-Item $cfg -Force; Write-Ok '.wslconfig removed' }
    } else { Write-Skip 'the installer did not change .wslconfig' }
    if (-not $DryRun) { Write-Host '    Run "wsl --shutdown" for this to take effect.' }
}

# ---------------------------------------------------------------- state file
if (-not $DryRun -and ($RemoveWsl -or -not $distroPresent) -and (Test-Path $script:StateFile)) {
    Remove-Item $script:StateFile -Force
}

Write-Step 'Done'
Write-Host '    Not touched: the Windows features WSL / Virtual Machine Platform, and this repository folder.'
Write-Host '    To also disable those features (rarely needed), use "Turn Windows features on or off".'
