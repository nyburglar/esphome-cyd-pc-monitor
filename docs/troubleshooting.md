# Troubleshooting

## The display

| Symptom | Cause | Fix |
|---|---|---|
| Screen stays **white** | The firmware sends commands for a different display controller, so the panel never initializes. The backlight still turns on. | Flash another firmware variant. Order to try: ILI9341, then ILI9342, then ST7789. |
| Screen is **scrambled** or sheared | The controller accepts commands, but the image width or orientation is wrong. This happens, for example, with ILI9342 firmware on an ILI9341 panel. | Flash another firmware variant. |
| Picture is **upside down** | The panel is mounted the other way. | Build the firmware yourself and add 180 to `lvgl_rotation` in your variant file (see [building.md](building.md)). |
| **Red and blue swapped**, or colors look like a negative | The panel uses a different color order or inversion. | Build it yourself and add `color_order: rgb` (or `bgr`), or `invert_colors: true`, under `display:` in `firmware/common.yaml`. |
| **"Waiting for PC..."** stays up | No data is arriving. | See [the feeder](#the-feeder) below. |
| Screen dims | No data has arrived for 60 seconds. | It brightens again as soon as data arrives. |

## Flashing

| Symptom | Fix |
|---|---|
| `Wrong boot mode detected (0x13)` or `Failed to connect` | The board's auto-reset circuit didn't put the ESP32 into flashing mode. Start the flash, then **hold BOOT** while it connects. With esptool, `--connect-attempts 0` keeps retrying until you press it. |
| `Could not open COMx, the port is busy` | Another program has the port open: the feeder, SignalRGB, a serial monitor, or a slicer such as Cura. Stop the feeder with `Stop-ScheduledTask "CYD PC Stats Feeder"` and close the others. |
| No COM port appears | Try a different cable; many are charge-only. On USB‑C, use an A‑to‑C cable rather than C‑to‑C. Windows 10/11 usually installs the CH340 driver automatically. If it doesn't, install it from the chip maker, WCH. |

## The feeder

Check the log first:

```powershell
Get-Content "$env:LOCALAPPDATA\CYD-PC-Stats\feeder.log" -Tail 20
```

| Log message | Fix |
|---|---|
| `CYD not found (no CH340/CP210x COM port)` | The CYD isn't plugged in, or it uses a different USB chip. Run the installer with `-Port COMx`. |
| `could not open port ... Access is denied` | Another program has the port open. SignalRGB is a frequent cause because it probes every serial port for RGB devices; exclude the CYD's port in its settings. |
| `LibreHardwareMonitor: not reachable` | LibreHardwareMonitor isn't running, or its web server is off. If it has exited, the feeder restarts it automatically after 20 s. See below. |
| `its startup task couldn't be started` | The `LibreHardwareMonitor` task is missing. Run the installer again to recreate it. |
| `running but its web server isn't answering` | LibreHardwareMonitor's web server was turned off. Run the installer again, or turn on **Options → Remote Web Server → Run**. |

Check whether the feeder is running:

```powershell
Get-ScheduledTaskInfo "CYD PC Stats Feeder" | Select-Object LastRunTime, LastTaskResult
```

`267009` means "running". Any other value is the feeder's exit code. Run the feeder in a console to see the error:

```powershell
& "$env:LOCALAPPDATA\CYD-PC-Stats\venv\Scripts\python.exe" "$env:LOCALAPPDATA\CYD-PC-Stats\pc_stats_feeder.py" --dry-run
```

## LibreHardwareMonitor

| Symptom | Fix |
|---|---|
| CPU temperature and power drop out for under a minute, then come back | LibreHardwareMonitor crashed, and the feeder restarted it. The feeder log shows `restarted it through its startup task`. These are crashes inside LibreHardwareMonitor itself; Event Viewer → Windows Logs → Application has the details. |
| CPU temperature and power show `--` | Run the installer again. It reinstalls LibreHardwareMonitor if it's missing, turns its web server back on, and restarts it. To check by hand, open `http://localhost:8085` in a browser. |
| The installer says the UAC prompt was declined | LibreHardwareMonitor's setup needs one elevated step. Run the installer again and approve the prompt, or use `-SkipLibreHardwareMonitor`. |
| The web server is off again after changing settings by hand | LibreHardwareMonitor saves its settings only when it closes (**File → Exit** or Windows sign-out). If it's killed instead, changes are lost. Running the installer again writes them directly. |
| LibreHardwareMonitor isn't installed through winget | The installer finds it through its **LibreHardwareMonitor** startup task. If you have neither, it installs a copy with winget. |
| Wrong fan shown as "CPU" | Run `pc_stats_feeder.py --list-sensors`, find your CPU fan header, and pass `--cpu-fan "<name>"`. |
| GPU fan shows 0 rpm | Normal for many GPUs at idle. The fans stop below about 50–60°C. |
