# Building the firmware yourself

You only need this to change the layout, colors or rotation. Otherwise, use the prebuilt firmware from [Releases](https://github.com/nyburglar/esphome-cyd-pc-monitor/releases/latest).

## Layout

| File | Purpose |
|---|---|
| `firmware/common.yaml` | Everything: hardware setup, serial parser, LVGL dashboard |
| `firmware/cyd-ili9341.yaml` | ILI9341 variant: sets `display_model` and `lvgl_rotation`, then includes `common.yaml` |
| `firmware/cyd-ili9342.yaml` | ILI9342 variant |
| `firmware/cyd-st7789.yaml` | ST7789 variant |

## Install ESPHome

ESPHome supports a narrower range of Python versions than the feeder. Python 3.12 is a safe choice:

```powershell
py -3.12 -m venv "$env:LOCALAPPDATA\esphome-venv"
& "$env:LOCALAPPDATA\esphome-venv\Scripts\python.exe" -m pip install esphome
```

## Compile and flash

Stop the feeder first, because only one program can use the COM port:

```powershell
Stop-ScheduledTask "CYD PC Stats Feeder"
```

Then compile and flash:

```powershell
$esphome = "$env:LOCALAPPDATA\esphome-venv\Scripts\esphome.exe"
& $esphome run firmware\cyd-ili9341.yaml --device COM3
```

When it's done, start the feeder again with `Start-ScheduledTask "CYD PC Stats Feeder"`.

If ESPHome can't put the board into flashing mode (`Wrong boot mode detected`), compile first. Then flash with esptool and hold **BOOT** while it connects:

```powershell
& $esphome compile firmware\cyd-ili9341.yaml
& "$env:LOCALAPPDATA\esphome-venv\Scripts\python.exe" -m esptool --chip esp32 --port COM3 --baud 460800 `
    --connect-attempts 0 write-flash -z 0x0 firmware\.esphome\build\cyd-pc-stats-ili9341\build\firmware.factory.bin
```

## Windows build problems

| Error | Fix |
|---|---|
| CMake `Failed to set working directory ... TryCompile` | The build path is longer than Windows' 260-character limit. Clone the repo to a short path such as `C:\src\cyd-pc-stats`. Or add `build_path: C:/esphome-build/cyd-pc-stats` under `esphome:` in `common.yaml`. |
| `Missing ESP-IDF tools: riscv32-esp-elf, dfu-util` | ESPHome downloaded only the ESP32 compiler, but ESP-IDF's environment check wants these two as well. Install them with ESP-IDF's own installer, then compile again. The `<version>` folders are under ESPHome's cache. |

The ESP-IDF install command:

```powershell
$env:IDF_TOOLS_PATH = "$env:LOCALAPPDATA\esphome\Cache\idf"
& "$env:LOCALAPPDATA\esphome\Cache\idf\penvs\<version>\Scripts\python.exe" `
  "$env:LOCALAPPDATA\esphome\Cache\idf\frameworks\<version>\tools\idf_tools.py" install riscv32-esp-elf dfu-util
```

## Things to change

- **Temperature colors**: `set_temp(id(cpu_temp_lbl), cpu_t, 70, 85)` in `common.yaml`. The last two numbers are the amber and red thresholds.
- **Rotation**: `lvgl_rotation` in your variant file. Add 180 to flip the picture.
- **Layout**: the `lvgl:` section of `common.yaml`. Positions are in pixels on the 320×240 landscape screen.
- **Offline behavior**: the `interval: 1s` block. The "Waiting for PC" box appears after 5 s without data, and the backlight dims after 60 s.

## The serial protocol

The CYD reads lines of `PCS,` followed by 12 comma-separated numbers. Any program can send them; the feeder is just one option. See the protocol section of the [README](../README.md#how-it-works).
