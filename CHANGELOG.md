# Changelog

## 1.3.4 (2026-10-14)
Temperature stays protected when a sensor or fan call stalls, and turbo stops being handed back into the next spike. Fan steps are unchanged: 2 % every 2 s (3 % in game mode), 100 % only at the existing critical temperatures.
* **A hot package is no longer handed back its power limit on a short dip.** 100 °C goes straight to the 85 % cap, 95 °C takes the next step on that sample, and after a critical spike every step stays down for the spike hold instead of the 20 s cool-down. A raw 100 °C sample also uses the existing one-time jump of the fans to 100 %.
* **The control loop no longer waits on LibreHardwareMonitor or GIGABYTE WMI.** Those reads run beside the loop. WMI calls give up after 2 s. A sample older than 2.5 s holds the current power step and fan target: it does not restore turbo, hand the fans back, or jump them. A real sleep/resume still resets smoothing; a stalled loop does not.
* **Repeated spikes hold turbo off.** After 2 spikes within an hour, the 99 % step stays until the CPU has been under 75 °C for 10 minutes continuously. Deeper steps can still ease off. `spikeGuard.repeatCount` 0 turns this off. An upgraded `config.json` gets the same defaults without an edit.
* **Time at or above 100 °C uses the real gap** between fresh samples. A sleep is a hole in that count. The priority scan no longer sleeps for 1 s inside the loop.
* `nvidia-smi` on the hot path gives up after 2.5 s.

## 1.3.3 (2026-10-14)
Installer/launcher fix only; same guard and SDK 1.2.3.
* **Upgrade ends with Thermal running**: setup now starts the guard from its elevated context (`Start-Thermal.ps1`, which runs the task and waits until the guard is logging, up to 3 tries). In 1.3.2 the final start ran as the unelevated original user, was denied, and left Thermal stopped after an upgrade.
* **Start menu / desktop shortcut**: if the guard is not running and the plain task start is denied, it asks once through UAC and starts it elevated. No UAC bypass.

## 1.3.2 (2026-10-14)
Rosa Guard SDK 1.2.3. No change to protection, fan/power control, the window or the tray icon.
* **SDK 1.2.3 (NetGuard crash fix)**: the SDK no longer disposes a pipe while another thread's overlapped read or write is still pending (only the reading thread disposes; others cancel and wait). This crashed NetGuard on 2026-10-13 right after it rejected Thermal.
* **SDK 1.2.3 (fewer rejected retries)**: when a peer refuses Thermal for a reason that can't change by itself (for example an unelevated NetGuard that can't read an elevated Thermal's command line), Thermal retries after 1 min, doubling up to 1 h, and at once when either app is reinstalled, upgraded or restarted. The rejection is reported once instead of every minute. No trust rule changed.
* Thermal now requires the shared SDK component 1.2.3+ (installed to `%CommonProgramFiles%\RosaGuard\SDK\1.2.3`).

## 1.3.1 (2026-10-12)
Rosa Guard SDK 1.2.2 (local rebuild; first built with 1.2.0). No change to protection, the window or the tray icon.
* **SDK 1.2.2 (Remote upgrade fix)**: right after Rosa Remote was upgraded, Thermal rejected it ("process image hash mismatch") until Thermal restarted, because the SDK
  loaded the registered hashes once at startup. SDK 1.2.2 re-reads that peer's registration on a mismatch (at most every 2 s per app) and checks again; a real mismatch is still refused.
  Thermal now requires the shared SDK component 1.2.2+ (installed to `%CommonProgramFiles%\RosaGuard\SDK\1.2.2`).
* **SDK 1.2.0**: the bundled shared component is the official, unmodified 1.2.0 release (`bin\RosaGuard.Interop.dll` only, checked against
  `bin\SHA256SUMS` at build time and by the module at load time). It installs to `%CommonProgramFiles%\RosaGuard\SDK\1.2.0`.
* **TabHost migration**: installing moves Thermal's 1.1.x reference from `RosaGuard\TabHost\1.1.2` to `RosaGuard\SDK\1.2.0`. The `TabHost`
  folder and its registry key are deleted once no app references them. If files are in use at that moment, Thermal Guard retries the cleanup itself.
* **Broker**: the suite hub is now the headless broker (SDK 1.2). Thermal is a broker candidate like every app. Log lines say "broker link".
* **Leases**: `granted`, `replaced` and `renewed` all count as active. Since SDK 1.2, a cooldown re-request is reported as `replaced`, and
  1.3.0 would have dropped the extra cooling at that point. `suite.allowPeerCooldown = false` / `suite.allowPowerSetting = false` now use `SetAccepting($false)`,
  which also revokes existing leases (holders get `thermal.lease` `revoked`/`disabled`). The SDK publishes `thermal.lease` for every lease change.
* **Start with Windows**: the existing `\RosaThermalGuard` logon task (highest privileges, same name) now starts 15 s after sign-in, Thermal's slot
  in the suite's staggered startup (CONTRACT 1.2 section 16). The SDK 1.2 startup check flagged "no logon delay"; the task is compliant either way. The toggle is
  unchanged, and Rosa's on/off choice is kept on upgrade.

## 1.3.0 (2026-10-12)
New family tray icon, Start with Windows toggle, Rosa Guard suite IPC (`thermal.pressure`, cooldown and power leases, suite gaming signal;
fully standalone without the suite), window polish, RTL fan bar fix. See the GitHub release notes.

## 1.2.0 and earlier
See https://github.com/RambodTaati/rosa-thermal-guard/releases.
