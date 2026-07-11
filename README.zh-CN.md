# Display Sleep Workaround

语言：[English](README.md) | 简体中文

这是一个 Windows 显示器息屏绕过工具，用于处理部分显示器无法保持真正休眠，而是进入带背光黑屏或无效信号状态的问题。

程序不会禁用 GPU 或显示适配器。默认的 `PowerEvent` 模式保留 Windows 电源计划的原生息屏流程；收到 Windows display-off 通知后，把指定问题显示器移出 active DisplayConfig topology，唤醒时再恢复之前捕获的 topology。未被选中的健康显示器继续使用 Windows 原生息屏，不依赖 DDC/CI。

## 已确认的行为

第一个验证硬件是通过 NVIDIA DisplayPort 连接的 HKC C340，H249W 作为剩余 active 显示器。

2026-07-10 已确认三种行为：

```text
Windows 电源计划自然息屏 + PowerEvent 移除 C340 -> 双屏正常息屏，DDC/CI 禁用
脚本主动发送 SC_MONITORPOWER + 随后移除 C340 -> C340 可能亮黑色背光
不发 DPMS，先移除 C340 -> C340 真正息屏，剩余 H249W 保持亮屏
```

自然 `PowerEvent` 测试中，日志明确记录 `RemainingDisplayPowerMode=Disabled`，因此双屏息屏没有使用 DDC/CI。唤醒后原双屏 topology 和 H249W 的位置也恢复成功。

脚本主动发送的测试 DPMS 不能等同于 Windows 电源计划的自然息屏路径。DDC/CI 仍是可选功能，主要用于 `IdlePreempt` 模式下关闭被 Windows 原生 DPMS 抑制的剩余显示器。

## 文件说明

- `topology-ddcci-workaround.ps1`
  长期运行 listener 和常规测试入口。

- `topology-ddcci-core.ps1`
  DisplayConfig、Windows 电源事件、空闲检测、DDC/CI 和恢复逻辑。

- `install-topology-ddcci-workaround-task.ps1`
  安装或更新登录自启动计划任务。

- `start-topology-ddcci-hidden.vbs`
  计划任务使用的隐藏启动器。

- `uninstall-topology-ddcci-workaround-task.ps1`
  删除计划任务并停止 listener。

- `VALIDATION.md`
  当前验证状态和待执行的 Windows 测试。

- `RESEARCH-NOTES.md`
  第一个案例的历史排查记录。

- `diagnostics/`
  自然息屏 ETW/DisplayConfig/驱动状态 A/B 取证工具，不执行 workaround。

- `anchor-driver/`
  实验性单显示器 Indirect Display Driver、软设备控制器及可撤销的一键 target 生命周期验收。尚未接入正式 runtime，说明见 [anchor-driver/README.zh-CN.md](anchor-driver/README.zh-CN.md)。

- `dp-link-probe/`
  实验性 KMDF/WDDM 诊断探针，在保留正常 active path 时采集 DP 地址和 DPCD 证据。协议 v4 另有一个显式确认、仅限标准 `0x600` D0 幂等写入的能力门槛，D3 已禁用；它尚不是修复方案，也没有接入正式 runtime，说明见 [dp-link-probe/README.zh-CN.md](dp-link-probe/README.zh-CN.md)。

## 选择目标显示器

列出 active DisplayConfig path：

```powershell
.\topology-ddcci-workaround.ps1 -ListDisplays -NoLog
```

从目标 path 中选择稳定标识。例如已验证的 C340 输出为：

```text
friendly=C340 path=\\?\DISPLAY#HKCB34C#...
```

因此目标条件是：

```powershell
-TargetNeedles "DISPLAY#HKCB34C"
```

不要把文档占位符当成真实 ID。脚本现在会在任何显示器电源动作之前拒绝 `YOUR_MONITOR_ID`。

可用条件：

```text
TargetNeedles           一个或多个字符串，匹配 DisplayConfig friendly/path。
TargetId                DisplayConfig targetId，默认 -1 表示不限制。
TargetOutputTechnology  DisplayConfig outputTech，默认 -1 表示不限制。
```

不同类型条件按 AND 组合；多个 `TargetNeedles` 之间按 OR 匹配。

## 模式选择

| 模式 | 用途 | 剩余显示器 |
| --- | --- | --- |
| `PowerEvent` | 默认和多屏首选。监听 Windows 电源计划的自然 display-off/on 通知。 | 继续使用 Windows 原生息屏；通常不需要 DDC/CI。 |
| `IdlePreempt` | 备用模式。在 Windows DPMS 前按输入空闲时间移除目标。 | 原生 DPMS 被抑制；要一同息屏通常需要支持 DDC/CI。 |

安装和测试时建议显式填写 `TriggerMode`，便于日志和故障排查。`IdleTimeoutSeconds` 只在 `IdlePreempt` 模式中使用。

## 多屏测试

直接测试前先停止已经安装的通用或旧版 listener。入口脚本会拒绝并行 listener，避免两个进程同时改写 topology。

```powershell
Stop-ScheduledTask -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
```

下面的首选测试等待 Windows 电源计划自然息屏。Windows 原生关闭健康副屏，listener 收到 display-off 通知后移除 C340。其它电脑必须把示例 ID 换成自己 `-ListDisplays` 输出中的 ID。

```powershell
.\topology-ddcci-workaround.ps1 `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -ProfileName "C340" `
  -TriggerMode PowerEvent `
  -RemainingDisplayPowerMode Disabled `
  -TestOnce `
  -AutoRestoreAfterSeconds 180
```

预期日志：

```text
Target preflight: ... matchedPaths=1 keptPaths=1
PowerEvent native mode is active
ConsoleDisplayState=0
removedPaths=1 keptPaths=1
Remaining display DDC/CI power-off is disabled
```

必须等待电源计划自然触发，不要添加 `TriggerDpmsAfterSeconds`。移动鼠标或按键后，Windows 发出 display-on 通知，listener 恢复原 topology 并结束测试；如果没有输入，则在移除目标 180 秒后自动恢复。

## IdlePreempt 备用模式

只有在自然 `PowerEvent` 无法修复目标显示器时，才测试 `IdlePreempt`：

```powershell
.\topology-ddcci-workaround.ps1 `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -ProfileName "C340" `
  -TriggerMode IdlePreempt `
  -IdleTimeoutSeconds 5 `
  -RemainingDisplayPowerMode Disabled `
  -TestOnce `
  -AutoRestoreAfterSeconds 180
```

该模式会阻止 Windows 自动显示器 DPMS，然后先移除目标。因此 `Disabled` 下剩余显示器保持亮屏。只有剩余显示器支持并通过 DDC/CI 测试时，才可改成：

```powershell
-RemainingDisplayPowerMode DdcciAllRemaining
```

如果剩余显示器不支持 DDC/CI，又需要原生息屏，应使用 `PowerEvent`，不能使用 `IdlePreempt`。

## 正式安装

多屏 `PowerEvent` 测试通过后，在管理员 PowerShell 中运行：

```powershell
.\install-topology-ddcci-workaround-task.ps1 `
  -StartNow `
  -TaskName "Topology DDC Sleep Workaround" `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -ProfileName "C340" `
  -TriggerMode PowerEvent `
  -RemainingDisplayPowerMode Disabled
```

`PowerEvent` 的息屏时间完全由 Windows 电源计划控制。`RemainingDisplayPowerMode Disabled` 表示脚本不发送 DDC/CI；它不会禁止健康显示器走 Windows 原生息屏。

调试安装并启用日志：

```powershell
.\install-topology-ddcci-workaround-task.ps1 `
  -StartNow `
  -EnableLog `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -ProfileName "C340" `
  -TriggerMode PowerEvent `
  -RemainingDisplayPowerMode Disabled
```

日志目录：

```text
.\log\display-topology-ddcci-YYYYMMDD-HHMMSS.log
```

## 单屏实验测试

正常运行模式会拒绝移除最后一条 active display path。要支持单屏，必须先验证当前 Windows/GPU 驱动是否接受“零 active path”的 supplied configuration。

断开或停用所有副屏，先确认 `-ListDisplays` 只显示一条 active path，然后运行：

```powershell
.\topology-ddcci-workaround.ps1 `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -ProfileName "C340-Single" `
  -TriggerMode IdlePreempt `
  -IdleTimeoutSeconds 5 `
  -RemainingDisplayPowerMode Disabled `
  -ExperimentalAllowZeroActivePaths `
  -TestOnce `
  -AutoRestoreAfterSeconds 180 `
  -EmergencyRestoreSeconds 240
```

安全措施：

- 脚本先调用 `SetDisplayConfig` 验证零路径请求。
- 只有显式 `IdlePreempt + TestOnce + 正数 IdleTimeoutSeconds` 才允许实验。
- `AutoRestoreAfterSeconds` 不能短于 60 秒，独立救援时间必须至少再晚 15 秒。
- 应用零路径之前，会启动一个独立的隐藏 PowerShell 救援进程。
- 同时写入当前用户的 `RunOnce` 救援项；如果实验期间重启，下次登录会执行 `DisplaySwitch.exe /extend`。
- 正常恢复会还原精确捕获的 topology，并取消救援进程。
- 如果 listener 崩溃或无法恢复，救援进程会在 240 秒后执行 `DisplaySwitch.exe /extend`。
- 正式安装器故意不提供这个实验开关。

已验证的 C340 单屏环境在 `SetDisplayConfig` 验证零路径时返回 Win32 error `87 (ERROR_INVALID_PARAMETER)`，因此没有应用任何零 active path 配置，C340 path 始终保持 active。该机器不应重复此实验，也不能启用正式零路径单屏模式。

这份失败日志还暴露了 `TestOnce` 失败后重复触发的问题；最新版已保证测试成功或失败后立即停止 timer，最多尝试一次。对单物理显示器而言，测试机器上没有可复用的 inactive DisplayConfig target。目前找到的唯一厂商无关自动化 topology 架构，是用可选的 Indirect Display Driver target 临时充当锚点；它仍是实验方案，没有接入正式 runtime。

## 主动 DPMS 诊断

`TriggerDpmsAfterSeconds` 会通过 `SC_MONITORPOWER` 主动发送测试 DPMS，只用于诊断。它与 Windows 电源计划的自然息屏路径和时序不完全等价；C340 的主动测试曾亮起黑色背光，而自然 `PowerEvent` 已成功实现双屏息屏。

```powershell
.\topology-ddcci-workaround.ps1 `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -TriggerMode PowerEvent `
  -TestOnce `
  -TriggerDpmsAfterSeconds 5 `
  -AutoRestoreAfterSeconds 180
```

不要用这条主动测试命令判断正式 `PowerEvent` 安装一定失败或成功；正式验证必须等待电源计划自然息屏。

## 根因取证

NVIDIA 自定义分辨率只作为“能改变故障状态机”的 A/B 探针，不作为正式修复依赖。新的只读取证脚本会等待 Windows 自然息屏，对比当前驱动下的原生模式故障状态和 NVIDIA CustomDisplay 正常状态：

```powershell
.\diagnostics\capture-natural-display-sleep.ps1 -Label "current-native-bad"
.\diagnostics\capture-natural-display-sleep.ps1 -Label "current-custom-good"
```

2026-07-10 的 120 秒 A/B 已确认：两组都收到 Windows `ConsoleDisplayState=0`，但原生故障模式下 NVIDIA 在息屏后仍报告 `Display Active: Enabled`；CustomDisplay 正常模式则报告 `Display Active: Disabled`，唤醒后恢复 `Enabled`。这证明两种状态进入了不同的输出电源路径，但不能据此把根因单独归给 NVIDIA；自定义模式也可能改变链路训练、AUX/DPCD 顺序、模式缓存，或 C340 scaler 对断信号的响应。

后续同步 25 秒 A/B 进一步定位了故障分支。原生模式和 CustomDisplay 都收到同一条内核显示中断/状态变化通知，也都重建了 target VidPN；随后只有原生模式进入 `WakeUpAdapter`、请求适配器 D0 并恢复 VidMm segments，CustomDisplay 则在不进入该恢复链的情况下完成相同的连接失效处理，并保持物理息屏。因此，异常 D0 是在共同状态事件之后，由适配器/miniport 内部恢复决策选中的；公开 ETW 看不到它使用的模式判定条件。后续不再重复边界时间、重复 DPMS 或尝试屏蔽两组共有的状态事件。

用户还确认：仅保留已保存的自定义分辨率记录没有作用，只要当前活动模式切换为任意原生分辨率或刷新率，故障就立即恢复。这排除了“一次创建后隐藏状态持续生效”的假设，删除记录、重置驱动和重启等转换测试没有继续执行的意义。

后续两种公开 Windows CCD 模式重提交策略均已实测失败：API 调用成功，但自然息屏后 NVIDIA 仍为 `Display Active: Enabled`，因此没有接入正式 runtime。

随后进行的 NVIDIA `NvAPI_DISP_SetDisplayConfig + NV_FORCE_COMMIT_VIDPN` 实验也已否决。NVAPI 验证和应用都返回成功，NVAPI 与 Windows CCD 配置保持完全不变，画面也正常恢复；但自然息屏 120 秒观察点仍为 `Display Active: Enabled`，并且 display-off 后约 90.34 秒出现 `DevicePoweredOn`。这证明强制重提当前原生 VidPN 不能修复故障电源转换。项目不会继续把更深的 NVIDIA 专用模式提交接口当作通用修复方向；诊断脚本只作为可复现实验证据保留，详见 [diagnostics/README.zh-CN.md](diagnostics/README.zh-CN.md)。

保留单物理显示器 path 的 `SC_MONITORPOWER LowPower`、目标适配器 D3D11 keep-alive 和普通枚举模式切换均已关闭：它们没有证据能够进入 CustomDisplay 的已知正常状态。后续不再增加同类 active-path 变体。

Windows 没有公开的通用用户态接口，可以让脚本在保留正常桌面 path 的同时取代显示驱动的物理输出电源转换。`GUID_CONSOLE_DISPLAY_STATE` 和 `GUID_MONITOR_POWER_ON` 只是通知；`DisplaySource.Status` 是面向专用显示 compositor 的只读状态；旧 video power IOCTL 已不受支持；真正设置显示子设备电源的是 miniport 驱动回调。因此在用户态 topology 这一层，厂商无关的单屏 workaround 仍需要另一个有效 target，例如物理副屏、dummy target 或可选 IDD 锚点。内核诊断线路已经观察到失败的 D3 到 D0 恢复分支，但无法控制选择该分支的 NVIDIA 私有判定。

原生模式与 CustomDisplay 的离线证据矩阵及接口审计见 [diagnostics/NATIVE-CUSTOMDISPLAY-DIFF.zh-CN.md](diagnostics/NATIVE-CUSTOMDISPLAY-DIFF.zh-CN.md)。决定性的 DP 链路和 AUX/DPCD 字段只存在于内核显示接口或外部协议取证中，因此不再增加无法取得这些字段的用户态采集器。新的 [DP 链路诊断探针](dp-link-probe/README.zh-CN.md) 使用 WDDM 2.7 公开的 `DXGK_DP_INTERFACE` 取证；默认采集路径只读，协议 v4 仅增加一个需要显式确认的标准 `0x600` D0 能力门槛，D3 已禁用，也未接入正式修复流程。

随后执行的 `QDC_ALL_PATHS` 检查共发现 `172` 条可能 path，但没有可用的 inactive target，因此不能只靠 DisplayConfig 复用现有的断开 target。新的单锚点 IDD 实验位于 [anchor-driver](anchor-driver/README.zh-CN.md)，目前已补齐固定构建包、显式证书信任、安装/卸载和一键 target 生命周期验收；在 Windows 上通过该验收前，不会接入正式 runtime。

## 状态与卸载

查看计划任务：

```powershell
Get-ScheduledTask -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
Get-ScheduledTaskInfo -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
```

查看 listener 进程：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*topology-ddcci-workaround.ps1*" -or $_.CommandLine -like "*start-topology-ddcci-hidden.vbs*" } |
  Select-Object ProcessId,ParentProcessId,Name,CommandLine
```

卸载任务并停止 listener：

```powershell
.\uninstall-topology-ddcci-workaround-task.ps1 -TaskName "Topology DDC Sleep Workaround"
```

## 安全说明

- listener 执行显示器电源动作之前会预检目标匹配结果。
- 正常模式拒绝移除全部 active display path。
- 每次移除前都会在当前进程中捕获原 active topology，并在输入、自动恢复或 listener 退出时还原。
- 正常 DisplayConfig 恢复重试失败后，仍会 fallback 到 `DisplaySwitch.exe /extend`。
- 不要同时运行旧 C340 专用 listener 和新的通用 listener。安装器会禁用两个已知旧任务名，直接启动时也会拒绝与已检测到的 listener 并行运行。
- 每套硬件都必须先运行 `TestOnce`，通过后再正式安装。
