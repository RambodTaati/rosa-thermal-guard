# Rosa Thermal Guard

**English** · [فارسی](README.fa.md) · [العربية](README.ar.md) · [简体中文](README.zh-CN.md)

A small Windows tray app that keeps your **CPU and GPU below 100 °C**. When a chip gets hot it first
turns the fans up gently (GIGABYTE laptops), then slows work down step by step; when it cools off it
gives you full speed back and hands the fans back to the firmware.

![Rosa Thermal Guard](../../releases/download/v1.2.0/screenshot-en.png)

## Features
- **Live monitoring**: CPU / GPU temperatures from LibreHardwareMonitor, two temperature rings (linear 0–100 °C) each wrapped by a thin fan-speed ring (% of that fan's max RPM, brighter while boosted, RPM in the tooltip), a fan row with
  spinning fan icons and speed bars, and a 5-minute graph with CPU/GPU temperatures, both fan speeds
  (% of each fan's max) and shaded bands for fan boost, 100 % and game mode.
- **Tray icon** that shows the CPU temperature and changes color: green = normal, orange = cooling down,
  red = hot, grey = paused. Left-click opens the window, right-click opens the menu.
- **1-second polling** (`pollSeconds`). Every hold time, ramp, smoothing window and the spike filter is
  defined in seconds, so changing the poll rate does not change the behavior. The guard itself stays light
  (sensors are cached, fan RPM is read every poll, fan mode registers every 5 s, the temperature line is
  logged every 5 s while something is active and every 60 s otherwise).
- **CPU throttling** through the Windows power plan ("Maximum processor state", all core types, AC and DC):
  100 → 99 (turbo off) → 85 → 70 → 55 %, one step at a time.
- **NVIDIA GPU throttling**: power limit (`nvidia-smi -pl`) when the driver allows it, otherwise a graphics
  clock cap (`nvidia-smi -lgc`) 75 → 55 → 40 %, otherwise lower process priority.
- **Spike filter**: heat must last ~2 s (`triggerSeconds`) before a throttle step, and ~4 s
  (`criticalSeconds`) before the fans go to 100 %. Single-sample turbo spikes are ignored.
- **Spike guard**: at full turbo the CPU can jump from the 80s to 100-105 °C within one 1-s reading, faster than the
  2-s filter. One reading at/above 95 °C (`spikeGuard.fastC`), or a rise of at least 5 °C/s above 92 °C, turns turbo off
  at once (the 99 % step), and turbo stays off until there has been no such reading for 120 s (300 s in game mode);
  if a spike follows right after turbo returns, that hold doubles, up to 600 s (`cpu.maxTurboHoldSeconds`).
  Deeper steps still need sustained heat, and the game keeps its priority. The CPU fan curve reaches 88 % by 92 °C
  (100 % still only at 95 °C). The report shows CPU/GPU time above 100 °C (total, episodes, longest) and marks those
  moments in red on the chart.
- **Bearing-friendly fan control (GIGABYTE laptops)**, through GIGABYTE's own ACPI-WMI interface
  (the same one the Control Center uses):
  - The firmware's auto mode stays in charge until a smooth curve asks for more airflow than auto gives
    (curve starts at CPU 75 °C / GPU 72 °C, reaches high duty only near the throttle points).
  - The fans are taken over at their current speed and moved in small 2 % steps every 2 s, never jumped.
  - Decisions use temperatures smoothed over ~12 s; 4 °C hysteresis, at least 60 s hold before lowering,
    at least 60 s between auto and controlled, so the fans never cycle.
  - 100 % only at critical temperatures (CPU 95 °C / GPU 90 °C), which skip the ramp.
  - While controlled the fans never run below what auto would run at that temperature.
  - On the way back the duty is ramped down slowly to about the auto speed and only then handed back.
    Hand-back depends only on the (smoothed) temperatures, not on whether throttling is still active.
- **Game mode**: when you play (a listed game in front, or sustained GPU load ≥ 60 % with a fullscreen
  app or a listed game running), the fan curve starts earlier (CPU 65 °C / GPU 60 °C at 45 %) and ramps a
  little faster (3 % per 2 s) with the same holds and margins; 100 % still only when critical. The game is
  never deprioritized, the guard uses fans and power steps first. Turns on after 10 s of game activity and
  off after 60 s without it; a violet badge and graph band show it.
- **Priority step**: at CPU 95 °C the 3 heaviest apps get BelowNormal priority (never system processes,
  never the running game); restored when it cools down.
- **Safety and restore**: every original setting (power plan values, GPU power limit / clock cap, process
  priorities, fan mode) is saved and restored on exit, on pause, on uninstall and after a crash (the next
  start restores a leftover state file). Fan watchdog: after 3 failed WMI calls the fans are handed back to
  vendor auto mode and fan control is disabled for the session. Stuck guard: if it has been cool for 5 min
  while the fans are still controlled, they are handed back. Sleep/resume is detected and everything is
  re-read. Only vendor-supported calls are used (Windows power plan, `nvidia-smi`, GIGABYTE WMI).
- **Pause** for 15 minutes from the tray (cancelled automatically if the CPU reaches 97 °C).
- **4 languages**: English, فارسی, العربية, 简体中文 (auto-detected, switchable in the window; RTL for fa/ar).
- **Starts with Windows** (scheduled task, elevated, no UAC prompt at each logon).
- **Auto-update** (from v1.2.0): about once a day (and ~5 min after start) the guard asks GitHub for the latest
  release. A newer installer is downloaded over HTTPS from that release only, its SHA-256 must match the release's
  `SHA256SUMS.txt` (and GitHub's own digest), and its name, size and version resource must be those of this
  installer, otherwise nothing is run. It installs silently only when it is safe (no game mode, temperatures normal,
  no throttling or fan control for a minute), after first restoring the fans, power plan and GPU settings; your
  `config.json` is kept and the app restarts by itself and shows "Updated to vX". Tray menu → **Check for updates**
  checks now. Turn it off with `autoUpdate.enabled = false`.
- **Graphical report** (the Report button or the tray menu): a window in your language with a 1 hour / 24 hours / 7 days
  selector, a CPU/GPU temperature chart with both fan speeds and shaded bands for throttling, fan control, 100 % and
  game mode, summary cards (CPU/GPU max and average, time above 90 °C, throttle events, fan-boost time, game sessions)
  and a plain-language event timeline. It reads a small structured history
  (`%ProgramData%\RosaThermalGuard\history\h-YYYYMMDD.csv`, one row per 5 s, kept 8 days, plus `events.jsonl`, kept
  7 days) instead of the text log; **Open raw log** still opens `guard.log`.
- **Compact window**: the 5-minute graph is collapsed by default; **Show graph** expands it (the window grows upwards
  and stays above the taskbar) and the choice is remembered. History keeps recording while it is hidden.
- **Bounded disk use**: `guard.log` rotates at 5 MB into compressed `guard.1.log.gz`, `guard.2.log.gz` … (at most
  5 archives, 7 days and 20 MB in total) and the history files are pruned by age, so nothing in ProgramData grows
  without limit.

## Supported hardware
| | Temperatures | Control |
|---|---|---|
| Intel / AMD CPU | yes (needs PawnIO) | Windows power plan, process priority |
| NVIDIA GPU | yes | power limit, clock cap (`nvidia-smi`), priority |
| AMD / Intel GPU | where the sensor exists | process priority only |
| GIGABYTE / AORUS / AERO laptops with the GIGABYTE ACPI-WMI interface (`GB_WMIACPI_Get/Set`) | fan RPM | bearing-friendly fan control |
| Other laptops / desktops | — | no fan control: the fans stay on the vendor's auto mode, everything else works |

## Requirements
- Windows 10 or 11, 64-bit
- An administrator account (the installer and the guard need admin rights)
- The **PawnIO** driver for CPU temperatures (https://pawnio.eu); the installer tells you if it is missing
- NVIDIA driver with `nvidia-smi` for GPU control (optional)
- For fan control: a GIGABYTE laptop with its WMI interface (the GIGABYTE Control Center can stay installed)

## Install
Download `RosaThermalGuard-Setup-1.2.0.exe` from the Releases page, check it against `SHA256SUMS.txt`
(`Get-FileHash .\RosaThermalGuard-Setup-1.2.0.exe`), and run it.

> The installer is **not code-signed**, so Windows SmartScreen may show "Windows protected your PC".
> Click **More info → Run anyway** if you trust this release (verify the SHA-256 first).

Installing over an older version keeps your `config.json`.

> **Updating from 1.1.0 or older:** auto-update starts with 1.2.0, so install 1.2.0 manually once; later versions
> arrive automatically.

## Uninstall
Settings → Apps → Rosa Thermal Guard → Uninstall. This stops the app, restores the original power, GPU and
fan settings, removes the scheduled task and deletes the program and its data folder.

## How it works
| | Throttle | Critical | Restore |
|---|---|---|---|
| Fans (GIGABYTE) | curve from CPU 75 / GPU 72 °C (game: 65 / 60 °C), 2 % per 2 s | CPU 95 / GPU 90 °C: 100 % | below CPU 70 / GPU 67 °C for 30 s: ramp down, hand back to auto |
| CPU | ≥ 90 °C for 2 s: max state 100 → 99 (turbo off) → 85 → 70 → 55 % | ≥ 95 °C: also lowers the priority of the top 3 CPU users | < 80 °C for 20 s, one step at a time |
| GPU (NVIDIA) | ≥ 88 °C for 2 s: power limit down, or clock cap 75 → 55 → 40 % | | < 78 °C for 20 s |

If heat comes back right after full speed returns, the wait before turbo is allowed again doubles (up to 10 minutes).
Logs are in `%ProgramData%\RosaThermalGuard\guard.log`. At `logging.maxSizeMB` it is rotated into compressed
`guard.1.log.gz`, `guard.2.log.gz` … (limited by `keepFiles`, `keepDays` and `totalMaxMB`); rotation is safe while the
tray and the guard both write. The report data lives in `history\` (8 days of 5-second rows plus 7 days of events,
about 0.7 MB per day).

## Configuration (`config.json` in the install folder, admin-only)
Restart the app (tray menu → Exit, then start it again) after editing. Temperatures are °C, times are seconds,
fan values are % of full duty. Curves are lists of `[temperature, percent]` points, interpolated linearly.

| Setting | Default | Meaning |
|---|---|---|
| `language` | `auto` | `auto`, `en`, `fa`, `ar`, `zh-CN` |
| `pollSeconds` | 1 | sensor polling interval (0.5–10) |
| `cpu.throttleC` | 90 | first CPU step at/above this |
| `cpu.criticalC` | 95 | also lower the priority of the heaviest apps |
| `cpu.restoreC` | 80 | CPU counts as cool below this |
| `cpu.restoreAfterSeconds` | 20 | cool this long before each step back (also used for the GPU) |
| `cpu.maxStateSteps` | [100,99,85,70,55] | "Maximum processor state" per level |
| `cpu.minSecondsBetweenSteps` | 6 | minimum time between two throttle steps (CPU and GPU) |
| `cpu.maxTurboHoldSeconds` | 600 | longest wait before turbo is allowed again after repeated heat |
| `cpu.triggerSeconds` | 2 | spike filter: heat must last this long before a CPU step |
| `spikeGuard.enabled` | true | turn turbo off on the first very hot or fast-rising reading |
| `spikeGuard.fastC` | 95 | one reading at/above this turns turbo off at once |
| `spikeGuard.riseFromC` / `risePerSec` | 92 / 5 | ... or a rise of at least `risePerSec` °C/s above `riseFromC` |
| `spikeGuard.holdSeconds` | 120 | turbo stays off until there has been no such reading for this long |
| `spikeGuard.gameHoldSeconds` | 300 | the same hold while game mode is on |
| `gpu.throttleC` | 88 | first GPU step at/above this |
| `gpu.restoreC` | 78 | GPU counts as cool below this |
| `gpu.clockStepsPercent` | [75,55,40] | clock cap steps (% of max clock) when the power limit is locked |
| `gpu.triggerSeconds` | 2 | spike filter for the GPU |
| `fanBoost.enabled` | true | fan control on/off (ignored on hardware without the GIGABYTE interface) |
| `fanBoost.curveCpu` | [[75,50],[80,60],[85,72],[89,82],[92,88]] | fan demand from the CPU temperature |
| `fanBoost.curveGpu` | [[72,50],[76,57],[80,65],[84,74],[88,84]] | fan demand from the GPU temperature |
| `fanBoost.fullDutyCpuC` / `fullDutyGpuC` | 95 / 90 | critical: 100 % at once, no ramp |
| `fanBoost.criticalSeconds` | 4 | raw critical heat must last this long (or the smoothed value be critical) |
| `fanBoost.smoothingSeconds` | 12 | EMA window of the temperatures the fan logic uses |
| `fanBoost.hysteresisC` | 4 | decreases use the curve as if it were this much hotter |
| `fanBoost.engageMarginPercent` | 5 | take control only when the curve asks for this much more than auto gives |
| `fanBoost.minHoldSeconds` | 60 | hold a raised duty at least this long before lowering |
| `fanBoost.minSwitchIntervalSeconds` | 60 | minimum time between auto ↔ controlled switches |
| `fanBoost.rampUpStepPercent` / `rampDownStepPercent` | 2 / 2 | size of one ramp step |
| `fanBoost.rampIntervalSeconds` | 2 | time between ramp steps |
| `fanBoost.releaseCpuC` / `releaseGpuC` | 70 / 67 | hand back to auto below these (smoothed) |
| `fanBoost.releaseAfterSeconds` | 30 | cool this long before handing back |
| `fanBoost.handBackMarginPercent` | 4 | hand back once the duty is within this of the auto speed |
| `fanBoost.handBackFallbackPercent` | 25 | landing duty when the auto speed is not known yet |
| `fanBoost.maxDuty` | 229 | the EC's raw value for 100 % duty |
| `fanBoost.maxRpmCpuFan` / `maxRpmGpuFan` | 6400 / 6900 | RPM at 100 %, used to scale the gauges and graph |
| `fanBoost.gameMode.enabled` | true | game mode on/off |
| `fanBoost.gameMode.gpuUtilPercent` | 60 | GPU load that counts as "busy" |
| `fanBoost.gameMode.enterSeconds` / `exitSeconds` | 10 / 60 | game activity needed to enter / idle time to leave |
| `fanBoost.gameMode.detectFullscreen` | true | a fullscreen foreground app + busy GPU counts as a game |
| `fanBoost.gameMode.protectGame` | true | never lower the game's priority |
| `fanBoost.gameMode.rampUpStepPercent` | 3 | faster ramp-up while gaming |
| `fanBoost.gameMode.curveCpu` | [[65,45],[71,55],[77,67],[83,78],[88,86],[91,90]] | game curve (CPU) |
| `fanBoost.gameMode.curveGpu` | [[60,45],[66,54],[72,64],[78,74],[83,82],[87,88]] | game curve (GPU) |
| `fanBoost.gameMode.exeList` | popular games | process names (without .exe) that always count as games |
| `fanBoost.gameMode.excludeExes` | browsers, players… | fullscreen apps that are never games |
| `autoUpdate.enabled` | true | check GitHub for new releases and install verified updates when idle and cool |
| `autoUpdate.checkHours` | 24 | hours between checks (first check ~5 min after start; errors back off 1, 2, 4… h) |
| `pauseCancelC` | 97 | a running pause is cancelled at this CPU temperature |
| `lowerPriorityTopN` | 3 | how many apps get lower priority at CPU critical |
| `notifications` | true | balloon notifications |
| `allowSimulateFile` | false | developer test hook; keep false |
| `logging.maxSizeMB` | 5 | rotate `guard.log` at this size into `guard.N.log.gz` |
| `logging.keepFiles` | 5 | compressed archives to keep |
| `logging.keepDays` | 7 | archives older than this are deleted |
| `logging.totalMaxMB` | 20 | cap for all logs together (oldest archives go first) |
| `logging.tempsEverySec` | 5 | temperature line interval while something is active (idle: 60 s); events are always logged |
| `protectedProcesses` | system list | processes whose priority is never changed |

## Troubleshooting
- **CPU shows "--" / waiting**: install PawnIO and make sure you are an administrator; check `guard.log` for
  `CPU temperature not available`.
- **No fan row / "not available"**: the laptop has no GIGABYTE WMI fan interface; the fans stay on auto.
- **Fans seem stuck high**: the guard hands back once smoothed temperatures are below 70 / 67 °C for 30 s (after
  the ramp-down). Open the log: lines starting with `fans:` explain every decision. Exiting the app always hands the
  fans back. If GIGABYTE Control Center is set to a fixed mode, that mode is respected after hand-back.
- **GPU limit does nothing**: many laptop drivers lock the power limit; the clock cap is used instead.
- **Window does not show**: left-click the tray icon (it restores a minimized window), or use the menu → Open.
- **SmartScreen warning**: see Install above.
- **Updates**: every step is logged in `guard.log` (lines with `update:`); the silent installer writes
  `%ProgramData%\RosaThermalGuard\update-install.log`. A file that fails any check is deleted, never run.
- **Start-up failed**: run the scheduled task `RosaThermalGuard` from Task Scheduler and look at `guard.log` and `ui.log`.

## Known limits
- Throttling cannot react faster than the poll interval plus the spike filter; a turbo burst can touch the limit for
  2–3 s before the first step.
- Many laptop drivers lock the GPU power limit; then the clock cap or process priority is used.
- AMD/Intel GPUs: temperature where available, control only via process priority.
- Vendor tools (e.g. OEM control centers) may override the Windows power plan.
- Runs for users in the Administrators group; for standard users it starts without sensor access.

## Build
Install Inno Setup 6, then run `powershell -File build.ps1`. Output goes to `dist\`.

## License
MIT for this project (see `LICENSE`). The bundled **LibreHardwareMonitorLib** is licensed under the
**Mozilla Public License 2.0 (MPL-2.0)**; its source is available at
https://github.com/LibreHardwareMonitor/LibreHardwareMonitor. See `THIRD-PARTY-NOTICES.md`.
