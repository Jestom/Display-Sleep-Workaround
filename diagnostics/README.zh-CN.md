# 自然息屏根因取证

这套诊断只用于定位 NVIDIA/C340 的自然显示器息屏差异，不执行 topology workaround，不修改电源计划，也不主动发送 `SC_MONITORPOWER`。

## 目标

先在相同驱动和相同单屏硬件下建立两份可比较的记录：

| 标签 | NVIDIA 模式 | 肉眼预期 |
| --- | --- | --- |
| `current-native-bad` | 删除/停用 NVIDIA 自定义分辨率，使用 EDID 原生模式 | C340 无信号后亮黑色背光 |
| `current-custom-good` | 创建并选中已验证的 NVIDIA `3440x1440 @ 100.000Hz` 自定义模式 | C340 持续真正息屏 |

只有这组差异稳定后，才进行第二阶段驱动对照：

| 标签 | 驱动分支 | 模式 | 肉眼预期 |
| --- | --- | --- | --- |
| `r535-53758-native-good` | 537.58 / R535 | EDID 原生模式 | 正常息屏 |
| `r545-first-bad-native` | 第一个确认故障的 R545 驱动 | EDID 原生模式 | 黑色背光 |

537.58 是 2023-10-10 的 R535 驱动；一周后的 545.84 已切换到 R545，并包含与显示器睡眠相关的修复条目。这个时间边界是重要线索，但发布说明只公开部分改动，不能据此直接断定内部根因：

- [NVIDIA 537.58 release notes](https://us.download.nvidia.com/Windows/537.58/537.58-win11-win10-release-notes.pdf)
- [NVIDIA 545.84 driver page](https://www.nvidia.com/Download/driverResults.aspx/212898/en-us/Guide/)

## 准备

1. 只连接 C340，物理拔掉其它显示器信号线。
2. 确认已安装的 topology listener 已停止。
3. 设置一个适合等待的 Windows 显示器关闭时间；脚本不会修改它。
4. 关闭视频播放器、演示模式或其它会阻止显示器超时的程序。
5. 在管理员 PowerShell 中运行诊断。

停止 listener：

```powershell
Stop-ScheduledTask -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
```

确认没有残留进程：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*topology-ddcci-workaround.ps1*" } |
  Select-Object ProcessId,Name,CommandLine
```

## 第一阶段

原生模式故障状态：

```powershell
.\diagnostics\capture-natural-display-sleep.ps1 `
  -Label "current-native-bad" `
  -ObserveAfterDisplayOffSeconds 120
```

NVIDIA 自定义模式正常状态：

```powershell
.\diagnostics\capture-natural-display-sleep.ps1 `
  -Label "current-custom-good" `
  -ObserveAfterDisplayOffSeconds 120
```

运行后不要操作鼠标或键盘。脚本等待 Windows 电源计划自然发出 display-off，观察 120 秒，然后发送一次极小鼠标移动唤醒并保存唤醒后状态。120 秒也是当前默认值。

每轮结束后记录肉眼现象：

- C340 是否先显示无信号；
- 黑色背光出现的大约时间；
- 120 秒内是否持续真正息屏；
- 自动唤醒是否正常。

## 输出

所有结果写入：

```text
.\log\diagnostics\YYYYMMDD-HHMMSS-LABEL\
.\log\diagnostics\YYYYMMDD-HHMMSS-LABEL.zip
```

重点文件：

- `capture.log`：display-off/on 墙钟时间。
- `result.txt`：测试结果摘要。
- `natural-display-sleep.etl`：原始 ETW。
- `relevant-events.txt`：筛选后的 D3/D0、DevicePreparation 和 DevicePoweredOn。
- `relevant-events-relative.txt`：以自然 display-off 为 0 秒的事件时间线。
- `displayconfig-*.txt`：息屏前、观察窗口和唤醒后的 active paths。
- `dispdiag-before.dat` / `dispdiag-after.dat`：Windows 显示诊断数据。
- `nvidia-display-state-summary.txt`：三阶段的 `Display Active`、P-State 和功耗摘要。
- `nvlddmkm-file.txt`：NVIDIA 驱动文件版本和 SHA-256。
- `nvidia-custom-display-registry-search.txt`：CustomDisplay 注册表值和 `CUST:` 二进制内容扫描结果。
- `nvidia-custom-display-values\`：匹配到的原始二进制注册表值及 SHA-256。

ETL 启动失败时先查看 `logman-start.txt`。可以使用 `-SkipEtl` 只采集状态，但这种结果不足以比较驱动电源事件。

## 判断标准

2026-07-10 的当前驱动 A/B 已得到一条比 ETW 计数更直接的差异：

| 状态 | 息屏前 | 自然息屏后 120 秒 | 唤醒后 |
| --- | --- | --- | --- |
| 原生模式故障 | `Display Active: Enabled` | `Enabled` | `Enabled` |
| NVIDIA CustomDisplay 正常 | `Display Active: Enabled` | `Disabled` | `Enabled` |

两组均收到 `ConsoleDisplayState=0`，且 DisplayConfig 中的 C340 active path 均保留。因此，Windows 已发起自然息屏，但两种状态最终进入不同的输出电源状态。CustomDisplay 是对 GPU、驱动、DisplayPort 链路和显示器 sink 这一整条链路的干预；仅凭这组 A/B 还不能判断决定性行为属于模式分类、驱动、链路命令顺序还是 C340 固件。

用户已经确认了关键转换行为：仅保留已保存的自定义分辨率记录没有作用。只要当前活动模式切换为任意原生分辨率或刷新率，黑色背光故障就立即恢复。因此，删除记录、重置驱动和重启等持久性测试都是重复验证，不再列入计划。

ETW 中仍需比较以下事件：

- `SuspendRequestSent`
- `IrpRequestSentD3`
- `IrpRequestSentD0`
- `DevicePreparation`
- `DevicePoweredOn`

完整的逐项 A/B 对比和公开接口审计见 [NATIVE-CUSTOMDISPLAY-DIFF.zh-CN.md](NATIVE-CUSTOMDISPLAY-DIFF.zh-CN.md)。结论是：当前缺失的 DP link rate、lane count、DPCD、AUX 和链路训练数据，不由有文档支持的通用用户态 API 暴露。

本次原生模式记录比 CustomDisplay 多一组 D0/Suspend/D3 循环，但两组自然息屏记录都没有筛选到 `DevicePoweredOn` 或 `DevicePreparation`。单次记录不足以证明多出的循环就是原因，不能把 ETW 计数差异当成最终结论。

## 已完成：公开 CCD 模式重提交实验

`test-displayconfig-mode-reapply.ps1` 不创建 NVIDIA 自定义分辨率。它读取当前单屏原生模式，然后通过 Windows `SetDisplayConfig` 临时重新提交完全相同的路径和模式，再调用上面的自然息屏采集。

微软对 `SDC_NO_OPTIMIZATION` 的定义是把模式变更强制下发到每个活动显示器的驱动；`SDC_FORCE_MODE_ENUMERATION` 则让驱动在设置配置时更新 GDI 模式列表：

- [SetDisplayConfig function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig)
- [SetDisplayConfig summary and scenarios](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/setdisplayconfig-summary-and-scenarios)

安全边界：

- 只允许恰好一个 active path，并要求它匹配 `TargetNeedle`。
- 先用 `SDC_VALIDATE` 验证当前配置。
- 不使用 `SDC_SAVE_TO_DATABASE`，不会写入 CCD 持久化数据库。
- 模式提交前保存原始数组，脚本退出时在 `finally` 中恢复。
- 提交后必须在 45 秒内按 Enter 确认画面正常；看不到画面时不要操作，watchdog 和主进程会运行 `DisplaySwitch.exe /extend`。

准备条件与前面的原生故障采集相同：只连接 C340、停用 NVIDIA CustomDisplay、使用 `99.998Hz` 原生模式、停止 topology listener，并在管理员 PowerShell 中运行。

第一种策略：

```powershell
.\diagnostics\test-displayconfig-mode-reapply.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy NoOptimization
```

画面重新出现后按一次 Enter，然后不要再使用鼠标或键盘。脚本会等待电源计划自然息屏并观察 120 秒。

第二种策略：

```powershell
.\diagnostics\test-displayconfig-mode-reapply.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy ForceModeEnumeration
```

两条命令不能连续粘贴执行。第一轮默认标签为 `native-reapply-no-optimization`，第二轮为 `native-reapply-force-mode-enumeration`。另外会在 `log\diagnostics` 下生成 `*-mode-reapply-*.log`。

2026-07-10 实测结果：

- 两种策略的 `SDC_VALIDATE` 和 `SDC_APPLY` 都返回成功。
- 活动模式始终保持原生 `533150000 / 99.998Hz`。
- 两轮自然息屏后 120 秒均为 `Display Attached: Yes, Display Active: Enabled`。
- 两轮在 display-off 后约 20 秒均出现四组 D0/Suspend/D3 循环，符合原生故障状态。
- `CustomDisplay` 值均为全零坏状态 hash `84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652`。

结论：公开 CCD 精确模式重提交和模式枚举刷新都不能进入 NVIDIA CustomDisplay 的内部 DPMS 路径。该方案已否决，不接入正式 runtime。

## 已否决：CCD 精确 supplied timing

`test-displayconfig-supplied-mode.ps1` 验证一个“原样重提当前模式”没有覆盖的窄问题：不创建 NVIDIA CustomDisplay，只通过微软有文档支持的 CCD 接口为当前会话直接提交一套新的 target timing，能否让 miniport 进入不同的模式路径。

针对已验证的 C340 环境，实验保留当前 `3440x1440` active area、`3600x1481` total、扫描方式、video standard、source mode、topology 和唯一 active path，只把 target signal 从原生 `533150000 / 99.998Hz` 改为数学上完全一致的 `533160000 / 148100Hz / 100.000Hz`。CRU 已经证明相同时序数值本身不能修复问题；本轮测试的变量是“当前会话由 CCD 直接提交非持久 supplied mode”这条路径，而不是再次验证 100.000Hz 数值。

安全边界：

- 只允许恰好一条 active path，并要求它匹配 `TargetNeedle`。
- 应用前先调用 `SDC_VALIDATE`。默认使用严格验证；只有显式指定 `-AllowChanges` 才启用微软说明的 best-mode 调整路径。
- 只用 `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_NO_OPTIMIZATION` 应用。
- 不使用 `SDC_SAVE_TO_DATABASE`，不写注册表，也不创建 NVIDIA CustomDisplay。
- 应用后必须精确读回 supplied timing；驱动若折回原生模式，立即终止息屏测试。
- 修改前保存原始数组，在 `finally` 中恢复；应用前还会启动独立的 `DisplaySwitch.exe /extend` watchdog。
- 只有用户确认画面正常后，才调用现有只读 DP probe 观察 30 秒。

NVIDIA 610.62 上的第一轮严格验证返回 `1610 (ERROR_BAD_CONFIGURATION)`，因此没有应用任何模式。微软对该结果的说明是：best-mode 逻辑无法在不改变 supplied path 或 mode 信息的前提下找到可行配置。加入 `SDC_ALLOW_CHANGES` 后，验证以 flags `0x00000460` 返回 `validationErr=0`：

```powershell
.\diagnostics\test-displayconfig-supplied-mode.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -AllowChanges `
  -ValidateOnly
```

随后使用相同调整 flag 执行受控应用：

```powershell
.\diagnostics\test-displayconfig-supplied-mode.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -AllowChanges `
  -MonitorIndex 0 `
  -ObserveAfterDisplayOffSeconds 30
```

`SetDisplayConfig` 接受了允许调整的应用请求，但紧接着的 `QueryDisplayConfig` 仍读回未改变的原生 `533150000 / 99.998Hz`。精确读回门槛在息屏前终止实验，取消 watchdog，并以 `applyErr=0` 成功恢复原始数组，因此没有运行 DPCD 息屏采集。

至此，有文档支持的公开 CCD supplied-mode 路线关闭：严格提交无法求解，允许调整则让 miniport 重新选择已经枚举的原生 target mode，而不会保留请求时序。脚本仅作为可复现实验证据保留，不接入正式程序，也不应在这台已验证机器上重复执行。

## 下一步：同步定位 D3 保持边界

DP probe 已经证明 NVIDIA 610.62 原生模式在息屏 10 秒时仍为物理 D3/link-down，到 30 秒时已经回到 D0/训练完成的 HBR2。重新对齐现有 ETW 后发现：原生故障和 CustomDisplay 正常状态都在约 `+19.44s` 出现相似的 `IrpRequestSentD0`，两边之后也都有额外的 D0/D3 循环；537.58 原生正常记录中甚至有更多高层 D0/D3 请求，但物理 sink 始终保持 D3。因此，这些事件不能直接代表物理 sink 电源状态，也不能据此锁定需要阻止的进程。

`capture-d3-retention-transition.ps1` 在现有 ETW 采集器上加入同步物理证据。它只允许显式 `SC_MONITORPOWER Off`，并采集：

- 现有完整 ETW provider 和展开后的 CSV。
- 用于 PID 对照的进程表。
- 息屏触发前的一次 DPCD 快照。
- 观察等待期间不进行任何 DPCD/AUX 调用。
- 在指定边界到达时，先读取一次 DPCD，再进行 WMI、NVIDIA 和 DisplayConfig 标记快照。

第一轮只测 20 秒：

```powershell
.\diagnostics\capture-d3-retention-transition.ps1 `
  -TargetId 4357 `
  -MonitorIndex 0 `
  -ObserveAfterDisplayOffSeconds 20 `
  -Label "61062-native-boundary-20s"
```

测试条件为 NVIDIA 610.62、仅一条 C340 active path、原生 `99.998Hz`、无 NVIDIA CustomDisplay。停止正式 listener，在管理员交互式 PowerShell 中运行，短时间采集期间不要操作输入设备。如果 20 秒标记仍是 D3，下一轮再测25秒；如果已经是 D0，下一轮再测15秒。在分析完20秒结果前不要自行执行后续轮次。

已验证的20秒结果仍为物理息屏：`0x600=02`、lane status `00 00`，NVIDIA 报告 `Display Active: Disabled`，DisplayConfig 原生活动路径保持不变。标记前55次 `IrpRequestSentD0` 全部来自 `dwm.exe`，每次之后都有 D3 请求，但到20秒时均未传播成物理 D0；VidPN 活动只在标记采集器启动后出现，不能当成故障触发。转换边界现已缩小到20～30秒，下一轮只测25秒。

25秒原生模式记录捕获到了转换本身。在标记探针启动前，DxgKrnl 于 `+24.416s` 处理一次显示中断，`+24.4199s` 的 `VidMmWakeReason_StatusChangeEvent` 随即让 target 4357 从 `DMM_CT_UNINITIALIZED / DMM_CVR_UNINITIALIZED` 开始重建；System 路径立即调用 `DdiSetTimingsFromVidPn` 和 `DdiSetVidPnSourceVisibility`，之后出现大量 VidPN/模式枚举事件。到25秒标记时，DPCD snapshot 已无法完成并返回 exit code `3`，而 NVIDIA 已报告 `Display Active: Enabled`。该序列早于标记探针，不由用户进程发起。它符合 miniport 上报 connector/child status change（例如 HPD 处理）的特征，但现有 ETW 不能直接证明电气 HPD。

不要再重复原生边界测试，也不要重试 `SC_MONITORPOWER`；黑背光后的 re-off 早已否决。下一项控制变量是在相同 NVIDIA 610.62 下激活已知正常的 NVIDIA CustomDisplay，再执行同样的25秒同步采集。如果状态变化序列消失，说明活动模式改变了中断前的链路/sink 行为；如果序列仍出现但 D3 得以保持，则说明 miniport 会根据模式分类采用不同处理。

## 已否决：NVIDIA 原生 CommitVidPn

`test-nvapi-force-commit-vidpn.ps1` 用 NVIDIA 官方显示控制路径测试“类原生”修复。它读取当前 NVAPI 配置，再原样使用 `NV_FORCE_COMMIT_VIDPN (0x10)` 提交；不创建自定义分辨率、不改变 topology，也不保存显示配置。NVIDIA 对该 flag 的定义是避免 modeset 中的 `CommitVidPn` 被优化掉。

桥接代码 `NvApiDisplayCommit.cs` 由 PowerShell 在内存中编译，直接调用 NVIDIA 驱动已安装的 `nvapi64.dll`，不需要 Visual Studio、WDK、自定义驱动或随项目分发 NVIDIA 二进制。API 常量和 x64 结构已按照公开的 NVIDIA R610 SDK 核对，许可记录见 `NVAPI-NOTICE.md`。

2026-07-10 的 `test3` 已正确完成，但没有修复黑色背光：

- 查询得到一条 path 和一个 target，display ID 为 `0x80061086`，原生模式为 `3440x1440 @ 99.998Hz`。
- 验证和应用都返回 `0`，apply flags 严格为 `0x10`。
- NVAPI 与 Windows DisplayConfig signature 均保持不变，提交后画面正常可见。
- 自然息屏 120 秒观察点仍为 `Display Attached: Yes, Display Active: Enabled, P5`。
- ETW 在 display-off 后约 90.34 秒记录到 `DevicePoweredOn`，随后还有 D3/D0 活动。

因此，“强制重提未改变的原生 VidPN 可以修复电源转换”这一假设已经被否决。脚本只为复现实验证据而保留，不是正式依赖，也不是推荐修复。

如需复现实验，先执行完全只读的 ABI/查询检查：

```powershell
.\diagnostics\test-nvapi-force-commit-vidpn.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -QueryOnly
```

正常结果应包含一条 NVAPI path、一个 NVIDIA target、非零 `displayId`、当前 source mode 和 `refreshRate1K`。这一步失败时不要继续 apply 测试。

查询通过后，再运行自然息屏实验：

```powershell
.\diagnostics\test-nvapi-force-commit-vidpn.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -ObserveAfterDisplayOffSeconds 120
```

准备条件与原生故障采集相同：只连接 C340，删除或停用 NVIDIA CustomDisplay，选择原生 `99.998Hz`，停止 topology listener，并使用管理员交互式 PowerShell。模式提交后只有画面完全恢复时才按 Enter，之后不要操作输入设备，直到采集结束。

安全边界：

- NVAPI 先验证刚查询到的配置。
- apply flag 只有 `NV_FORCE_COMMIT_VIDPN`，不包含持久化或 mode enumeration。
- apply 后 NVAPI 和 Windows DisplayConfig signature 都必须保持不变。
- 未确认画面时，隐藏 watchdog 会执行 `DisplaySwitch.exe /extend`。
- 后续仍等待 Windows 自然 display-off，不发送脚本 DPMS。

原定成功标准是：C340 DisplayConfig path 仍保持 active，但 120 秒观察点的 NVIDIA `Display Active` 变为 `Disabled`。实际结果为 `Enabled`，说明只强制提交原生 VidPN 不足以修复。不要把该策略接入正式 listener，也不要继续叠加 NVIDIA 专用提交 flags。

## 下一步：保留 active path 的息屏实验

`test-active-path-sleep-experiment.ps1` 测试三种始终保留单物理显示器 path 的机制。它不会删除 path、创建虚拟显示器、持久化显示配置或调用 NVIDIA API。测试前停止已安装的 topology listener，只连接问题显示器，停用 NVIDIA CustomDisplay，并选择已知会复现的原生模式。

每条命令必须单独运行。先执行完全只读的模式列表：

```powershell
.\diagnostics\test-active-path-sleep-experiment.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy ListModes
```

### 1. LowPower 系统命令

该实验发送 `SC_MONITORPOWER` 状态 `1`（`LowPower`），而不是已经失败的状态 `2`（`Off`）。脚本会先启动 ETW 和快照，五秒后发送命令，观察 120 秒，然后自动唤醒显示器。

```powershell
.\diagnostics\test-active-path-sleep-experiment.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy LowPower `
  -TriggerAfterSeconds 5 `
  -ObserveAfterDisplayOffSeconds 120
```

2026-07-10 的 `test4` 已否决该策略。状态 `1` 在 `20:11:21` 发出，但 `ConsoleDisplayState=0` 约 45 秒后才出现，说明 LowPower 没有立即触发 display-off。真正 off 后约 `+21s` 开始密集出现 `SuspendRequestSent`；物理黑色背光再次亮起，观察快照仍为 `Display Active: Enabled`。不要重复测试，也不要接入正式 runtime。

### 2. 真实临时模式切换

从 `ListModes` 输出中选择一条与 `CURRENT` 不同的模式。下面只是示例，只有列表确实包含这条模式时才能使用：

```powershell
.\diagnostics\test-active-path-sleep-experiment.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy ModeTransition `
  -TemporaryWidth 1920 `
  -TemporaryHeight 1080 `
  -TemporaryRefreshRate 60 `
  -ObserveAfterDisplayOffSeconds 120
```

模式通过 `ChangeDisplaySettingsEx` 动态应用，不写持久配置。bridge 会先用 `CDS_TEST` 验证枚举到的 `DEVMODE`，再连续采样十次、每次间隔 500 毫秒，只有请求模式稳定保持五秒才会继续。切换后画面正常时按 Enter，然后不要再使用输入设备，等待电源计划自然息屏；唤醒或出错后会精确恢复原模式。它与已否决的 CCD 实验不同：这里会真正切换到另一条已枚举模式，而不是重提完全相同的原生模式。

### 3. 目标适配器 D3D11 keep-alive

```powershell
.\diagnostics\test-active-path-sleep-experiment.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy D3dKeepAlive `
  -KeepAliveIntervalMilliseconds 1000 `
  -ObserveAfterDisplayOffSeconds 120
```

bridge 会把目标 DisplayConfig adapter LUID 映射到同一个 DXGI adapter，只创建一个 256 字节 D3D11 constant buffer，并周期性更新和 flush。它没有窗口、swap chain、present 调用或 `DISPLAY_REQUIRED` 请求。该实验用于判断活动 WDDM 图形上下文能否阻止异常 D3/D0 输出电源循环，不应预设为长期节能方案。

2026-07-10 的 `test5` 已否决该策略。D3D11 device 精确匹配 C340 的 NVIDIA adapter LUID `00000000:00010309`，完整执行 `254` 次 pulse 且 `failure=none`，贯穿自然 display-off 和完整 120 秒观察。黑色背光仍然出现，NVIDIA 仍为 `Display Active: Enabled`，约 `+68s` 开始重复出现 `SuspendRequestSent`。相对另一轮较晚出现不足以证明有实用效果；不要继续提高 GPU 负载，也不要接入正式 runtime。

`test7` 和 `test8` 都不能算作有效的模式切换结果。两次实验状态和三份 CCD 快照全部仍是 `3440x1440 @ 99.998Hz`，并不是请求的 60Hz。`test8` 在同一个 PowerShell 进程中复用了已经加载的 V1 bridge 类型，所以替换 C# 源码不会让该类型重新加载。新 PowerShell 进程可以加载修正版，但不再要求继续测试。

这条分支正式关闭。更早的 60Hz 物理 DPMS 测试已经复现黑色背光，而且普通枚举模式之间切换没有证据表明能进入已知正常的 NVIDIA CustomDisplay 电源路径。`LowPower`、`D3dKeepAlive` 和 `ModeTransition` 都不得接入正式 listener。

## Windows 公开接口边界

其余有文档的 Windows 接口，没有为普通桌面显示器提供通用的用户态物理输出电源 setter：

- [`GUID_CONSOLE_DISPLAY_STATE` 和 `GUID_MONITOR_POWER_ON`](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids) 是电源状态通知。
- [`DisplaySource.Status`](https://learn.microsoft.com/en-us/uwp/api/windows.devices.display.core.displaysource) 是只读状态；`Windows.Devices.Display.Core` 面向驱动专用显示器的自定义 compositor。
- [`IOCTL_VIDEO_SET_POWER_MANAGEMENT`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddvdeo/ni-ntddvdeo-ioctl_video_set_power_management) 在现代 Windows 已过时且不受支持。
- [`DxgkDdiSetPowerState`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/nc-dispmprt-dxgkddi_set_power_state) 是 WDDM display miniport 驱动回调，不是应用 API。
- [`CIM_Display.SetPowerState`](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/setpowerstate-method-in-class-cim-display) 没有由 WMI 实现。

`SC_MONITORPOWER` 仍是诊断触发器使用的公开用户态请求，但该请求如何转换为物理链路/输出状态，仍由 Windows 和显示驱动负责。脚本无法以厂商无关方式替换这部分驱动行为。

## 已完成：查找现有显示锚点

```powershell
.\diagnostics\inspect-displayconfig-anchor-candidates.ps1
```

该命令只调用 `QueryDisplayConfig(QDC_ALL_PATHS)` 和只读 PnP 查询，不修改显示拓扑。默认只输出 active path 和候选摘要；只有需要完整 inactive path 证据时才添加 `-IncludeAllPaths`。结果写入：

```text
.\log\diagnostics\displayconfig-anchor-candidates-YYYYMMDD-HHMMSS.log
```

2026-07-10 的 C340 单屏结果为 `allPaths=172`、`activeTargets=1`、`candidateTargets=0`。所有 inactive target 都不可用且不可强制。

下一步是 `anchor-driver/` 中的单显示器 IDD 隔离实验。检查器会把识别到的实验 target 单独输出为 `ANCHOR`，即使 Windows 第一次发现它时自动设成 active 也不会漏掉。只有控制器运行后恰好出现一个 `targetAvailable=True`、`outputTech=16` 的 `ANCHOR`，才能继续实现受控的锚点激活和问题显示器移除。

微软说明 `QDC_ALL_PATHS` 会返回当前连接集合中的全部可能路径，而未连接的数字 target 不能像模拟 target 一样被强制启用：

- [QueryDisplayConfig function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig)
- [Forced versus connected targets](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/forced-versus-connected-targets)

## 驱动回退阶段

不要在第一阶段之前回退驱动。第一阶段只改变 NVIDIA 模式，能最大限度控制变量。

驱动对照需要分别保留工作和故障状态的 ETW、`dispdiag` 和驱动文件版本。NVIDIA 官方也建议对驱动更新后出现的显示问题收集工作/故障两组记录：

- [NVIDIA display issue logging guide](https://nvidia.custhelp.com/app/answers/detail/a_id/5149/)

内核 dump 会主动触发系统崩溃，不属于本脚本范围；只有准备向 NVIDIA 提交正式驱动缺陷时再按官方步骤执行。
