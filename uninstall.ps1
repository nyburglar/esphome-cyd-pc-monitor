<#
.SYNOPSIS
    Removes the CYD PC Stats feeder: the login task, the running feeder and %LOCALAPPDATA%\CYD-PC-Stats.
    LibreHardwareMonitor and the firmware on the CYD are left alone.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
$ErrorActionPreference = 'Stop'
$InstallDir = Join-Path $env:LOCALAPPDATA 'CYD-PC-Stats'
$TaskName = 'CYD PC Stats Feeder'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "==> Removing the '$TaskName' login task" -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Write-Host '==> Stopping the feeder' -ForegroundColor Cyan
Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match '^pythonw?\.exe$' -and $_.CommandLine -match 'pc_stats_feeder\.py' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

if (Test-Path $InstallDir) {
    Write-Host "==> Deleting $InstallDir" -ForegroundColor Cyan
    Remove-Item -Path $InstallDir -Recurse -Force
}

Write-Host 'Done. LibreHardwareMonitor is still installed; remove it separately if you no longer need it.' -ForegroundColor Green
