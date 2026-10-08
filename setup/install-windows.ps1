<#
.SYNOPSIS
  Installs everything needed to run Scale App on Windows 10/11 and deploys it to a local k3d cluster.

.DESCRIPTION
  Uses WSL2 with Ubuntu 24.04. Inside WSL it installs Docker Engine (not Docker Desktop), k3d and kubectl, creates a
  k3d cluster named "scale" (1 server + 2 agents), then runs ops/deploy.sh from this repository.
  Safe to re-run: every step checks first and skips what is already done. Records what it changed in
  %LOCALAPPDATA%\scale-app\setup-state.json so cleanup-windows.ps1 only removes what this script added.

.PARAMETER Port         Host port for the app (default 8088).
.PARAMETER WslMemoryGB  If > 0, sets WSL's memory limit in %USERPROFILE%\.wslconfig (existing file is backed up).
                        The full stack needs about 8 GB inside WSL; the WSL default is 50% of RAM.
.PARAMETER SkipDeploy   Install the tooling and create the cluster, but do not deploy the app.
.PARAMETER DryRun       Print what would happen without changing anything (read-only checks still run).
.PARAMETER Yes          Do not ask for confirmation (needed for unattended use).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup\install-windows.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup\install-windows.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [ValidateRange(1024, 65535)][int]$Port = 8088,
    [int]$WslMemoryGB = 0,
    [switch]$SkipDeploy,
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-windows.ps1')
$script:Distro   = $Distro
$script:IsDryRun = [bool]$DryRun
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$state = Get-SetupState
if ($DryRun) { Write-Host 'DRY RUN: nothing will be changed. Read-only checks still run.' -ForegroundColor Magenta }

# ------------------------------------------------------------------ 1. this PC
Write-Step 'Checking this PC'
$os    = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
if ($build -lt 19041) { throw "Windows build $build is too old for WSL2 (need 19041 or newer)." }
$ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
Write-Ok "Windows build $build, $ramGB GB RAM"
if ($ramGB -lt 12) { Write-Warn2 "Only $ramGB GB RAM: the stack needs ~8 GB inside WSL, so 16 GB total is recommended. Expect pods to be OOM-killed on smaller machines." }
$cs = Get-CimInstance Win32_ComputerSystem
if (-not $cs.HypervisorPresent) { Write-Warn2 'No hypervisor detected. If WSL fails to start, enable virtualization (VT-x / SVM) in your BIOS/UEFI.' }

# ------------------------------------------------------------------ 2. WSL itself
Write-Step 'Checking WSL'
if (-not (Test-WslInstalled)) {
    if ($DryRun) {
        Write-Plan 'run "wsl --install --no-distribution" as administrator, then ask you to reboot and re-run this script'
        Write-Host '    (the remaining steps depend on WSL, so the dry run stops here)'
        return
    }
    if (-not (Test-IsAdmin)) {
        throw 'WSL is not installed. Open PowerShell as Administrator, run:  wsl --install --no-distribution   then reboot and run this script again.'
    }
    & wsl.exe --install --no-distribution
    Write-Warn2 'WSL was just installed. REBOOT Windows, then run this script again.'
    return
}
Write-Ok 'WSL is installed'

# ------------------------------------------------------------------ 3. the distribution
Write-Step "Checking the $Distro distribution"
$distros = Get-WslDistros
$distroPresent = $distros -contains $Distro
if ($distroPresent) {
    Write-Skip "$Distro already installed"
} else {
    if ($DryRun) { Write-Plan "install $Distro with: wsl --install -d $Distro --no-launch" }
    else {
        & wsl.exe --install -d $Distro --no-launch
        if ($LASTEXITCODE -ne 0) { throw "Installing $Distro failed. If it mentions features or virtualization, run this once from an Administrator PowerShell and reboot." }
        $state['distroCreatedBySetup'] = $true
        $state['distro'] = $Distro
        Save-SetupState $state
        $distroPresent = $true
        Write-Ok "$Distro installed"
    }
}
if (-not $distroPresent) { Write-Host '    (dry run: skipping the checks that need the distribution)'; return }

$code = Invoke-WslBash -User root -ReadOnly -Script 'true'
if ($code -ne 0) { throw "WSL could not start $Distro. Usually virtualization is disabled in the BIOS/UEFI, or a reboot is pending after enabling WSL." }
Write-Ok "$Distro starts"

# ------------------------------------------------------------------ 4. a normal Linux user (docker group, kubeconfig live in it)
Write-Step 'Checking the Linux user'
$wslUser = (& wsl.exe -d $Distro -- whoami | Out-String).Trim()
$readUser = $wslUser
if ($wslUser -eq 'root') {
    $candidate = ($env:USERNAME.ToLower() -replace '[^a-z0-9_]', '')
    if (-not $candidate -or $candidate -notmatch '^[a-z]') { $candidate = 'scale' }
    if ($candidate.Length -gt 30) { $candidate = $candidate.Substring(0, 30) }
    $script1 = $script:BashLib + @'
set -e
U='__USER__'
id -u "$U" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$U"
set_conf user default "$U"
'@
    $script1 = $script1.Replace('__USER__', $candidate)
    $c = Invoke-WslBash -User root -Script $script1 -Describe "create Linux user '$candidate' and make it the default"
    if ($c -ne 0) { throw 'Could not create the Linux user.' }
    if (-not $DryRun) {
        & wsl.exe --terminate $Distro | Out-Null
        $state['wslUserCreatedBySetup'] = $candidate
        Save-SetupState $state
    }
    $wslUser = $candidate
    if ($DryRun) { $readUser = 'root' }     # the user does not exist yet in a dry run: read-only queries run as root
    Write-Ok "using Linux user '$wslUser'"
} else {
    Write-Skip "default Linux user is '$wslUser'"
}

# ------------------------------------------------------------------ 5. systemd (needed to run Docker as a service)
Write-Step 'Checking systemd'
$init = Get-WslOutput -User root -Script 'ps -p 1 -o comm= | tr -d " "'
if ($init -eq 'systemd') {
    Write-Skip 'systemd is already PID 1'
} else {
    $c = Invoke-WslBash -User root -Script ($script:BashLib + "`nset_conf boot systemd true`n") -Describe 'enable systemd in /etc/wsl.conf'
    if (-not $DryRun) {
        & wsl.exe --terminate $Distro | Out-Null
        Start-Sleep -Seconds 3
        $init = Get-WslOutput -User root -Script 'ps -p 1 -o comm= | tr -d " "'
        if ($init -ne 'systemd') { throw 'systemd did not start after the restart. Run "wsl --shutdown" and try again.' }
        Write-Ok 'systemd enabled'
    }
}

# ------------------------------------------------------------------ 6. Docker Engine, k3d, kubectl
Write-Step 'Installing Docker Engine, k3d and kubectl inside WSL'
$tools = $script:BashLib + @'
set -e
export DEBIAN_FRONTEND=noninteractive
U='__USER__'
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg git >/dev/null
if docker info >/dev/null 2>&1; then
  echo "[skip] a Docker daemon is already reachable"
else
  echo "Installing Docker Engine..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  systemctl enable --now docker
  mark docker
fi
if [ "$U" != root ]; then usermod -aG docker "$U"; fi
if command -v k3d >/dev/null 2>&1; then echo "[skip] k3d already installed"; else
  echo "Installing k3d..."; curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash >/dev/null; mark k3d
fi
if command -v kubectl >/dev/null 2>&1; then echo "[skip] kubectl already installed"; else
  echo "Installing kubectl..."
  KV=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KV}/bin/linux/$(dpkg --print-architecture)/kubectl"
  chmod +x /usr/local/bin/kubectl; mark kubectl
fi
echo "[ok] tooling ready"
'@
$tools = $tools.Replace('__USER__', $wslUser)
$present = Get-WslOutput -User root -Script 'if docker info >/dev/null 2>&1; then d=1; else d=0; fi; if command -v k3d >/dev/null 2>&1; then k=1; else k=0; fi; if command -v kubectl >/dev/null 2>&1; then c=1; else c=0; fi; echo "$d$k$c"'
if ($DryRun -and $present -eq '111') {
    Write-Skip 'Docker, k3d and kubectl are already installed'
} else {
    $c = Invoke-WslBash -User root -Script $tools -Describe 'install Docker Engine, k3d and kubectl (each only if missing)'
    if ($c -ne 0) { throw 'Installing the tooling failed; see the output above.' }
    if (-not $DryRun) { & wsl.exe --terminate $Distro | Out-Null; Start-Sleep -Seconds 3 }   # new session picks up the docker group
}

# ------------------------------------------------------------------ 7. optional: WSL memory limit
if ($WslMemoryGB -gt 0) {
    Write-Step "Setting the WSL memory limit to $WslMemoryGB GB"
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    $current = if (Test-Path $cfg) { Get-Content $cfg -Raw } else { '' }
    if ($current -match "(?im)^\s*memory\s*=\s*${WslMemoryGB}GB\s*$") {
        Write-Skip 'already set'
    } elseif ($DryRun) {
        Write-Plan "write memory=${WslMemoryGB}GB to $cfg (backing up any existing file) and restart WSL"
    } elseif (Confirm-Action 'Applying this stops ALL running WSL distributions. Continue?' -Assume:$Yes) {
        if ((Test-Path $cfg) -and -not $state.ContainsKey('wslconfigBackup')) {
            Copy-Item $cfg "$cfg.scale-app.bak"; $state['wslconfigBackup'] = "$cfg.scale-app.bak"
        } elseif (-not (Test-Path $cfg)) { $state['wslconfigCreatedBySetup'] = $true }
        if ($current -match '(?im)^\s*\[wsl2\]') {
            if ($current -match '(?im)^\s*memory\s*=') { $new = [regex]::Replace($current, '(?im)^\s*memory\s*=.*$', "memory=${WslMemoryGB}GB") }
            else { $new = [regex]::Replace($current, '(?im)^(\s*\[wsl2\]\s*)$', "`$1`r`nmemory=${WslMemoryGB}GB") }
        } else { $new = $current.TrimEnd() + "`r`n[wsl2]`r`nmemory=${WslMemoryGB}GB`r`n" }
        Set-Content -Path $cfg -Value $new -Encoding ASCII
        Save-SetupState $state
        & wsl.exe --shutdown
        Start-Sleep -Seconds 5
        Write-Ok "WSL memory limit set to $WslMemoryGB GB"
    } else { Write-Skip 'left unchanged' }
}

# ------------------------------------------------------------------ 8. cluster
Write-Step "Creating the k3d cluster 'scale'"
$listening = $null
try { $listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue } catch { }
$clusterExists = (Get-WslOutput -User $readUser -Script 'k3d cluster list --no-headers 2>/dev/null | awk "{print \$1}" | grep -qx scale && echo yes || echo no') -eq 'yes'
if ($listening -and -not $clusterExists) { throw "Port $Port is already in use on this PC. Re-run with -Port <other>." }
$cluster = @'
set -e
docker info >/dev/null 2>&1 || { echo "Docker is not usable by $(whoami). Run 'wsl --shutdown' and try again."; exit 1; }
if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx scale; then
  echo "[skip] cluster 'scale' exists"; k3d cluster start scale >/dev/null 2>&1 || true
else
  k3d cluster create scale --servers 1 --agents 2 -p "__PORT__:80@loadbalancer" --wait
fi
'@
$cluster = $cluster.Replace('__PORT__', [string]$Port)
if ($DryRun -and $clusterExists) {
    Write-Skip "cluster 'scale' already exists"
} else {
    $c = Invoke-WslBash -User $wslUser -Script $cluster -Describe "create k3d cluster 'scale' (1 server + 2 agents, port $Port)"
    if ($c -ne 0) { throw 'Creating the cluster failed; see the output above.' }
}
if (-not $DryRun -and -not $clusterExists) { $state['clusterCreatedBySetup'] = $true; Save-SetupState $state }

# ------------------------------------------------------------------ 9. deploy
if ($SkipDeploy) {
    Write-Step 'Skipping the deploy (-SkipDeploy)'
} else {
    Write-Step 'Deploying the app (first run builds images and pulls ~4 GB: 10-20 minutes)'
    $wslRepo = (Convert-ToWslPath $RepoRoot).Replace("'", "'\''")
    $deploy = "set -e`ncd '$wslRepo'`nbash ops/deploy.sh`n"
    $c = Invoke-WslBash -User $wslUser -Script $deploy -Describe 'run ops/deploy.sh (build images, install the Postgres operator, apply manifests)'
    if ($c -ne 0) { throw 'Deploy failed. It is safe to re-run this script: finished steps are skipped.' }
}

# ------------------------------------------------------------------ done
if (-not $DryRun) {
    $state['installedAt'] = (Get-Date).ToString('s'); $state['repo'] = $RepoRoot
    Save-SetupState $state
}
Write-Step $(if ($DryRun) { 'Dry run complete (nothing was changed)' } else { 'Done' })
Write-Host "    App:       http://localhost:$Port"
Write-Host "    Kafka UI:  http://localhost:$Port/kafka-ui   (user: admin)"
Write-Host "    Password:  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((wsl -d $Distro -- kubectl -n scale get secret kafka-ui-auth -o jsonpath='{.data.password}')))"
Write-Host '    Remove it: powershell -ExecutionPolicy Bypass -File setup\cleanup-windows.ps1   (add -DryRun to preview)'
