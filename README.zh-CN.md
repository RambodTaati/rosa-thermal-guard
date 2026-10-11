# Rosa 温控卫士（Rosa Thermal Guard）

[English](README.md) · [فارسی](README.fa.md) · [العربية](README.ar.md) · **简体中文**

一个小巧的 Windows 托盘程序，让 **CPU 和 GPU 温度始终低于 100 °C**。温度过高时逐级降速，降温后自动恢复全速。

![Rosa Thermal Guard](../../releases/download/v1.0.1/screenshot-zh-CN.png)

## 功能
- 实时显示 CPU / GPU 温度，环形仪表盘和最近 5 分钟曲线
- 托盘图标随状态变色：绿色 = 正常，橙色 = 正在降温，红色 = 过热，灰色 = 已暂停；悬停显示温度
- 通过 Windows 电源计划限制 CPU（"最大处理器状态"，适用于所有核心类型，交流电与电池）
- NVIDIA 显卡控制：驱动允许时降低功耗上限（`nvidia-smi -pl`），否则限制核心频率（`nvidia-smi -lgc`），再否则降低进程优先级
- CPU 温度达到临界值时降低最耗资源程序的优先级，不会改动系统进程
- 退出、卸载或崩溃后都会恢复所有原始设置
- 可从托盘菜单暂停 15 分钟（若 CPU 达到 97 °C 会自动取消暂停）
- 支持 4 种语言：简体中文、English、فارسی、العربية（自动识别，也可在窗口中切换）
- 随 Windows 启动（计划任务，以管理员权限运行，每次登录无需 UAC 确认）

## 系统要求
- Windows 10 / 11，64 位
- 管理员账户
- 读取 CPU 温度需要 **PawnIO** 驱动（https://pawnio.eu），缺失时安装程序会提示
- 控制显卡需要带 `nvidia-smi` 的 NVIDIA 驱动（可选）

## 安装
从 Releases 页面下载 `RosaThermalGuard-Setup-1.0.1.exe`，用 `SHA256SUMS.txt` 校验后运行。

> 安装程序**没有数字签名**，Windows SmartScreen 可能会提示"Windows 已保护你的电脑"。
> 如果你信任此版本（请先核对 SHA-256），点击 **更多信息 → 仍要运行**。

## 工作原理
每 2 秒读取一次传感器。

| | 开始降温 | 临界 | 恢复 |
|---|---|---|---|
| CPU | ≥ 90 °C：最大状态 100 → 99（关闭睿频）→ 85 → 70 → 55 % | ≥ 95 °C：同时降低前 3 个高占用程序的优先级 | 低于 80 °C 持续 20 秒，逐级恢复 |
| NVIDIA GPU | ≥ 88 °C：降低功耗上限，或频率上限 75 → 55 → 40 % | | 低于 78 °C 持续 20 秒 |

所有参数都可在安装目录的 `config.json` 中修改。日志位于 `%ProgramData%\RosaThermalGuard\guard.log`。

## 已知限制
- 响应速度受轮询间隔限制，睿频瞬间可能让温度在 2–4 秒内触及上限。
- 许多笔记本驱动锁定了显卡功耗上限，此时改用频率限制或进程优先级。
- AMD / Intel 显卡仅能通过进程优先级控制。
- 厂商控制软件可能会覆盖 Windows 电源计划。

## 卸载
设置 → 应用 → Rosa Thermal Guard → 卸载。程序会停止运行、恢复原始电源和显卡设置，并删除计划任务与所有文件。

## 许可证
本项目代码采用 MIT 许可证。随附的 LibreHardwareMonitorLib 采用 MPL-2.0（见 `THIRD-PARTY-NOTICES.md`）。
