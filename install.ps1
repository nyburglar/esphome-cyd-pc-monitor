<#
.SYNOPSIS
    Installs the CYD PC Stats feeder and starts it at every login.

.DESCRIPTION
    - Creates a private Python environment in %LOCALAPPDATA%\CYD-PC-Stats
    - Installs the feeder script and its two dependencies (psutil, pyserial)
    - Registers a "CYD PC Stats Feeder" scheduled task that runs it hidden at login
    - Starts it right away

    Running it again upgrades an existing install. No admin rights needed.

.PARAMETER Port
    COM port of the CYD, e.g. COM5. By default the feeder finds it automatically.

.PARAMETER NoAutostart
    Install the feeder but don't create the login task or start it.

.PARAMETER InstallLibreHardwareMonitor
    Also install LibreHardwareMonitor with winget (needed for CPU temperature,
    CPU power and fan speeds).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    irm https://raw.githubusercontent.com/nyburglar/esphome-cyd-pc-monitor/main/install.ps1 | iex
#>
param(
    [string]$Port,
    [switch]$NoAutostart,
    [switch]$InstallLibreHardwareMonitor
)

$ErrorActionPreference = 'Stop'
$Repo = 'nyburglar/esphome-cyd-pc-monitor'
$Branch = 'main'
$InstallDir = Join-Path $env:LOCALAPPDATA 'CYD-PC-Stats'
$TaskName = 'CYD PC Stats Feeder'
$Files = @('feeder/pc_stats_feeder.py', 'feeder/requirements.txt', 'uninstall.ps1')

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Note($msg) { Write-Host "    $msg" }
function Write-Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Find-Python {
    # The py launcher first, then python on PATH. Skips the Microsoft Store "python" stub.
    foreach ($candidate in @(@('py', '-3'), @('python'), @('python3'))) {
        $exe = $candidate[0]
        $pre = @($candidate | Select-Object -Skip 1)
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
        try {
            $out = & $exe @pre -c 'import sys; print(int(sys.version_info >= (3, 9)))' 2>$null
        } catch { continue }
        if ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq '1') { return , (@($exe) + $pre) }
    }
    return $null
}

function Stop-Feeder {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -match '^pythonw?\.exe$' -and $_.CommandLine -match 'pc_stats_feeder\.py' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host 'CYD PC Stats - feeder installer' -ForegroundColor Green
Write-Host ''

# 1. Python ------------------------------------------------------------------------------
Write-Step 'Looking for Python 3.9 or newer'
$python = Find-Python
if (-not $python) {
    Write-Warn 'Python 3.9+ not found. Install it, then run this installer again:'
    Write-Warn '    winget install Python.Python.3.12'
    exit 1
}
$pyVersion = & $python[0] @($python | Select-Object -Skip 1) --version
Write-Note "Using $pyVersion ($($python -join ' '))"

# 2. Files -------------------------------------------------------------------------------
Write-Step "Installing to $InstallDir"
Stop-Feeder
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

$localRoot = if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'feeder\pc_stats_feeder.py'))) { $PSScriptRoot } else { $null }
if ($localRoot) {
    Write-Note "Copying files from $localRoot"
} else {
    Write-Note "Downloading files from github.com/$Repo"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}
foreach ($file in $Files) {
    $dest = Join-Path $InstallDir (Split-Path $file -Leaf)
    if ($localRoot) {
        Copy-Item -Path (Join-Path $localRoot $file) -Destination $dest -Force
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$Repo/$Branch/$file" -OutFile $dest
    }
}

# 3. Python environment ------------------------------------------------------------------
Write-Step 'Setting up the Python environment (psutil, pyserial)'
$venv = Join-Path $InstallDir 'venv'
$venvPython = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    & $python[0] @($python | Select-Object -Skip 1) -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw 'Creating the Python environment failed.' }
}
& $venvPython -m pip install --disable-pip-version-check --quiet --upgrade -r (Join-Path $InstallDir 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Installing Python packages failed.' }

# 4. LibreHardwareMonitor ----------------------------------------------------------------
Write-Step 'Checking LibreHardwareMonitor (CPU temperature, CPU power, fan speeds)'
$lhmRunning = [bool](Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue)
if (-not $lhmRunning -and $InstallLibreHardwareMonitor) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id LibreHardwareMonitor.LibreHardwareMonitor --exact --accept-source-agreements --accept-package-agreements
        Write-Note 'Installed. Start it as administrator and finish the setup below.'
    } else {
        Write-Warn 'winget is not available; download it from github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases'
    }
}
$lhmWeb = $false
try {
    $null = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:8085/data.json' -TimeoutSec 3
    $lhmWeb = $true
} catch { }
if ($lhmWeb) {
    Write-Note 'Web server is running on port 8085. All stats will be available.'
} else {
    if ($lhmRunning) { Write-Warn 'LibreHardwareMonitor is running, but its web server is off.' }
    else { Write-Warn 'LibreHardwareMonitor is not running. CPU temp, CPU power and fan speeds will show "--".' }
    Write-Warn 'To enable them: run LibreHardwareMonitor as administrator, then turn on'
    Write-Warn '  Options > Remote Web Server > Run   and   Options > Run On Windows Startup'
    if (-not $InstallLibreHardwareMonitor -and -not $lhmRunning) {
        Write-Warn 'Install it with:  winget install LibreHardwareMonitor.LibreHardwareMonitor'
    }
}

# 5. Login task --------------------------------------------------------------------------
$feederArgs = "`"$(Join-Path $InstallDir 'pc_stats_feeder.py')`" --log-file `"$(Join-Path $InstallDir 'feeder.log')`""
if ($Port) { $feederArgs += " --port $Port" }

if ($NoAutostart) {
    Write-Step 'Skipping the login task (-NoAutostart)'
    Write-Note "Run it manually with:  & `"$venvPython`" $feederArgs"
} else {
    Write-Step "Creating the '$TaskName' login task"
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute (Join-Path $venv 'Scripts\pythonw.exe') -Argument $feederArgs -WorkingDirectory $InstallDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'Sends PC temps and usage to a CYD display over USB serial.' -Force | Out-Null

    Write-Step 'Starting the feeder'
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 4
    $logFile = Join-Path $InstallDir 'feeder.log'
    if (Test-Path $logFile) { Get-Content $logFile -Tail 4 | ForEach-Object { Write-Note $_ } }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Note "Log file:   $(Join-Path $InstallDir 'feeder.log')"
Write-Note "Uninstall:  powershell -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'uninstall.ps1')`""
Write-Host ''
