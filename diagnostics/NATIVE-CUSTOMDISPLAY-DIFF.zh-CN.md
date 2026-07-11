# 原生模式与 CustomDisplay 证据审计

## 范围

本报告对比已经完成的两份单屏取证：

- 原生故障：`screenshot/20260710-142806-current-native-bad`
- CustomDisplay 正常：`screenshot/20260710-143319-current-custom-good`

报告严格区分事实和解释。NVIDIA 控制面板自定义模式只是对“GPU、驱动、DisplayPort、显示器”整条链路的一次干预，不能仅凭它有效就判定故障归属。

## 已确认矩阵

| 层面 | 原生故障 | CustomDisplay 正常 | 判断 |
| --- | --- | --- | --- |
| 物理拓扑 | C340 单屏连接 NVIDIA DP | 相同 | 已控制 |
| Windows | Windows 11 build 28000 | 同一次启动、相同 build | 已控制 |
| NVIDIA 适配器 | RTX 3070 Ti | 相同实例 | 已控制 |
| NVIDIA 驱动 | `32.0.16.1062` | 相同 | 已控制 |
| 显示器驱动 | Microsoft `monitor.inf` | 相同 | 已控制 |
| Console display state | 已观察到 Off | 已观察到 Off | 两组均由 Windows 发起息屏 |
| Active CCD path | 全程只有 C340 一条 | 相同 | 拓扑相同 |
| 活动分辨率 | 3440x1440 | 3440x1440 | 相同 |
| CCD 刷新率 | `99998/1000`（99.998Hz） | `100/1`（100.000Hz） | 可见模式差异，但不足以解释根因 |
| 息屏后 120 秒 GPU P-state | P8 | P8 | 相同 |
| 息屏后 120 秒 Display Attached | Yes | Yes | 相同 |
| 息屏后 120 秒 Display Active | **Enabled** | **Disabled** | 最强的已观测差异 |
| 息屏后 120 秒 GPU 平均功耗 | 6.80W | 6.19W | 小幅结果差异，不是已证实原因 |
| D0 / Suspend / D3 组数 | 10 / 10 / 10 | 9 / 9 / 9 | 相差一组，不足以证明因果 |
| `DevicePoweredOn` / `DevicePreparation` | 筛选结果中没有 | 筛选结果中没有 | 本组 A/B 无区分度 |
| 应用电源请求 | 空 | 空 | 已控制 |
| 肉眼结果 | 亮起黑色背光 | 持续真正息屏 | 已确认区分结果 |

用户还确认：仅保留已保存的自定义分辨率记录没有作用。只要当前活动模式切换到任意原生分辨率或刷新率，故障就立即恢复。因此，正常状态与“当前实际激活 CustomDisplay 路径”绑定，不是创建记录后留下的一次性持久重置。

此前 CRU 测试也已经输出相同的 `533.16MHz / 100.000Hz` 有效时序，但没有复制正常行为。因此，像素时钟和刷新率数值本身不能解释结果。

## 同步 25 秒边界

后续 `test15`/`test16` 同步 A/B 在等待期间不调用 AUX，并捕获到了第一次故障边界。原生故障与 CustomDisplay 正常状态都在约 `+24.4s` 收到内核显示中断，随后出现 `VidMmWakeReason_StatusChangeEvent`、DMM target/validation 未初始化、`DdiSetTimingsFromVidPn`、`DdiSetVidPnSourceVisibility`、连接失效处理和显示模式重建。

第一个实质差异出现在 `DxgkInvalidateMonitorConnections` 内部。原生故障路径调用 `WakeUpAdapter`、发出 `IrpRequestSentD0`、恢复 VidMm segments 并构建 paging buffers；CustomDisplay 正常路径没有进入这条适配器恢复链，仍保持 `Display Active: Disabled`。其观察点 DPCD 读取以控制器退出码 `3` 返回，符合 target 仍处于深度息屏、暂时不可读；同一个退出码本身不是物理电源状态测量。

因此，共同的状态通知不足以导致故障，DWM、NVIDIA Container 和观察点探针也不是发起者。剩余区分条件是 target 重建之后的私有适配器/miniport 恢复决策。公开 ETW 能显示驱动最终选择了哪条分支，但看不到用于选择分支的模式分类字段或条件。

## 内核探针之后仍不可见的变量

后续只读 DP 探针已经取得协商后的 HBR2/四 lane、DPCD sink 电源和 lane 状态，并证明原生故障会回到 D0/已训练链路，而 CustomDisplay 正常状态保持 D3/链路断开。仍不可见的是以下参数或顺序：

- display-off 期间的 AUX 读写顺序；
- 链路训练次数和发生时间；
- main link 禁用、blanking 和重新启用顺序；
- 自定义路径是否改变 MSA、颜色传输、DSC、VRR 或其他私有模式属性；
- 独立于 GPU 报告的 C340 scaler 与背光硬件状态。

这些变量中的任何一个，都可能导致桌面几何参数看似相同的两个模式进入不同的物理电源状态。

## 公开接口审计

### 用户态能够读取的内容

Windows CCD 的 [`DISPLAYCONFIG_PATH_TARGET_INFO`](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_path_target_info) 包含连接类型、target 可用性、旋转、缩放、刷新率和模式索引。[`DISPLAYCONFIG_VIDEO_SIGNAL_INFO`](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_video_signal_info) 还能提供像素时钟、水平/垂直同步、活动尺寸、总尺寸、视频标准和扫描方式。两者都没有 DP link rate、lane count、DPCD 状态或 AUX 事务。

[`DXGI_OUTPUT_DESC1`](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_6/ns-dxgi1_6-dxgi_output_desc1) 可以读取桌面连接、旋转、活动线路色深、色彩空间、色域和亮度数据，但不包含 DP 链路协商或电源寄存器。

[`DisplayConfigGetDeviceInfo`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-displayconfiggetdeviceinfo) 可以获取名称、首选模式、适配器标识和高级颜色等 target 元数据；公开 request type 中没有 link rate、lane count、DPCD 或 AUX 历史。

电源 GUID 只报告操作系统级状态。[`GUID_CONSOLE_DISPLAY_STATE`](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids) 能确认 Windows 认为显示器已关闭，但不能证明物理 DP sink 或背光状态。

### 只存在于内核显示接口中的内容

WDDM 定义了只读的 [`DXGK_DIAG_DISPLAY_LINK_STATE`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ne-dispmprt-dxgk_diag_display_link_state)，可以区分稳定、失败、训练中和反复训练状态。但承载它的 [`DXGK_DISPLAY_DIAGNOSTICS_INTERFACE`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-dxgk_display_diagnostics_interface) 明确由**内核模式组件**向 display miniport driver 查询。

WDDM 也定义了 [`DXGK_DP_INTERFACE`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-dxgk_dp_interface) 和 [`DXGKARG_DPAUXIOTRANSMISSION`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-dxgkarg_dpauxiotransmission)，用于 DPCD/AUX 访问。这些接口通过 miniport driver 的 `DxgkDdiQueryInterface` 获取，并不是公开应用程序 API。

`dispdiag` 可以保存不透明的诊断文件，但 Microsoft 只公开了采集参数，没有公开可支持的文件结构或用户态接口来提取上述内核链路状态字段。

## 决策

不再编写新的 PowerShell/C# 用户态采集器。它只能重复已经明确的时序、拓扑、颜色和高层电源事件，仍然拿不到私有 miniport 恢复决策。

不把故障单独归因于 NVIDIA。现有证据支持的是：当前活动的原生路径与 CustomDisplay 路径进入了不同的 DP 电源行为，差异可能横跨模式分类、GPU 驱动、链路命令顺序和 C340 固件。

已经完成的只读内核探针确认了物理 D3/D0 状态，并把 `WakeUpAdapter` 定位为恢复分支的第一个区分点。NVIDIA miniport 拒绝公开 native AUX 写入，公开 ETW 也不暴露该分支使用的模式分类条件。如果要继续深入根因，至少需要以下一种条件：

1. 显卡厂商提供能够暴露显示链路转换的驱动诊断；
2. 使用 DisplayPort 协议分析仪捕获 AUX/DPCD 和 main link；
3. 开发能够观察 miniport 私有恢复决策的厂商相关内核/显示诊断，能力超过已经验证的公开只读 WDDM 接口。

这些都不适合作为当前脚本项目的生产依赖。已经验证的多 path 拓扑 workaround 保持不变。通用单屏修复在协议、驱动或固件层仍有研究空间，但公开用户态脚本路线已经走到边界。
