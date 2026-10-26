<#
.SYNOPSIS
    Installs the CYD PC Stats feeder and LibreHardwareMonitor, and starts both at every login.

.DESCRIPTION
    - Creates a private Python environment in %LOCALAPPDATA%\CYD-PC-Stats
    - Installs the feeder script and its two dependencies (psutil, pyserial)
    - Registers a "CYD PC Stats Feeder" scheduled task that runs it hidden at login
    - Installs LibreHardwareMonitor with winget if it's missing, turns on its web server,
      and sets it to start minimized to the tray at login (one UAC prompt, because it
      needs admin rights to read CPU temperatures)
    - Starts everything right away

    Running it again upgrades an existing install.

.PARAMETER Port
    COM port of the CYD, e.g. COM5. By default the feeder finds it automatically.

.PARAMETER NoAutostart
    Install the feeder but don't create the login task or start it.

.PARAMETER SkipLibreHardwareMonitor
    Don't install or configure LibreHardwareMonitor. CPU temperature, CPU power and
    fan speeds will show "--"; everything else still works.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    irm https://raw.githubusercontent.com/nyburglar/esphome-cyd-pc-monitor/main/install.ps1 | iex
#>
param(
    [string]$Port,
    [switch]$NoAutostart,
    [switch]$SkipLibreHardwareMonitor
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

function Find-LibreHardwareMonitor {
    # Its own startup task, then the winget install location.
    $task = Get-ScheduledTask -TaskName 'LibreHardwareMonitor' -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) {
        $exe = $task.Actions | Where-Object { $_.Execute -match 'LibreHardwareMonitor\.exe$' } | Select-Object -First 1 -ExpandProperty Execute
        if ($exe -and (Test-Path $exe)) { return $exe }
    }
    $packages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    $found = Get-ChildItem $packages -Directory -Filter 'LibreHardwareMonitor.LibreHardwareMonitor_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'LibreHardwareMonitor.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    return $found
}

# Runs elevated: stops LibreHardwareMonitor without letting it save (it rewrites its settings
# file on exit), turns on the web server, start-minimized and minimize-to-tray in that file,
# registers the same startup task as its own "Run On Windows Startup" option, and starts it.
$LhmSetupScript = @'
$ErrorActionPreference = 'Stop'
$exe = '__EXE__'
$user = '__USER__'
Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800

$config = [IO.Path]::ChangeExtension($exe, '.config')
$doc = New-Object System.Xml.XmlDocument
if (Test-Path $config) { $doc.Load($config) }
else { $doc.LoadXml('<?xml version="1.0" encoding="utf-8"?><configuration><appSettings /></configuration>') }
$appSettings = $doc.SelectSingleNode('/configuration/appSettings')
$wanted = [ordered]@{ runWebServerMenuItem = 'true'; listenerPort = '8085'; startMinMenuItem = 'true'; minTrayMenuItem = 'true' }
foreach ($key in $wanted.Keys) {
    $node = $appSettings.SelectSingleNode("add[@key='$key']")
    if (-not $node) {
        $node = $doc.CreateElement('add')
        $node.SetAttribute('key', $key)
        [void]$appSettings.AppendChild($node)
    }
    $node.SetAttribute('value', $wanted[$key])
}
$doc.Save($config)

$action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory (Split-Path $exe)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'LibreHardwareMonitor' -TaskPath '\' -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Starts LibreHardwareMonitor on Windows startup.' -Force | Out-Null
Start-ScheduledTask -TaskName 'LibreHardwareMonitor'
'@

function Test-LhmWebServer {
    try {
        $null = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:8085/data.json' -TimeoutSec 3
        return $true
    } catch { return $false }
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
if ($SkipLibreHardwareMonitor) {
    Write-Step 'Skipping LibreHardwareMonitor (-SkipLibreHardwareMonitor)'
} else {
    Write-Step 'Setting up LibreHardwareMonitor (CPU temperature, CPU power, fan speeds)'
    $lhmExe = Find-LibreHardwareMonitor
    if (-not $lhmExe) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Note 'Installing it with winget...'
            winget install --id LibreHardwareMonitor.LibreHardwareMonitor --exact --silent `
                --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
            $lhmExe = Find-LibreHardwareMonitor
            if (-not $lhmExe) { Write-Warn "winget couldn't install it (exit code $LASTEXITCODE)." }
        } else {
            Write-Warn 'winget is not available.'
        }
    }

    $lhmReady = $false
    if ($lhmExe) {
        Write-Note "Using $lhmExe"
        Write-Note 'Turning on its web server and startup task. Approve the UAC prompt;'
        Write-Note 'it needs admin rights to read CPU sensors.'
        $script = $LhmSetupScript.Replace('__EXE__', $lhmExe.Replace("'", "''")).Replace('__USER__', "$env:USERDOMAIN\$env:USERNAME".Replace("'", "''"))
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $elevatedOk = $false
        try {
            $proc = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
            $elevatedOk = ($proc.ExitCode -eq 0)
            if (-not $elevatedOk) { Write-Warn "The setup step failed (exit code $($proc.ExitCode))." }
        } catch {
            Write-Warn 'The UAC prompt was declined or failed.'
        }
        if ($elevatedOk) {
            for ($i = 0; $i -lt 20 -and -not $lhmReady; $i++) {
                $lhmReady = Test-LhmWebServer
                if (-not $lhmReady) { Start-Sleep -Seconds 2 }
            }
            if (-not $lhmReady) { Write-Warn 'LibreHardwareMonitor started, but its web server did not answer on port 8085.' }
        }
    }

    if ($lhmReady) {
        Write-Note 'Running in the tray with its web server on port 8085, and starts at login.'
    } else {
        Write-Warn 'CPU temperature, CPU power and fan speeds will show "--" until this is fixed.'
        Write-Warn 'Run this installer again, or set it up by hand: install LibreHardwareMonitor'
        Write-Warn '(winget install LibreHardwareMonitor.LibreHardwareMonitor), run it as administrator,'
        Write-Warn 'and turn on Options > Remote Web Server > Run and Options > Run On Windows Startup.'
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
