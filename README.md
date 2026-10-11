# Rosa Thermal Guard

**English** · [فارسی](README.fa.md) · [العربية](README.ar.md) · [简体中文](README.zh-CN.md)

A small Windows tray app that keeps your **CPU and GPU below 100 °C**. When the chip gets hot it
slows work down step by step; when it cools off it gives you full speed back.

![Rosa Thermal Guard](../../releases/download/v1.1.0/screenshot-en.png)

## Features
- Live CPU / GPU temperatures (LibreHardwareMonitor sensors), gauges and a 5-minute history graph
- Tray icon that changes color: green = normal, orange = cooling down, red = hot, grey = paused; the tooltip shows °C
- CPU throttling through the Windows power plan ("Maximum processor state", all core types, AC and DC)
- NVIDIA GPU control: power limit (`nvidia-smi -pl`) when the driver allows it, otherwise a graphics clock cap (`nvidia-smi -lgc`), otherwise lower process priority
- GIGABYTE laptops: switches the fans to maximum before any throttling (CPU 85 °C / GPU 83 °C) through GIGABYTE's own ACPI-WMI interface, and puts your fan mode back once it has cooled down (below 75 / 73 °C for 20 s), on exit and on uninstall; for fan health, the normal boost runs at 88% duty and 100% only when critical (CPU 95 °C / GPU 90 °C, stepping back to 88% as temperatures fall or after 5 min), with a 60 s minimum hold and at least 30 s between fan-mode switches (all configurable in `fanBoost`)
- Lowers the priority of the heaviest apps when the CPU is critical; never touches system processes
- Restores every original setting on exit, on uninstall and after a crash
- Pause for 15 minutes from the tray (cancelled automatically if the CPU reaches 97 °C)
- 4 languages: English, فارسی, العربية, 简体中文 (auto-detected, switchable in the window)
- Starts with Windows (scheduled task, elevated, no UAC prompt at each logon)

## Requirements
- Windows 10 or 11, 64-bit
- An administrator account (the installer and the guard need admin rights)
- The **PawnIO** driver for CPU temperatures (https://pawnio.eu); the installer tells you if it is missing
- NVIDIA driver with `nvidia-smi` for GPU control (optional)

## Install
Download `RosaThermalGuard-Setup-1.1.0.exe` from the Releases page, check it against `SHA256SUMS.txt`, and run it.

> The installer is **not code-signed**, so Windows SmartScreen may show "Windows protected your PC".
> Click **More info → Run anyway** if you trust this release (verify the SHA-256 first).

## How it works
Every 2 seconds the guard reads the sensors.

| | Throttle | Critical | Restore |
|---|---|---|---|
| CPU | ≥ 90 °C: max state 100 → 99 (turbo off) → 85 → 70 → 55 % | ≥ 95 °C: also lowers the priority of the top 3 CPU users | < 80 °C for 20 s, one step at a time |
| GPU (NVIDIA) | ≥ 88 °C: power limit down, or clock cap 75 → 55 → 40 % | | < 78 °C for 20 s |

If heat comes back right after full speed returns, the wait before turbo is allowed again doubles (up to 10 minutes).
Everything is configurable in `config.json` in the install folder (admin-only): thresholds, steps, poll interval,
language and the list of protected processes. Logs are in `%ProgramData%\RosaThermalGuard\guard.log`.

## Known limits
- Throttling cannot react faster than the poll interval; a turbo burst can touch the limit for 2–4 s before the first step.
- Many laptop drivers lock the GPU power limit; then the clock cap or process priority is used.
- AMD/Intel GPUs: temperature where available, control only via process priority.
- Vendor tools (e.g. OEM control centers) may override the Windows power plan.
- Runs for users in the Administrators group; for standard users it starts without sensor access.

## Uninstall
Settings → Apps → Rosa Thermal Guard → Uninstall. This stops the app, restores the original power and GPU settings,
removes the scheduled task and deletes the program and its data folder.

## Build
Install Inno Setup 6, then run `powershell -File build.ps1`. Output goes to `dist\`.

## License
MIT for this project. Bundled LibreHardwareMonitorLib is MPL-2.0; see `THIRD-PARTY-NOTICES.md`.
