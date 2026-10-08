# Shared helpers for install-windows.ps1 and cleanup-windows.ps1 (dot-sourced; not meant to be run directly).
# Compatible with Windows PowerShell 5.1 and PowerShell 7. Keep this file ASCII-only.

$script:StateDir   = Join-Path $env:LOCALAPPDATA 'scale-app'
$script:StateFile  = Join-Path $script:StateDir 'setup-state.json'
$script:IsDryRun   = $false
$script:Distro     = 'Ubuntu-24.04'
$script:MarkerDir  = '/var/lib/scale-app-setup'   # inside WSL: one file per tool the installer added

function Write-Step([string]$Message) { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "    [ok] $Message" -ForegroundColor Green }
function Write-Skip([string]$Message) { Write-Host "    [skip] $Message" -ForegroundColor DarkGray }
function Write-Warn2([string]$Message){ Write-Host "    [warn] $Message" -ForegroundColor Yellow }
function Write-Plan([string]$Message) { Write-Host "    [dry-run] would: $Message" -ForegroundColor Magenta }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Confirm-Action([string]$Question, [switch]$Assume) {
    if ($Assume -or $script:IsDryRun) { return $true }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^(y|yes)$')
}

# ---- persisted state (what the installer did, so cleanup only removes its own work) ----
function Get-SetupState {
    $h = @{}
    if (Test-Path $script:StateFile) {
        try {
            $o = Get-Content $script:StateFile -Raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch { }
    }
    return $h
}
function Save-SetupState([hashtable]$State) {
    if ($script:IsDryRun) { return }
    New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
    ($State | ConvertTo-Json -Depth 5) | Set-Content -Path $script:StateFile -Encoding UTF8
}

# ---- WSL helpers ----
function Convert-ToWslPath([string]$WindowsPath) {
    $p = $WindowsPath -replace '\\', '/'
    if ($p -match '^([A-Za-z]):(.*)$') { return '/mnt/' + $Matches[1].ToLower() + $Matches[2] }
    return $p
}

function Test-WslInstalled {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    & wsl.exe --version *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-WslDistros {
    # `wsl -l -q` prints UTF-16; strip the NUL characters the console decoding leaves behind.
    $raw = & wsl.exe -l -q 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    $text = (($raw | Out-String) -replace "`0", '')
    return @($text -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Runs a bash script inside the distro. The script is written to a temp file (LF endings, no BOM) because piping
# text into wsl.exe mangles encodings. -ReadOnly scripts also run during -DryRun; everything else is only described.
function Invoke-WslBash {
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Script,
        [string]$Describe = 'run a setup script inside WSL',
        [switch]$ReadOnly
    )
    if ($script:IsDryRun -and -not $ReadOnly) { Write-Plan "$Describe (as $User)"; return 0 }
    $tmp = Join-Path $env:TEMP ('scale-setup-' + [guid]::NewGuid().ToString('N') + '.sh')
    [IO.File]::WriteAllText($tmp, ($Script -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
    try {
        & wsl.exe -d $script:Distro -u $User -- bash (Convert-ToWslPath $tmp)
        return $LASTEXITCODE
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Same, but captures stdout (for small read-only queries). Never prints plans.
function Get-WslOutput {
    param([Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Script)
    $tmp = Join-Path $env:TEMP ('scale-setup-' + [guid]::NewGuid().ToString('N') + '.sh')
    [IO.File]::WriteAllText($tmp, ($Script -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding $false))
    try {
        $out = & wsl.exe -d $script:Distro -u $User -- bash (Convert-ToWslPath $tmp)
        return (($out | Out-String).Trim())
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Bash helpers prepended to scripts that edit /etc/wsl.conf or record what they installed.
$script:BashLib = @'
set_conf() {  # set_conf <section> <key> <value>  : idempotent edit of /etc/wsl.conf
  f=/etc/wsl.conf; touch "$f"
  if ! grep -q "^\[$1\]" "$f"; then printf '\n[%s]\n%s=%s\n' "$1" "$2" "$3" >> "$f"; return; fi
  if awk -v s="[$1]" -v k="$2" 'BEGIN{i=0;f=0} $0==s{i=1;next} /^\[/{i=0} i && $0 ~ "^"k"[ ]*="{f=1} END{exit !f}' "$f"; then
    awk -v s="[$1]" -v k="$2" -v v="$3" 'BEGIN{i=0} $0==s{i=1;print;next} /^\[/{i=0} i && $0 ~ "^"k"[ ]*="{print k"="v;next} {print}' "$f" > "$f.new" && mv "$f.new" "$f"
  else
    awk -v s="[$1]" -v k="$2" -v v="$3" '{print} $0==s{print k"="v}' "$f" > "$f.new" && mv "$f.new" "$f"
  fi
}
mark() { mkdir -p /var/lib/scale-app-setup; touch "/var/lib/scale-app-setup/installed-$1"; }
'@
