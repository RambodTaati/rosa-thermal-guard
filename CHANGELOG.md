# Changelog

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
