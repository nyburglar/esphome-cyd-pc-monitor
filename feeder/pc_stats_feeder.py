"""Send PC temps and usage to the CYD over its USB serial port.

Sources, best first:
  * LibreHardwareMonitor's web server (Options > Remote Web Server > Run, port 8085):
    CPU temp/power, GPU stats, fan RPM.
  * psutil: CPU load and RAM (always available).
  * nvidia-smi: GPU stats if LibreHardwareMonitor isn't running.

Without LibreHardwareMonitor everything except CPU temp, CPU power and fan RPM still works.

Usage:
  python pc_stats_feeder.py                 # auto-detect the CYD's COM port
  python pc_stats_feeder.py --port COM5
  python pc_stats_feeder.py --list-sensors  # print LibreHardwareMonitor sensor names
  python pc_stats_feeder.py --dry-run       # print what would be sent
"""

import argparse
import json
import logging
import logging.handlers
import math
import re
import shutil
import subprocess
import sys
import time
import urllib.request

import psutil
import serial
from serial.tools import list_ports

__version__ = "1.0.0"

log = logging.getLogger("cyd-pc-stats")

LHM_URL = "http://localhost:8085/data.json"
# USB-serial chips used on CYD boards: WCH CH340/CH9102, Silicon Labs CP210x.
CYD_USB_VIDS = {0x1A86, 0x10C4}
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


# ---------------------------------------------------------------- LibreHardwareMonitor

def _parse_value(text):
    """'55.4 °C' -> 55.4, '6,144 MB' -> 6144.0 (also handles comma decimals)."""
    m = re.search(r"-?\d[\d.,]*", text or "")
    if not m:
        return None
    num = m.group(0)
    if "," in num and "." in num:
        num = num.replace(",", "")
    else:
        num = num.replace(",", ".")
    try:
        return float(num)
    except ValueError:
        return None


def read_lhm():
    """Return a flat list of (sensor_id, type, name, value) from LibreHardwareMonitor, or None."""
    try:
        with urllib.request.urlopen(LHM_URL, timeout=0.8) as resp:
            root = json.load(resp)
    except (OSError, ValueError):
        return None

    sensors = []

    def walk(node):
        sid = node.get("SensorId")
        if sid:
            sensors.append((sid, node.get("Type", ""), node.get("Text", ""), _parse_value(node.get("Value"))))
        for child in node.get("Children", []):
            walk(child)

    walk(root)
    return sensors


def _pick(sensors, prefixes, stype, names=(), contains=None):
    """First sensor matching hardware prefix + type, preferring names in order."""
    cands = [s for s in sensors if s[0].startswith(prefixes) and s[1] == stype and s[3] is not None]
    for name in names:
        for s in cands:
            if s[2].lower() == name.lower():
                return s[3]
    if contains:
        for s in cands:
            if contains.lower() in s[2].lower():
                return s[3]
    return None


CPU_HW = ("/amdcpu/", "/intelcpu/")


def gpu_prefix(sensors):
    # Prefer the discrete GPU; the Ryzen's integrated Radeon also shows up as /gpu-amd/.
    for prefix in ("/gpu-nvidia/", "/gpu-amd/", "/gpu-intel/"):
        if any(s[0].startswith(prefix) for s in sensors):
            return prefix
    return None


def stats_from_lhm(sensors, cpu_fan_name, gpu_fan_name):
    out = {}
    out["cpu_temp"] = _pick(sensors, CPU_HW, "Temperature",
                            ("Core (Tctl/Tdie)", "CPU Package", "Core (Tctl)", "Core (Tdie)", "Package"))
    out["cpu_load"] = _pick(sensors, CPU_HW, "Load", ("CPU Total",))
    out["cpu_power"] = _pick(sensors, CPU_HW, "Power", ("Package", "CPU Package"))

    gp = gpu_prefix(sensors)
    if gp:
        out["gpu_temp"] = _pick(sensors, gp, "Temperature", ("GPU Core",))
        out["gpu_load"] = _pick(sensors, gp, "Load", ("GPU Core",))
        out["gpu_power"] = _pick(sensors, gp, "Power", ("GPU Package", "GPU Power", "GPU Core"))
        used = _pick(sensors, gp, "SmallData", ("GPU Memory Used", "D3D Dedicated Memory Used"))
        total = _pick(sensors, gp, "SmallData", ("GPU Memory Total",))
        out["vram_used"] = used / 1024 if used is not None else None  # MB -> GB
        out["vram_total"] = total / 1024 if total is not None else None
        out["gpu_fan"] = _pick(sensors, gp, "Fan", (gpu_fan_name,) if gpu_fan_name else (), contains="fan")

    # Motherboard fan headers live under /lpc/ (Super I/O chip).
    fans = [s for s in sensors if s[0].startswith("/lpc/") and s[1] == "Fan" and s[3] is not None]
    if cpu_fan_name:
        out["cpu_fan"] = next((s[3] for s in fans if s[2].lower() == cpu_fan_name.lower()), None)
    else:
        named = [s for s in fans if "cpu" in s[2].lower()]
        spinning = [s for s in fans if s[3] > 0]
        out["cpu_fan"] = (named or spinning or [(None, None, None, None)])[0][3]
    return out


# ---------------------------------------------------------------- fallbacks

def stats_from_nvidia_smi():
    exe = shutil.which("nvidia-smi")
    if not exe:
        return {}
    try:
        res = subprocess.run(
            [exe, "--query-gpu=temperature.gpu,utilization.gpu,power.draw,memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=2, creationflags=NO_WINDOW)
        vals = [_parse_value(v) for v in res.stdout.splitlines()[0].split(",")]
    except (OSError, subprocess.SubprocessError, IndexError):
        return {}
    if len(vals) != 5:
        return {}
    t, load, power, used, total = vals
    return {"gpu_temp": t, "gpu_load": load, "gpu_power": power,
            "vram_used": used / 1024 if used is not None else None,
            "vram_total": total / 1024 if total is not None else None}


def collect(args):
    stats = {}
    sensors = read_lhm()
    if sensors:
        stats.update({k: v for k, v in stats_from_lhm(sensors, args.cpu_fan, args.gpu_fan).items() if v is not None})
    if any(k not in stats for k in ("gpu_temp", "gpu_load", "vram_used")):
        for k, v in stats_from_nvidia_smi().items():
            if v is not None:
                stats.setdefault(k, v)
    stats.setdefault("cpu_load", psutil.cpu_percent(interval=None))
    mem = psutil.virtual_memory()
    stats["ram_used"] = (mem.total - mem.available) / 1024**3
    stats["ram_total"] = mem.total / 1024**3
    return stats, sensors is not None


FIELDS = ("cpu_temp", "cpu_load", "cpu_power", "gpu_temp", "gpu_load", "gpu_power",
          "ram_used", "ram_total", "vram_used", "vram_total", "cpu_fan", "gpu_fan")


def format_line(stats):
    def fmt(v):
        return "" if v is None or (isinstance(v, float) and math.isnan(v)) else f"{v:.1f}"
    return "PCS," + ",".join(fmt(stats.get(f)) for f in FIELDS) + "\n"


# ---------------------------------------------------------------- serial

def find_port():
    ports = [p for p in list_ports.comports() if p.vid in CYD_USB_VIDS]
    return ports[0].device if ports else None


def open_port(name):
    ser = serial.Serial()
    ser.port = name
    ser.baudrate = 115200
    ser.write_timeout = 1
    # Keep DTR/RTS low so opening the port doesn't reset the ESP32 or put it in bootloader mode.
    ser.dtr = False
    ser.rts = False
    ser.open()
    return ser


def setup_logging(log_file, verbose):
    log.setLevel(logging.DEBUG if verbose else logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%d %H:%M:%S")
    if sys.stdout is not None:  # None under pythonw.exe
        console = logging.StreamHandler(sys.stdout)
        console.setFormatter(fmt)
        log.addHandler(console)
    if log_file:
        handler = logging.handlers.RotatingFileHandler(log_file, maxBytes=512_000, backupCount=1, encoding="utf-8")
        handler.setFormatter(fmt)
        log.addHandler(handler)


class StatusLog:
    """Log a status message only when it changes, so retry loops don't flood the log."""

    def __init__(self):
        self.last = None

    def __call__(self, msg):
        if msg != self.last:
            log.info(msg)
            self.last = msg


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="COM port of the CYD (default: auto-detect)")
    ap.add_argument("--interval", type=float, default=1.0, help="seconds between updates (default 1)")
    ap.add_argument("--cpu-fan", help="LibreHardwareMonitor name of the CPU fan header, e.g. 'Fan #2'")
    ap.add_argument("--gpu-fan", help="LibreHardwareMonitor name of the GPU fan, e.g. 'GPU Fan 1'")
    ap.add_argument("--list-sensors", action="store_true", help="print LibreHardwareMonitor sensors and exit")
    ap.add_argument("--dry-run", action="store_true", help="print lines instead of sending them")
    ap.add_argument("--log-file", help="also write status messages to this file (rotates at 500 KB)")
    ap.add_argument("-v", "--verbose", action="store_true", help="log every line sent")
    ap.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = ap.parse_args()
    setup_logging(args.log_file, args.verbose)

    if args.list_sensors:
        sensors = read_lhm()
        if sensors is None:
            sys.exit(f"LibreHardwareMonitor web server not reachable at {LHM_URL}")
        for sid, stype, name, value in sensors:
            print(f"{stype:12} {name:32} {value!s:>10}   {sid}")
        return

    log.info(f"CYD PC Stats feeder {__version__}")
    psutil.cpu_percent(interval=None)  # prime the counter; the first reading is always 0
    lhm_status = StatusLog()
    serial_status = StatusLog()
    ser = None
    while True:
        started = time.monotonic()
        stats, lhm_up = collect(args)
        lhm_status("LibreHardwareMonitor: " + ("connected" if lhm_up else
                   f"not reachable at {LHM_URL} (no CPU temp/power or fan RPM)"))
        line = format_line(stats)

        if args.dry_run:
            print(line, end="", flush=True)
        else:
            try:
                if ser is None:
                    port = args.port or find_port()
                    if not port:
                        raise serial.SerialException("CYD not found (no CH340/CP210x COM port)")
                    ser = open_port(port)
                    serial_status(f"Sending to {port}")
                ser.write(line.encode("ascii"))
                log.debug(line.rstrip())
            except serial.SerialException as e:
                serial_status(f"Serial: {e}; retrying every 3 s")
                if ser is not None:
                    ser.close()
                    ser = None
                time.sleep(3)
                continue

        time.sleep(max(0.0, args.interval - (time.monotonic() - started)))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
