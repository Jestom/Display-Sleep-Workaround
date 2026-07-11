# Topology DP Link Diagnostic Probe

语言：[English](README.md) | 简体中文

这是单显示器根因调查的第一阶段内核探针，不是新的正式修复。它在保留 active DisplayConfig path 的情况下，通过 WDDM 2.7 公开的 `DXGK_DP_INTERFACE` 读取 DP 地址和 DPCD，用来比较“原生模式亮黑色背光”和“CustomDisplay 正常息屏”两种状态。

## 安全边界

当前源码有以下硬限制：

- 只安装一个独立的 `Root\TopologyDpProbe` KMDF 设备，不替换、不附着、不过滤 NVIDIA、显示器或 ACPI 驱动；它只把已注册的 monitor device interface 当作临时远程 I/O target。
- 不处理、不拦截、不伪造 power IRP。
- 不调用 `SetDisplayConfig`，不改变 active path，不创建虚拟显示器。
- 默认取证路径只请求 `DxgkDdiQueryDPCaps`、`DxgkDdiGetDPAddress` 和 native AUX read。
- 协议 v4 增加一个实验性受限能力门槛：只允许直接非 MST target 的标准 `DPCD 0x600 SET_POWER` D0 (`01`) 幂等写入，长度固定为 1。D3 已在源码层禁用，不存在任意 DPCD 地址、长度或数据写接口。
- 每次请求结束立即调用 `InterfaceDereference` 并关闭远程 I/O target，不长期持有显示设备栈。

即使只读，内核驱动和 AUX 访问也不等于零风险。显示 miniport 可能为了完成读取而临时处理链路或唤醒硬件，因此“息屏后第一次读取”本身也要被视为有观察副作用。`set-power` 写入更具侵入性，仅用于显式 D0 能力门槛，不会由快照或正式 topology runtime 自动调用。

## 运行要求

- x64 Windows 10 2004（build 19041）或更高版本。
- GPU 驱动支持 WDDM 2.7 或更高版本以及 `GUID_DXGK_DP_INTERFACE`。
- Visual Studio 2022，安装“使用 C++ 的桌面开发”。
- 与 Windows SDK 匹配的 Windows Driver Kit（WDK）。
- 用于实验驱动的有效签名环境。测试签名和 Secure Boot 策略由测试机器决定，本工程不会自动修改启动配置。

不要直接在唯一且无法恢复的工作环境上首次加载实验驱动。先准备系统还原点、恢复环境或另一种远程管理方式。

## 构建

在安装了 Visual Studio 和 WDK 的 Windows 管理员 PowerShell 中进入本目录：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build-dp-link-probe.ps1 -Configuration Release
```

成功后输出位于：

```text
.\out\x64\
```

其中应包含：

```text
TopologyDpProbeDriver.sys
TopologyDpProbeDriver.inf
TopologyDpProbeDriver.cat
TopologyDpProbeCtl.exe
```

Linux 只能检查源码和工程结构，不能生成或加载 Windows `.sys`。当前工程必须在 Windows + WDK 上完成第一次真实编译。

## 安装

WDK 自带 `devcon.exe`。在管理员 PowerShell 中执行：

```powershell
.\install-dp-link-probe.ps1
```

脚本只创建 `Root\TopologyDpProbe` 根枚举设备，不会重启或替换显示适配器。若 Windows 拒绝目录签名或驱动签名，应先修复测试签名环境，不要绕过错误继续。

## 第一道门槛：只查询接口

安装后先只运行：

```powershell
.\out\x64\TopologyDpProbeCtl.exe list
```

重点查看与目标显示器路径对应的 `monitor` 状态：

```text
controllerRevision=3 probeProtocolVersion=4 monitorInterfaces=...
open=0x00000000 dpInterface=0x00000000 caps=0x00000000
interfaceGate=PASS safeToRunRead=true
```

目标显示器（例如路径中包含 `DISPLAY#HKCB34C`）必须满足以上三项成功，并返回非零 `rootPorts`。如果所有 `dpInterface` 都失败，`list` 会返回退出码 3，采集脚本也会在发送任何 DPCD read 前中止。

早期 v1 探针错误地枚举了 `GUID_DISPLAY_DEVICE_ARRIVAL` 显示适配器接口，实测全部返回 `0xC00000BB (STATUS_NOT_SUPPORTED)`。v2 改为枚举 `GUID_DEVINTERFACE_MONITOR`：每个 monitor 节点是显示适配器的子设备，查询会沿该子设备栈交给 `Dxgkrnl`，再由它调用 miniport 的 `DxgkDdiQueryInterface`。这仍然是一次有明确目标的验证；WDDM 2.7 提供该 DDI 不代表每个厂商驱动都必须向这个调用方返回接口。

状态不是 `0x00000000` 时要保留完整输出，不要只截最后一行。

## TargetId

`TargetId` 是十进制 DisplayConfig target ID，不是 `DISPLAY#HKCB34C` 字符串。可先回到 `work` 目录查询：

```powershell
.\topology-ddcci-workaround.ps1 -ListDisplays -NoLog
```

C340 的已有日志中是：

```text
targetId=4357
```

target ID 可能在驱动、接口或拓扑变化后改变，每次正式采集前都应重新确认。

## 单次只读快照

接口查询成功后，先在屏幕亮着时执行：

```powershell
.\out\x64\TopologyDpProbeCtl.exe snapshot --target 4357
```

如果配置了多台显示器，可根据 `list` 中的路径固定目标 monitor：

```powershell
.\out\x64\TopologyDpProbeCtl.exe snapshot --target 4357 --monitor 0
```

快照读取四组标准 DPCD 区域：

```text
0x00000..0x0000f  receiver capability
0x00100..0x0010f  link configuration
0x00200..0x00207  link status
0x00600            sink power state
```

对 MST 下游显示器，`GetDPAddress` 会返回 `numLinks > 0`。当前探针会拒绝对这种目标执行 native AUX read，因为公开的 `DxgkDdiDPAuxIoTransmission` 只覆盖直接连接到 GPU 的设备，不能假装读取的是 MST 下游目标。

## v4 受限写入门槛

不要首先尝试 D3。升级并确认 `controllerRevision=3 probeProtocolVersion=4` 后，只在屏幕亮着且 `0x600=01` 时测试一次幂等的 D0 写入：

```powershell
.\out\x64\TopologyDpProbeCtl.exe set-power `
  --monitor 0 `
  --target 4357 `
  --state d0 `
  --confirm-standard-dpcd-write
```

只有 `write=0x00000000` 且 `bytesDone=1` 才表示 miniport 接受标准 AUX write。随后用只读命令确认仍为 D0：

```powershell
.\out\x64\TopologyDpProbeCtl.exe read `
  --monitor 0 `
  --target 4357 `
  --address 0x600 `
  --length 1
```

若写入返回任何错误，到这里停止，也不通过其它地址规避驱动限制。受影响机器上的 NVIDIA miniport 已返回 `write=0xC000000D`、native error `0xC0000022` 和 `bytesDone=0`，因此该路线关闭，源码也已拒绝 D3。未来只有在其它硬件先通过 D0 门槛并具备独立恢复 watchdog 后，才能在新协议中重新评估 D3。

## 息屏 A/B 采集

先停止已安装的 topology listener，避免它在采集期间移除 target：

```powershell
Stop-ScheduledTask -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
```

采集器还会检查残留 listener 进程并在冲突时拒绝启动。随后它读取一次亮屏基线，通过 `SC_MONITORPOWER` 主动请求息屏；中间 120 秒完全不调用探针，最后只执行一次息屏状态快照并恢复显示器：

```powershell
.\capture-dp-link-sleep.ps1 `
  -TargetId 4357 `
  -ObserveAfterDisplayOffSeconds 120
```

若 `list` 已确认正确 monitor，也可减少无关请求：

```powershell
.\capture-dp-link-sleep.ps1 `
  -TargetId 4357 `
  -MonitorIndex 0 `
  -ObserveAfterDisplayOffSeconds 120
```

日志写入：

```text
..\log\diagnostics\YYYYMMDD-HHMMSS-dp-link-readonly.log
```

需要分别采集：

1. 当前活动模式为 EDID 原生模式，复现亮黑色背光。
2. 当前活动模式为已知正常息屏的 NVIDIA CustomDisplay 模式。

两次测试之间不要同时运行 topology workaround。其它显示模式、线材、端口和电源计划应保持不变。

该脚本是受控的主动 DPMS A/B，不等同于电源计划自然到时的完整时序。第一阶段先确认 DXGK 接口和 DPCD 读取能力；接口通过后，再把相同的单次快照挂到现有 `diagnostics\capture-natural-display-sleep.ps1` 的自然 display-off 观察点，不能用这份主动结果替代最终自然息屏结论。

`AuxStatus=0x8000000F (STATUS_DEVICE_POWERED_OFF)` 一类 powered-off 状态本身就是有效证据，不代表探针设计失败；它可能说明正确息屏时 miniport 已无法进行 AUX 读取。最终判断必须比较两份完整日志中的接口状态、DP 地址、DPCD 数据和读取错误，不能只看 `0x600` 一个字节。

## 卸载

```powershell
.\uninstall-dp-link-probe.ps1
```

该命令移除根设备并停止驱动。已暂存的驱动包仍留在 Driver Store；需要彻底删除时，先用 `pnputil /enum-drivers` 找到对应的 `oemXX.inf`，确认 Provider 和名称后再执行 `pnputil /delete-driver oemXX.inf /uninstall`。

## 公开接口依据

- [DXGK_DP_INTERFACE](https://learn.microsoft.com/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-dxgk_dp_interface)
- [DXGKDDI_GETDPADDRESS](https://learn.microsoft.com/windows-hardware/drivers/ddi/dispmprt/nc-dispmprt-dxgkddi_getdpaddress)
- [DXGKDDI_DPAUXIOTRANSMISSION](https://learn.microsoft.com/windows-hardware/drivers/ddi/dispmprt/nc-dispmprt-dxgkddi_dpauxiotransmission)
- [WdfIoTargetQueryForInterface](https://learn.microsoft.com/windows-hardware/drivers/ddi/wdfiotarget/nf-wdfiotarget-wdfiotargetqueryforinterface)
- [GUID_DEVINTERFACE_MONITOR](https://learn.microsoft.com/windows-hardware/drivers/install/guid-devinterface-monitor)
- [Supporting Video Capture and Other Child Devices](https://learn.microsoft.com/windows-hardware/drivers/display/supporting-video-capture-and-other-child-devices)
