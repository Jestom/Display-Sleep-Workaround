# Topology DDC Sleep Anchor（实验）

语言：[English](README.md) | 简体中文

该目录包含一个实验性 Windows Indirect Display Driver（IDD）和软设备控制器。它只创建一个低分辨率虚拟显示目标，用于单物理显示器场景中的临时 DisplayConfig topology 锚点。

## 当前阶段

IDD 尚未接入正式 workaround。第一阶段只验证下面的设备生命周期：

1. 平时不存在可用的 anchor target。
2. 控制器运行时，Windows 报告且只报告一个 `targetAvailable=True`、`outputTech=16` 的 `TopologyDdcciAnchor` target。
3. 控制器结束后，该 target 不再可用，原物理 active target 集合恢复一致。

这一阶段不调用 `SetDisplayConfig`，不移除物理显示器，也不触发息屏。通过后才会实现“临时激活 anchor -> 移除问题物理 target -> 息屏 -> 唤醒后恢复”的第二阶段。

Windows 可能在 IDD 第一次出现时自动激活新显示器，因此桌面布局可能短暂变化。控制器撤销后必须自动恢复；否则本阶段判定失败。

## 设计边界

- 只报告一个虚拟显示器，不做通用虚拟显示产品。
- 使用固定 monitor container ID，避免每次启动生成随机设备身份。
- 不伪造实体显示器 EDID。
- 只提供 `1024x768`、`800x600`、`640x480` 三种 60 Hz 保守模式。
- output technology 为 `DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_WIRED`（`outputTech=16`）。
- 控制器持有软设备；控制器退出或被终止时，Windows 撤销该设备。
- 正式 workaround、DP 诊断驱动和 IDD 实验保持相互隔离。

实现基于微软官方 `video/IndirectDisplay` 示例。来源记录见 `THIRD-PARTY-NOTICES.md`，完整 MS-PL 许可见 `LICENSE-MS-PL.txt`。

官方资料：[Indirect display driver model overview](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview)、[Building IddCx 1.4 drivers](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/building-iddcx1.4-drivers)

## 1. 在编译电脑构建

要求：

- Windows 11 build 22000 或更新版本。
- Visual Studio、Desktop C++ 工具、匹配的 Windows SDK 和完整 WDK。
- 驱动项目要求的 MSVC Spectre-mitigated libraries。

在 `work` 目录执行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\anchor-driver\build-anchor-driver.ps1 -Configuration Release -Platform x64
```

脚本优先使用 64 位 MSBuild，检查 `iddcx.h`，使用本地时间生成 catalog，并把完整测试包统一复制到：

```text
anchor-driver\out\x64
```

构建日志写入 `log\anchor-driver`。成功输出至少包含：

```text
TopologyAnchorDriver.dll
TopologyAnchorDriver.inf
TopologyAnchorDriver.cat
TopologyAnchorController.exe
TopologyAnchorTest.cer
```

把整个 `anchor-driver\out\x64` 文件夹复制到问题电脑对应位置，不要只复制 DLL 或 INF。

## 2. 在问题电脑安装

测试签名、Secure Boot 和证书信任会影响整台电脑。本项目不会自动启用 Windows test-signing，也不会关闭 Secure Boot。

在问题电脑的管理员 PowerShell 中执行：

```powershell
cd "D:\path\to\Display-Sleep-Workaround\anchor-driver"
Set-ExecutionPolicy -Scope Process Bypass
.\install-anchor-driver.ps1 -TrustTestCertificate
```

`-TrustTestCertificate` 是显式操作，会把本地 WDK 测试证书加入 `LocalMachine\Root` 和 `LocalMachine\TrustedPublisher`。仅应对自己编译并复制的受控测试包使用。若该证书已经受信任，以后可以省略该参数：

```powershell
.\install-anchor-driver.ps1
```

安装脚本只把驱动包暂存到 Driver Store，不会立即创建虚拟显示器。

## 3. 执行第一阶段验收

保持正式 workaround 计划任务停止，然后在同一个管理员窗口执行：

```powershell
Stop-ScheduledTask `
  -TaskName "Topology DDC Sleep Workaround" `
  -ErrorAction SilentlyContinue

.\test-anchor-availability.ps1
```

脚本会自动完成：

- 记录启动前 DisplayConfig；
- 临时启动 `TopologyAnchorController.exe`；
- 验证恰好一个可用的 indirect-wired anchor；
- 停止控制器并撤销软设备；
- 验证 anchor 不再可用，且原物理 active target 集合恢复。

成功结尾必须是：

```text
PASS: one available indirect-wired anchor was observed and then withdrawn; active physical targets were restored.
```

日志位于：

```text
work\log\anchor-driver
work\log\diagnostics
```

即使 `QDC_ALL_PATHS` 留下不可用的历史 anchor path，只要它是 `targetAvailable=False` 且未 active，就不算控制器仍在运行。验收关注的是“可用 target”是否正确出现和撤销。

没有 `PASS`、出现显示驱动警告、脚本结束后桌面布局没有恢复，或设备管理器出现黄色感叹号，都不要继续第二阶段。

## 4. 完整卸载

在管理员 PowerShell 中执行：

```powershell
.\uninstall-anchor-driver.ps1
```

脚本会停止遗留的 anchor 控制器并从 Driver Store 删除 `TopologyAnchorDriver.inf` 包。显式信任的测试证书不会自动删除，因为同一 WDK 证书可能还被 DP probe 使用。

## 当前不做的事情

- 不把 IDD 常驻为第二块桌面。
- 不在这一轮测试息屏或黑色背光。
- 不让正式任务自动安装驱动。
- 不在 anchor 可用性验证前接入 topology 切换。
- 不将本地测试签名包作为普通用户发行包。

面向普通用户发布驱动最终需要 Microsoft 接受的签名；本地测试签名只适合受控开发验证。
