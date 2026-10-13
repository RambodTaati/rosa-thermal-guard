# Rosa Thermal Guard

[English](README.md) · [فارسی](README.fa.md) · [العربية](README.ar.md) · **简体中文**

一个小巧的 Windows 托盘程序，让 **CPU 和 GPU 保持在 100 °C 以下**。芯片变热时，它先平缓地提高风扇转速（技嘉笔记本），
再逐级降低性能；降温后恢复全速，并把风扇交还给厂商的自动模式。

![Rosa Thermal Guard](../../releases/download/v1.3.0/screenshot-zh-CN.png)

## 功能
- **实时监控**：来自 LibreHardwareMonitor 的 CPU / GPU 温度、两个温度环（0–100 °C 线性），每个外圈有一条细的风扇转速环（占该风扇最大转速的百分比，加速时更亮，悬停显示转速），带旋转图标和速度条的风扇行，以及 5 分钟图表
  （温度、两个风扇的转速占各自最大值的百分比，以及风扇加速、100% 和游戏模式的色带）。
- **托盘图标**（Rosa Guard 系列设计，从 v1.3.0 起）：Thermal Guard 玫红色（#DB2777）的温度计轮廓，内有白色数字显示实时 CPU 温度。
  温度计按状态填色：绿 = 正常，橙 = 限制性能 / 降温中，红 = 过热，灰 = 已暂停；100 °C 及以上时三位数字占满整个底板（绝不显示“99+”）。
  图标在运行时按任务栏所在显示器的 DPI 绘制（16/20/24/32 像素），并区分浅色和深色任务栏。游戏模式显示在提示和窗口中，而不在图标上。左键打开窗口，右键打开菜单。
- **Rosa Guard 套件**（从 v1.3.0 起）：向其他 Rosa Guard 应用发布热压力，接受降温租约和无线网卡节能请求，同时仍可完全独立运行
  （见下文）。始终使用自己的窗口。
- **每秒读取一次传感器**（`pollSeconds`）。所有保持时间、渐变、平滑窗口和尖峰过滤都以秒为单位，改变读取间隔不会改变行为。
  程序本身很轻（传感器对象缓存；风扇转速每次读取，风扇模式每 5 秒读取；有活动时每 5 秒、否则每 60 秒记录一行温度）。
- **CPU 降频**：通过 Windows 电源计划（“最大处理器状态”，所有核心类型，交流和电池）：100 → 99（关闭睿频）→ 85 → 70 → 55%，每次一级。
- **NVIDIA GPU 降频**：驱动允许时用功耗上限（`nvidia-smi -pl`），否则用频率上限（`nvidia-smi -lgc`）75 → 55 → 40%，否则降低进程优先级。
- **尖峰过滤**：高温需持续约 2 秒（`triggerSeconds`）才降一级，持续约 4 秒（`criticalSeconds`）风扇才到 100%。单次睿频尖峰会被忽略。
- **尖峰防护**：满睿频时 CPU 可能在一次 1 秒读数内从 80 多度跳到 100-105 °C，比 2 秒过滤更快。一次读数达到 95 °C
  （`spikeGuard.fastC`），或在 92 °C 以上每秒升温至少 5 °C，就会立即关闭睿频（99 % 档），并在 120 秒内没有此类读数后
  才恢复（游戏模式下 300 秒）；若睿频恢复后
  立即再次出现尖峰，该时长加倍，最多 600 秒（`cpu.maxTurboHoldSeconds`）。更深的档位仍需持续高温，游戏优先级保持不变。CPU 风扇曲线在 92 °C 时达到 88 %（100 %
  仍只在 95 °C）。报告显示 CPU/GPU 高于 100 °C 的时长（总计、次数、最长一次），并在图表上用红色标出。
- **顾及轴承寿命的风扇控制（技嘉笔记本）**，通过技嘉自己的 ACPI-WMI 接口（Control Center 使用的同一接口）：
  - 由厂商自动模式负责，直到平滑曲线需要比自动模式更多的风量（曲线从 CPU 75 °C / GPU 72 °C 开始，只在接近降频点时才到高转速）。
  - 从当前转速接管，每 2 秒以 2% 的小步调整，绝不跳变。
  - 决策基于约 12 秒平滑后的温度；4 °C 回差，降速前至少保持 60 秒，自动与接管之间至少间隔 60 秒，风扇不会反复启停。
  - 只有临界温度（CPU 95 °C / GPU 90 °C）才 100%，此时不做渐变。
  - 接管期间转速绝不低于该温度下自动模式的转速。
  - 回退时缓慢降到接近自动转速后再交还。交还只取决于平滑温度，与是否仍在降频无关。
- **游戏模式**：玩游戏时（前台是列表中的游戏，或 GPU 负载持续 ≥ 60% 且有全屏程序或列表中的游戏在运行），风扇曲线更早开始
  （CPU 65 °C / GPU 60 °C 时 45%），升速稍快（每 2 秒 3%），保持时间和余量不变；100% 仍只在临界温度。游戏优先级绝不降低，
  先用风扇和功耗步骤。游戏活动 10 秒后开启，无游戏 60 秒后关闭；有紫色徽标和图表色带。
- **优先级步骤**：CPU 95 °C 时把最重的 3 个程序设为 BelowNormal（绝不动系统进程和正在运行的游戏），降温后恢复。
- **安全与恢复**：所有原始设置（电源计划、GPU 功耗上限 / 频率上限、进程优先级、风扇模式）都会保存，并在退出、暂停、卸载以及崩溃后恢复
  （下次启动会恢复残留的状态文件）。风扇看门狗：WMI 连续失败 3 次即交还厂商自动模式并在本次运行中停用风扇控制。防卡死：降温已 5 分钟
  而风扇仍被接管时自动交还。能检测睡眠/唤醒并重新读取一切。只使用厂商支持的调用（Windows 电源计划、`nvidia-smi`、技嘉 WMI）。
- **暂停** 15 分钟（CPU 达到 97 °C 时自动取消）。
- **4 种语言**：English、فارسی、العربية、简体中文（自动检测，可在窗口中切换；波斯语和阿拉伯语为从右到左）。
- **随 Windows 启动**（计划任务，管理员权限，每次登录不弹 UAC，登录 15 秒后启动），隐藏在托盘中：不显示窗口，不抢焦点。可在窗口中用
  **随 Windows 启动** 开关关闭或开启（默认开启；更新时保留你的选择）。
- **自动更新**（从 v1.2.0 起）：大约每天一次（以及启动约 5 分钟后）向 GitHub 查询最新版本。新安装程序只从该版本页通过 HTTPS 下载，
  其 SHA-256 必须与该版本的 `SHA256SUMS.txt`（以及 GitHub 自身的摘要）一致，文件名、大小和版本信息也必须属于本安装程序，否则什么都不会运行。
  只在安全时静默安装（非游戏模式、温度正常、一分钟内无降频和风扇接管），安装前先恢复风扇、电源计划和 GPU 设置；保留 `config.json`，
  程序会自动重启并提示“已更新到 vX”。托盘菜单 → **检查更新** 可立即检查。设置 `autoUpdate.enabled = false` 可关闭。
- **图形报告**（“报告”按钮或托盘菜单）：以你的语言显示的窗口，可选 1 小时 / 24 小时 / 7 天；CPU/GPU 温度图表，
  含两个风扇转速以及降频、风扇控制、100 % 和游戏模式的阴影带；摘要卡片（CPU/GPU 最高与平均、高于 90 °C 的时长、
  降频次数、风扇增强时长、游戏次数）以及通俗易懂的事件时间线。数据来自一个小型结构化历史文件
  （`%ProgramData%\RosaThermalGuard\history\h-YYYYMMDD.csv`，每 5 秒一行，保留 8 天；以及 `events.jsonl`，保留 7 天），
  而不是解析文本日志；**打开原始日志** 仍会打开 `guard.log`。
- **紧凑窗口**：5 分钟图表默认折叠；点击 **显示图表** 展开（窗口向上增高并保持在任务栏之上），选择会被记住。
  折叠时历史仍在记录。
- **磁盘占用有上限**：`guard.log` 达到 5 MB 时轮转为压缩的 `guard.1.log.gz`、`guard.2.log.gz` …（最多 5 个归档、
  7 天、总计 20 MB），历史文件按时间清理，ProgramData 中没有文件会无限增长。

## 支持的硬件
| | 温度 | 控制 |
|---|---|---|
| Intel / AMD CPU | 是（需要 PawnIO） | Windows 电源计划、进程优先级 |
| NVIDIA GPU | 是 | 功耗上限、频率上限（`nvidia-smi`）、优先级 |
| AMD / Intel GPU | 有传感器时 | 仅进程优先级 |
| 带技嘉 ACPI-WMI 接口（`GB_WMIACPI_Get/Set`）的技嘉 / AORUS / AERO 笔记本 | 风扇转速 | 顾及轴承的风扇控制 |
| 其他笔记本 / 台式机 | — | 无风扇控制：风扇保持厂商自动模式，其余功能照常 |

## 系统要求
- Windows 10 或 11，64 位
- 管理员账户（安装程序和本程序需要管理员权限）
- CPU 温度需要 **PawnIO** 驱动（https://pawnio.eu）；缺少时安装程序会提示
- GPU 控制需要带 `nvidia-smi` 的 NVIDIA 驱动（可选）
- 风扇控制需要带 WMI 接口的技嘉笔记本（Control Center 可以保留）

## 安装
从 Releases 页面下载 `RosaThermalGuard-Setup-1.3.2.exe`，对照 `SHA256SUMS.txt` 校验
（`Get-FileHash .\RosaThermalGuard-Setup-1.3.2.exe`），然后运行。

> 安装程序**没有代码签名**，Windows SmartScreen 可能提示“Windows 已保护你的电脑”。
> 如信任此版本（请先校验 SHA-256），点击 **更多信息 → 仍要运行**。

覆盖安装旧版本会保留你的 `config.json`。

> **从 1.1.0 或更早版本升级：** 自动更新从 1.2.0 开始，请手动安装一次 1.2.0，之后的版本会自动更新。

## 卸载
设置 → 应用 → Rosa Thermal Guard → 卸载。会停止程序，恢复原始电源、GPU 和风扇设置，删除计划任务以及程序和数据文件夹。

共享的 Rosa Guard 组件（`%CommonProgramFiles%\RosaGuard\SDK`）只有在没有其他 Rosa Guard 应用使用时才会被删除；卸载
Thermal Guard 只会移除它自己的引用。

## 工作方式
| | 降频 | 临界 | 恢复 |
|---|---|---|---|
| 风扇（技嘉） | 曲线从 CPU 75 / GPU 72 °C 开始（游戏：65 / 60 °C），每 2 秒 2% | CPU 95 / GPU 90 °C：100% | 低于 CPU 70 / GPU 67 °C 持续 30 秒：缓慢降速后交还自动 |
| CPU | ≥ 90 °C 持续 2 秒：100 → 99（关闭睿频）→ 85 → 70 → 55% | ≥ 95 °C：同时降低占用最高的 3 个程序的优先级 | < 80 °C 持续 20 秒，每次回退一级 |
| GPU（NVIDIA） | ≥ 88 °C 持续 2 秒：降低功耗上限，或频率上限 75 → 55 → 40% | | < 78 °C 持续 20 秒 |

如果全速刚恢复就再次过热，重新允许睿频前的等待时间会翻倍（最多 10 分钟）。
日志位于 `%ProgramData%\RosaThermalGuard\guard.log`。达到 `logging.maxSizeMB` 时轮转为压缩的 `guard.1.log.gz`、
`guard.2.log.gz` …（受 `keepFiles`、`keepDays`、`totalMaxMB` 限制）；托盘和守护进程同时写入时轮转也是安全的。
报告数据位于 `history\`（8 天的 5 秒数据行和 7 天的事件，每天约 0.7 MB）。

## Rosa Guard 套件：应用间通信（从 v1.3.0 起）
Thermal Guard 是 Rosa Guard 套件的第一个应用（互操作协议 1.2，Rosa Guard SDK 1.2.0），也是电源计划、CPU 限制、GPU 频率和风扇的
所有者。套件中的应用只通过本地命名管道通信（仅限你的账户和 SYSTEM，双向校验身份）；任何应用都不读取其他应用的文件。

- **独立优先**：安装程序会添加共享组件 `%CommonProgramFiles%\RosaGuard\SDK\1.2.0`（引用计数）。如果它缺失或损坏，
  Thermal Guard 的运行与 1.2 完全相同（日志中只有一行：`[SUITE] ... standalone`）。所有通信都在单独的后台 runspace 中运行，
  保护循环从不等待它。
  从 1.3.0 升级时，Thermal 旧的 `TabHost\1.1.2` 引用会迁移到 `SDK\1.2.0`；没有应用再使用 `TabHost` 时其文件夹会被删除。
- **发布 `thermal.pressure`**，每 2 秒一次（有效 15 秒）：`level` 0 = 正常（CPU < 75 / GPU < 72 °C），1 = 偏热或风扇正在升速
  （游戏模式：从 65 / 60 °C 起），2 = Thermal Guard 正在限制 CPU 或 GPU，3 = 危急（CPU ≥ 95 / GPU ≥ 90 °C）；降级需等待 30 秒。
  另含 `cpuC`、`gpuC`、`cpuTrendCPerSec`、`fanMode`、`gaming` 和 `cooldown`。
- **降温租约**（`thermal.request_cooldown`）：其他应用（例如下载器在大任务前）可以申请 10–600 秒的额外降温。`mild` = 风扇曲线提前
  5 °C 开始（`suite.leaseFanShiftC`，同样平缓渐变）；`strong` = 另外关闭睿频。租约只会增加降温，绝不会取消任何保护步骤；最多
  8 个应用，每个一份租约，到期、取消或申请方断开连接时立即结束。关闭：`suite.allowPeerCooldown = false`。
- **无线网卡节能**（`thermal.request_power_setting`）：Net Guard 可以请求电源计划所有者 Thermal Guard，在 30–3600 秒内把当前计划的
  *Wireless Adapter Settings → Power Saving Mode* 设为 Maximum Performance。原始值会先保存（防崩溃，`wifistate.json`），并在到期、
  取消、断开、退出、崩溃和卸载时恢复；压力等级 3 时拒绝，达到等级 3 时立即撤销；仅限已验证的应用；续租保持同一个 `leaseId`，
  `thermal.leases` 查询可列出当前租约。关闭：`suite.allowPowerSetting = false`。
- **游戏信号**：`suite.gaming`（来自选出的检测者）和 `net.session.gaming` 作为游戏模式的又一个信号；Thermal Guard 自己的检测照常
  独立工作。Thermal Guard 被选为检测者时会自己发布 `suite.gaming`。
- 诊断：`guard.log` 中带 `[SUITE]` 的行显示 broker 连接、租约和请求。管道 `RosaGuard.v1.thermal.<你的 SID>`，注册表
  `HKLM\SOFTWARE\RosaGuard\Apps\thermal`。

## 配置（安装目录中的 `config.json`，仅管理员）
修改后请重启程序（托盘菜单 → 退出，再启动）。温度单位 °C，时间单位秒，风扇值为满转的百分比。曲线是 `[温度, 百分比]` 点的列表，线性插值。

| 设置 | 默认值 | 含义 |
|---|---|---|
| `language` | `auto` | `auto`、`en`、`fa`、`ar`、`zh-CN` |
| `pollSeconds` | 1 | 传感器读取间隔（0.5–10 秒） |
| `cpu.throttleC` | 90 | CPU 达到该温度时开始第一级降频 |
| `cpu.criticalC` | 95 | 同时降低最重程序的优先级 |
| `cpu.restoreC` | 80 | 低于此温度视为 CPU 已降温 |
| `cpu.restoreAfterSeconds` | 20 | 每次回退一级前需保持低温的时间（GPU 同样使用） |
| `cpu.maxStateSteps` | [100,99,85,70,55] | 各级的“最大处理器状态” |
| `cpu.minSecondsBetweenSteps` | 6 | 两次降频之间的最短间隔（CPU 和 GPU） |
| `cpu.maxTurboHoldSeconds` | 600 | 反复过热后重新允许睿频前的最长等待 |
| `cpu.triggerSeconds` | 2 | 尖峰过滤：高温需持续这么久 |
| `spikeGuard.enabled` | true | 第一次出现过热或快速升温读数时关闭睿频 |
| `spikeGuard.fastC` | 95 | 一次读数达到此温度即立即关闭睿频 |
| `spikeGuard.riseFromC` / `risePerSec` | 92 / 5 | ……或在 `riseFromC` 以上每秒升温至少 `risePerSec` °C |
| `spikeGuard.holdSeconds` | 120 | 在这段时间内没有此类读数后才恢复睿频 |
| `spikeGuard.gameHoldSeconds` | 300 | 游戏模式下的同一时长 |
| `gpu.throttleC` | 88 | GPU 达到该温度时开始第一级 |
| `gpu.restoreC` | 78 | 低于此温度视为 GPU 已降温 |
| `gpu.clockStepsPercent` | [75,55,40] | 功耗上限被锁定时的频率上限各级 |
| `gpu.triggerSeconds` | 2 | GPU 的尖峰过滤 |
| `fanBoost.enabled` | true | 风扇控制开关（无技嘉接口的硬件上忽略） |
| `fanBoost.curveCpu` | [[75,50],[80,60],[85,72],[89,82],[92,88]] | 按 CPU 温度的风扇需求曲线 |
| `fanBoost.curveGpu` | [[72,50],[76,57],[80,65],[84,74],[88,84]] | 按 GPU 温度的风扇需求曲线 |
| `fanBoost.fullDutyCpuC` / `fullDutyGpuC` | 95 / 90 | 临界：立即 100%，不做渐变 |
| `fanBoost.criticalSeconds` | 4 | 原始临界温度需持续这么久（或平滑值已达临界） |
| `fanBoost.smoothingSeconds` | 12 | 风扇逻辑所用温度的平滑窗口（EMA） |
| `fanBoost.hysteresisC` | 4 | 降速时按“比实际高这么多度”读取曲线 |
| `fanBoost.engageMarginPercent` | 5 | 曲线需求比自动模式高出这么多才接管 |
| `fanBoost.minHoldSeconds` | 60 | 提速后至少保持这么久才降 |
| `fanBoost.minSwitchIntervalSeconds` | 60 | 自动 ↔ 接管之间的最短切换间隔 |
| `fanBoost.rampUpStepPercent` / `rampDownStepPercent` | 2 / 2 | 每一步渐变的幅度 |
| `fanBoost.rampIntervalSeconds` | 2 | 渐变步之间的时间 |
| `fanBoost.releaseCpuC` / `releaseGpuC` | 70 / 67 | 低于这些（平滑）温度时交还自动模式 |
| `fanBoost.releaseAfterSeconds` | 30 | 交还前需保持低温的时间 |
| `fanBoost.handBackMarginPercent` | 4 | 转速降到离自动转速这么近时交还 |
| `fanBoost.handBackFallbackPercent` | 25 | 尚不知道自动转速时的着陆转速 |
| `fanBoost.maxDuty` | 229 | EC 中 100% 的原始值 |
| `fanBoost.maxRpmCpuFan` / `maxRpmGpuFan` | 6400 / 6900 | 100% 时的转速，用于仪表和图表刻度 |
| `fanBoost.gameMode.enabled` | true | 游戏模式开关 |
| `fanBoost.gameMode.gpuUtilPercent` | 60 | 视为“繁忙”的 GPU 负载 |
| `fanBoost.gameMode.enterSeconds` / `exitSeconds` | 10 / 60 | 进入所需的游戏活动时间 / 退出所需的空闲时间 |
| `fanBoost.gameMode.detectFullscreen` | true | 前台全屏程序 + GPU 繁忙 = 游戏 |
| `fanBoost.gameMode.protectGame` | true | 永不降低游戏优先级 |
| `fanBoost.gameMode.rampUpStepPercent` | 3 | 游戏时更快的升速渐变 |
| `fanBoost.gameMode.curveCpu` | [[65,45],[71,55],[77,67],[83,78],[88,86],[91,90]] | 游戏曲线（CPU） |
| `fanBoost.gameMode.curveGpu` | [[60,45],[66,54],[72,64],[78,74],[83,82],[87,88]] | 游戏曲线（GPU） |
| `fanBoost.gameMode.exeList` | … | 始终视为游戏的进程名（不含 .exe，常见游戏） |
| `fanBoost.gameMode.excludeExes` | … | 永远不算游戏的全屏程序（浏览器、播放器等） |
| `autoUpdate.enabled` | true | 在 GitHub 检查新版本，并在空闲且温度正常时安装已校验的更新 |
| `autoUpdate.checkHours` | 24 | 两次检查之间的小时数（启动约 5 分钟后首次检查；出错时 1、2、4… 小时退避） |
| `pauseCancelC` | 97 | CPU 达到此温度时取消暂停 |
| `lowerPriorityTopN` | 3 | CPU 临界时降低优先级的程序数量 |
| `notifications` | true | 通知 |
| `allowSimulateFile` | false | 开发测试用，保持 false |
| `logging.maxSizeMB` | 5 | `guard.log` 达到此大小时轮转为 `guard.N.log.gz` |
| `logging.keepFiles` | 5 | 保留的压缩归档数量 |
| `logging.keepDays` | 7 | 早于此天数的归档会被删除 |
| `logging.totalMaxMB` | 20 | 所有日志合计上限（最旧的归档先删除） |
| `logging.tempsEverySec` | 5 | 有活动时温度行的写入间隔（空闲时 60 秒）；事件总是记录 |
| `suite.enabled` | true | 安装了共享组件时加入 Rosa Guard 套件（false = 始终独立运行） |
| `suite.allowPeerCooldown` | true | 接受其他 Rosa Guard 应用的降温租约（它们只能增加降温） |
| `suite.allowPowerSetting` | true | 接受 Net Guard 的无线网卡节能请求（到期 / 退出时恢复） |
| `suite.leaseFanShiftC` | 5 | 降温租约期间风扇曲线提前多少 °C 开始（0–10） |
| `protectedProcesses` | … | 永不修改优先级的进程（系统列表） |
## 故障排除
- **CPU 显示“--”或一直等待**：安装 PawnIO 并确认是管理员账户；在 `guard.log` 中查找 `CPU temperature not available`。
- **没有风扇行 / “不可用”**：此笔记本没有技嘉 WMI 风扇接口，风扇保持自动模式。
- **风扇一直高转**：平滑温度低于 70 / 67 °C 持续 30 秒（缓慢降速后）就会交还。日志中以 `fans:` 开头的行解释每个决定。退出程序总会交还风扇。
- **GPU 限制无效**：许多笔记本驱动锁定功耗上限，此时改用频率上限。
- **窗口不显示**：左键单击托盘图标（会恢复最小化的窗口），或菜单 → 打开。
- **更新**：每一步都记录在 `guard.log`（`update:` 行）；静默安装写入 `%ProgramData%\RosaThermalGuard\update-install.log`。任何一项检查失败的文件都会被删除，绝不运行。
- **SmartScreen 警告**：见上文“安装”。
- **启动失败**：在任务计划程序中运行 `RosaThermalGuard` 任务，并查看 `guard.log` 和 `ui.log`。

## 已知限制
- 反应速度受读取间隔和尖峰过滤限制；睿频突发可能在第一级降频前触及上限 2–3 秒。
- 许多笔记本驱动锁定 GPU 功耗上限，此时使用频率上限或进程优先级。
- AMD/Intel GPU：有传感器时显示温度，仅能通过进程优先级控制。
- 厂商工具（如 OEM 控制中心）可能覆盖 Windows 电源计划。
- 适用于 Administrators 组用户；标准用户启动后无法读取传感器。

## 构建
安装 Inno Setup 6，然后运行 `powershell -File build.ps1`。输出在 `dist\`。

## 许可证
本项目采用 MIT 许可证（见 `LICENSE`）。随附的 **LibreHardwareMonitorLib** 采用 **Mozilla Public License 2.0（MPL-2.0）**，
其源代码见 https://github.com/LibreHardwareMonitor/LibreHardwareMonitor。详见 `THIRD-PARTY-NOTICES.md`。
