# Research Notes: First Display-Sleep Case Study

> This is the historical debugging log from the first validated hardware case. It intentionally contains C340/H249W-specific observations, old file names, and discarded experiments. The current generic runtime is documented in `README.md` and `VALIDATION.md`.

# HKC C340 DP 息屏后黑色背光问题排查记录

记录时间：2026-07-06

## 问题现象

- C340 使用 DisplayPort 连接 RTX 3070 Ti 时，Windows 触发关闭显示器/DPMS 后，显示器会先黑屏。
- 几秒后 C340 会重新亮起黑色背光，LCD 无法进入真正息屏状态。
- HDMI 连接 C340 时该问题不明显，但 HDMI 下无法完美使用 100Hz，并且会闪屏。
- 单显示器场景也会出现，但曾经可以通过 NVIDIA 控制面板自定义分辨率修复；双屏场景下该方案无效。

## 当前硬件/拓扑

- 主显示器：HKC C340
  - 连接：RTX 3070 Ti DisplayPort
  - 当前模式：3440x1440 @ 100Hz
  - Windows 桌面名：`\\.\DISPLAY1`
- 副显示器：HKC H249W
  - 连接：Intel UHD Graphics 730 HDMI
  - 当前模式：1920x1080 @ 60Hz
  - Windows 桌面名：`\\.\DISPLAY5`
- GPU：
  - NVIDIA GeForce RTX 3070 Ti
  - Intel UHD Graphics 730
  - MuMu Virtual Display Adapter

## 已执行测试

### 1. NVIDIA 驱动版本排除

- 初始 NVIDIA 驱动：610.47
- 更新后 NVIDIA 驱动：610.62
- 结果：610.62 下问题依旧。
- 结论：该问题不是单一 NVIDIA 驱动版本导致。虽然 NVIDIA release notes 提到相关修复，但本机故障路径仍存在。

### 2. Windows 自动息屏/DPMS 测试

- 关闭显示器时间设置为 1 分钟。
- 现象：C340 黑屏数秒后亮起黑色背光。
- 系统日志：复现时没有新增 `nvlddmkm`、Display、DxgKrnl、Kernel-Power 事件。
- 结论：Windows 认为显示器已经关闭，问题更可能在 DP 链路低功耗状态、显示器固件或 EDID/时序握手。

### 3. 强制 DPMS 关屏 35 秒

- 通过 `SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)` 触发关屏。
- 现象：C340 仍然黑屏数秒后亮起黑色背光。
- 系统日志：无新增相关事件。
- 结论：问题不是控制面板 1 分钟息屏逻辑本身，而是 DPMS 关闭路径本身会触发 C340 的异常背光状态。

### 4. 60Hz 降频测试

- 临时将 C340 从 3440x1440 @ 100Hz 切换到 3440x1440 @ 60Hz。
- 再次执行 35 秒 DPMS 关屏测试。
- 现象：60Hz 下仍然黑屏数秒后亮起黑色背光。
- 测试后已恢复 3440x1440 @ 100Hz。
- 结论：问题不只是 100Hz 或高像素时钟导致。单纯降频不能修复。

### 5. DDC/CI 电源命令测试

- 读取 C340 的 VCP `0xD6` 电源模式可用。
- 尝试对 C340 发送 `D6=4`，12 秒后发送 `D6=1` 恢复。
- 命令返回成功，但显示器肉眼观察没有息屏。
- 结论：C340 可能忽略或不完整支持 DDC/CI 电源写入。暂时不能用 DDC/CI 作为可靠绕过方案。

## EDID 观察

C340 当前活动 EDID 为 256 字节，包含 base block + CTA extension。

原始 EDID 已备份：

- `work/C340_active.edid.bin`
- `work/C340_active.edid.hex.txt`
- `work/C340_old.edid.bin`
- `work/H249W_active.edid.bin`

关键详细时序：

- Base DTD：
  - 3440x1440 @ 99.998Hz
  - Pixel clock：533.15 MHz
  - Total：3600x1481
  - Sync：H +48/32，V +3/5
- CTA DTD：
  - 3440x1440 @ 60.016Hz
  - Pixel clock：319.98 MHz
  - Total：3600x1481

初步判断：

- 100Hz 是 C340 EDID 原生广告出来的模式，不是 Windows 临时拼出来的模式。
- C340 的 EDID 范围描述符看起来不够干净，可能会影响 NVIDIA/Windows 对 DP 低功耗状态和时序的处理。
- 但 60Hz 也复现，说明问题可能不是某个刷新率本身，而是 C340 这套 DP EDID/链路省电行为整体有缺陷。

## 当前结论

最可能方向：

1. C340 DisplayPort 固件/Scaler 在 DPMS 后没有真正进入低功耗，反而重新点亮背光。
2. Windows/NVIDIA 正常发送了关屏请求，但 C340 的 DP 链路状态或 EDID 时序导致它停在“有背光、无画面”的状态。
3. 多屏会让这个问题更稳定或更难通过 NVIDIA 控制面板自定义分辨率规避。

已基本排除：

- 单一 NVIDIA 驱动版本问题。
- 100Hz 高刷新率本身。
- Windows 控制面板 1 分钟息屏逻辑。
- DDC/CI 电源控制作为直接替代方案。

### 追加观察：黑背光更像被重新唤醒

用户观察：

- 正常显示器休眠后，移动鼠标需要约 2-3 秒才恢复画面。
- 当前 bug 中，C340 黑屏几秒后亮起黑色背光。
- 进入黑色背光状态后，只要移动鼠标，鼠标指针几乎立刻出现。

新的判断：

- 这更像 Windows/NVIDIA 显示管线在 DPMS 后被重新唤醒，然后输出黑画面。
- 问题不一定只是“C340 背光没关”，也可能是“某个设备/进程/显示拓扑事件把显示器从 off 状态拉回 on 状态”。
- 因此后续需要增加一条排查线：监控 Windows 的 Console Display State，并找出是否有自动唤醒显示器的来源。

## 新线索：NVIDIA 自定义分辨率

用户补充：

- 单屏且未新建 NVIDIA 自定义分辨率时，C340 也会出现黑屏后亮起黑色背光。
- 单屏可以通过 NVIDIA 控制面板自定义分辨率修复。
- 双屏下 NVIDIA 控制面板自定义分辨率方案失效。

系统注册表中发现 NVIDIA `CustomDisplay` 记录：

- 标签：`CUST:3440x1440x100.000Hz`
- 解析出的关键时序：
  - Active：3440x1440
  - H front porch：48
  - H sync width：32
  - H total：3600
  - V front porch：3
  - V sync width：5
  - V total：1481
  - Pixel clock：533.16 MHz
  - Refresh：100.000Hz

这与 C340 原生 EDID 100Hz 详细时序几乎完全相同，但原生 EDID 是：

- Pixel clock：533.15 MHz
- Refresh：99.998Hz

因此当前最强假设变为：

> 单屏 NVIDIA 自定义分辨率之所以有效，是因为它让 C340 收到精确 `100.000Hz / 533.16MHz` 时序；双屏下 NVIDIA 自定义分辨率没有稳定成为实际活动时序，所以 DPMS bug 仍然出现。

已生成候选 EDID override：

- `outputs/C340_candidate_100000Hz.edid.bin`
- `outputs/C340_candidate_100000Hz.edid.hex.txt`
- `outputs/C340_100000Hz_EDID_Override.inf`

候选 EDID 只改两个字节：

- EDID offset 54：`0x43 -> 0x44`，即 base DTD pixel clock `533.15MHz -> 533.16MHz`
- EDID offset 127：`0xAC -> 0xAB`，重新计算 base block checksum

CTA extension 未修改。

参考依据：

- Microsoft 文档说明 Monitor INF 可以通过 `HKR,EDID_OVERRIDE,"0",0x01,...` 形式覆盖指定 EDID block。
- Windows 会把 override 写入监视器设备硬件键，监视器驱动初始化时优先使用 override 数据。

## 候选 override 安装/回滚计划

安装目标：

- 设备硬件 ID：`MONITOR\HKCB34C`
- 文件：`outputs/C340_100000Hz_EDID_Override.inf`

安装前建议：

1. 先在 NVIDIA 控制面板中删除或停用 C340 的 `3440x1440x100.000Hz` 自定义分辨率。
2. 保持 C340 使用 Windows/NVIDIA 默认暴露的 3440x1440 @ 100Hz。
3. 再安装 EDID override。

原因：

- 这次测试的目标是确认“把 NVIDIA 自定义时序提升到 EDID 层”是否能在双屏下修复 DPMS。
- 如果 NVIDIA 自定义分辨率仍存在并被选中，实际活动时序可能仍来自 NVIDIA 自定义模式，测试结论会混淆。
- 自定义模式的关键参数已经从注册表解析并记录，不需要依赖 NVIDIA 控制面板继续保存它。

安装后验证：

1. 设备管理器的 C340 监视器名称应变为 `HKC C340 100.000Hz EDID Override`。
2. C340 应仍可选择 3440x1440 @ 100Hz。
3. 再执行 35 秒 DPMS 关屏测试。

回滚方案：

1. 设备管理器打开“监视器”。
2. 找到 `HKC C340 100.000Hz EDID Override`。
3. 卸载设备，并勾选“删除此设备的驱动程序软件”（如果出现该选项）。
4. 扫描检测硬件改动，或重启。
5. C340 应回到 Microsoft `Generic PnP Monitor` / `monitor.inf`。

注意：

- 当前受限会话不是管理员权限，无法直接安装监视器 INF。
- 如果 Windows 拒绝未签名 Monitor INF，可改用 CRU 导入同一份 `outputs/C340_candidate_100000Hz.edid.bin`，或用 CRU 手动把 base detailed resolution 的 pixel clock 改为 533.16MHz。

实际安装结果：

- 通过设备管理器安装 `outputs/C340_100000Hz_EDID_Override.inf` 时失败。
- Windows 报错：第三方 INF 不包含数字签名信息。
- 结论：Windows 11 当前策略不接受未签名的第三方 Monitor INF，改用 CRU 路线。

CRU 路线：

- 使用 CRU 选择 C340。
- 导入 `outputs/C340_candidate_100000Hz.edid.bin`，或手动编辑 C340 的 3440x1440 @ 100Hz detailed resolution：
  - Pixel clock：533.16 MHz
  - H active：3440
  - H front porch：48
  - H sync width：32
  - H total：3600
  - V active：1440
  - V front porch：3
  - V sync width：5
  - V total：1481
  - Polarity：`+ / +`
- 保存后运行 CRU 自带的 `restart64.exe` 或重启电脑。
- 再执行 DPMS 35 秒测试。

CRU 测试结果：

- CRU 已成功写入 C340 的 `EDID_OVERRIDE`。
- CRU 实际写入的 base detailed timing 已确认：
  - 3440x1440 @ 100.000Hz
  - Pixel clock：533.16MHz
  - Total：3600x1481
- 35 秒 DPMS 测试结果：问题仍复现，C340 黑屏数秒后亮起黑色背光。
- 结论：只把 NVIDIA 自定义分辨率的 100.000Hz 时序提升到 EDID 层，不能修复当前双屏场景。

DisplayConfig 实际活动时序确认：

- C340 当前实际 target timing：
  - active：3440x1440
  - total：3600x1481
  - pixelRate：533160000
  - hSync：148100Hz
  - vSync：100.000Hz
  - outputTechnology：10，即 DisplayPort
- 结论：CRU 后 NVIDIA/Windows 确实在双屏下输出了 `533.16MHz / 100.000Hz` 时序，但问题仍然存在。

## 下一步计划

1. 监控 Windows Console Display State，确认 C340 黑背光出现时系统是否已经从 display off 变回 display on。
2. 检查是否存在自动唤醒显示器的来源：
   - 电源请求
   - HID/键鼠输入噪声
   - 网络/USB 唤醒
   - 虚拟显示适配器
   - 多 GPU/多显示拓扑事件
3. 如果确认是显示状态被自动唤醒，优先查唤醒源，而不是继续只改 EDID。
4. 如果确认系统仍认为 display off，则再考虑更激进的 CRU/EDID 修改：
   - 移除或重写 CTA extension。
   - 改写范围描述符。
   - 让 C340 只暴露一组稳定的 3440x1440 100Hz 模式。
5. 如果 EDID override 仍无效，再考虑系统级绕过：
   - 息屏前临时断开/禁用 C340 显示路径。
   - 息屏前切换显示拓扑。
   - 使用显示器厂商/第三方工具配合热键或计划任务。

## Console Display State 监控

测试时间：2026-07-06 23:56

测试方法：

- 注册 Windows `GUID_CONSOLE_DISPLAY_STATE` 和 `GUID_MONITOR_POWER_ON` 通知。
- 触发 DPMS off。
- 在脚本主动移动鼠标恢复之前，持续监听显示状态。

结果：

- 23:56:22.700：`ConsoleDisplayState=0 Off`
- 23:56:22.701：`MonitorPowerOn=0`
- 23:56:55.141：`ConsoleDisplayState=1 On`
- 23:56:55.142：`MonitorPowerOn=1`
- 23:57:06.535：脚本才执行主动唤醒动作

结论：

- Windows 显示状态确实从 Off 自动变回 On。
- 自动唤醒发生在脚本主动唤醒前约 11 秒。
- 当前问题应优先按“显示器/显示管线被自动唤醒”排查，而不是继续只按“显示器背光无法关闭”处理。

## 输入唤醒监控

测试时间：2026-07-06 23:57

测试方法：

- 在 DPMS off 后每 2 秒记录一次 `GetLastInputInfo`。
- 同时监听 Windows 显示状态。

结果：

- 23:58:00.234：`ConsoleDisplayState=0 Off`，`lastInputTick=2078953`
- 23:58:41.097：仍为 display off，`lastInputTick=2078953`，说明期间无输入。
- 23:58:42.455：`ConsoleDisplayState=1 On`，同时 `lastInputTick=2157328`，最后输入时间已重置。

结论：

- 显示器被重新唤醒时，系统确实收到了输入事件。
- 后续重点改为抓取 Raw Input 来源，识别是哪一个 HID 设备在显示器休眠后自动发送输入。

## Raw Input 监控

测试 1：

- 注册 Raw Input 监听键盘和鼠标。
- 触发 DPMS off。
- 脚本在 55 秒后主动移动鼠标恢复。
- 结果：55 秒内没有抓到 Raw Input，显示状态保持 Off。

测试 2：

- 注册 Raw Input 监听键盘和鼠标。
- 触发 DPMS off。
- 脚本不主动恢复，等待 80 秒。
- 结果：80 秒内没有抓到 Raw Input，显示状态保持 Off。

阶段性结论：

- 当没有输入事件时，Windows display off 状态可以保持。
- 黑色背光更像是在输入/唤醒后出现的“显示管线已唤醒但画面仍黑”的状态。
- 仍需用自然 1 分钟息屏场景复测，因为真实 bug 可能只在 Windows idle timeout 路径下触发，而不是每次强制 DPMS 都触发。

## 自然空闲 + Raw Input 监控

测试方法：

- 不主动发送 DPMS off。
- 等待 Windows 自然空闲息屏。
- 注册 Raw Input 监听键盘/鼠标。

关键结果：

- 显示处于 Off 状态时，捕获到鼠标 Raw Input。
- 输入设备路径：
  - `\\?\HID#VID_046D&PID_C53F&MI_01&Col01#7&16e5d49c&0&0000#{378de44c-56ef-11d1-bc8c-00a0c91405dd}`
- 该设备对应：
  - USB 设备：`LIGHTSPEED Receiver`
  - 鼠标设备：`HID-compliant mouse`
  - 实例：`HID\VID_046D&PID_C53F&MI_01&COL01\7&16E5D49C&0&0000`
- Raw Input 后，Windows 立刻从 `ConsoleDisplayState=0 Off` 切回 `ConsoleDisplayState=1 On`。

结论：

- 当前复现路径中，显示器被 Logitech LIGHTSPEED 鼠标接口唤醒。
- C340 的黑背光状态不是无输入情况下固定出现，而是在显示器 Off 后收到鼠标输入，Windows 重新点亮显示管线后出现。
- 需要继续验证鼠标是否存在传感器漂移/表面反射/震动/接收器异常导致的“无人操作输入”。

用户后续反馈：

- 即使拔掉鼠标，C340 仍然会亮起黑色背光。
- 如果只是鼠标唤醒，预期应直接恢复正常系统画面，而不是停在黑色背光。

修正判断：

- Logitech Raw Input 只能解释某一次测试中的唤醒事件，不足以作为根因。
- 真正需要解释的是“显示状态被唤醒后，C340/DP 链路没有恢复有效画面，只亮黑背光”。
- 排查重心回到 C340 DisplayPort + NVIDIA + 多屏拓扑/时序；输入事件只作为可能触发器之一，而不是最终原因。

下一步验证：

1. 物理关闭 Logitech 鼠标，或把鼠标翻过来让传感器完全不读桌面。
2. 保持键盘/接收器其余设备不动。
3. 等待 Windows 自然 1 分钟息屏。
4. 如果 C340 不再亮黑色背光，则根因基本确认是 Logitech 鼠标输入噪声。
5. 后续修复方向：
   - 清洁鼠标传感器。
   - 更换鼠标垫/表面。
   - 降低 Logitech G HUB 中的回报率。
   - 更新鼠标/接收器固件。
   - 调整接收器位置，避免 USB 干扰。
   - 在不用鼠标时关闭鼠标电源。

## 拔掉 Logitech 接收器后的自然息屏测试

测试时间：2026-07-07 00:19

前置状态：

- Logitech `LIGHTSPEED Receiver` 已物理拔掉。
- 设备管理器/PnP 中 `VID_046D&PID_C53F` 相关设备均为 `Unknown`，即不在线。
- Windows 显示关闭时间为 60 秒。

测试方法：

- 不主动发送 DPMS off。
- 等待 Windows 自然空闲息屏。
- 监听 Raw Input、`ConsoleDisplayState`、`MonitorPowerOn`。

结果：

- 00:20:06.123：`ConsoleDisplayState=0 Off`
- 00:20:06.124：`MonitorPowerOn=0`
- 之后持续采样到 00:22:26，显示状态一直保持 Off。
- 全程没有 Raw Input。
- `lastInputTick` 未变化。

结论：

- 在 Logitech 接收器拔掉、无输入事件的情况下，Windows display off 可以稳定保持至少 140 秒。
- 用户肉眼观察：这轮 C340 仍然亮起黑色背光。
- 因此不能用 Windows `ConsoleDisplayState=0 Off` 直接等同于“显示器真实息屏”。
- 当前证据修正为：Windows 认为显示器保持 Off，但 C340 的硬件背光仍然会亮起。这重新指向 C340/DP 链路低功耗状态，而不是鼠标键盘输入。
- 仍需解释用户反馈中“拔掉鼠标也会亮黑背光”的场景，可能需要区分：
  - 拔掉鼠标本体 vs 拔掉 USB 接收器。
  - 是否还有其它输入设备触发。
  - 是否是用户移动鼠标后即时唤醒时 C340 只恢复背光不恢复画面。

重要修正：

- Logitech Raw Input 只是某次测试中捕获到的额外输入事件。
- 鼠标/键盘不再作为主根因方向。
- 后续主线改为比较“坏状态”和“已知好状态”的真实显示时序/拓扑/注册表差异。

## 坏状态快照

已创建状态采集脚本：

- `work/capture-display-state.ps1`

已采集当前坏状态：

- `work/display-state-snapshots/20260707-002548-bad-dual-cru-override`

当前坏状态特征：

- 双屏扩展。
- C340 走 RTX 3070 Ti DisplayPort。
- H249W 走 Intel UHD Graphics HDMI。
- C340 已应用 CRU EDID override。
- DisplayConfig 显示 C340 实际输出为：
  - 3440x1440 @ 100.000Hz
  - pixelRate：533160000
  - total：3600x1481
- 用户肉眼观察仍然复现黑色背光。

下一步：

- 让用户切换到“单屏 + NVIDIA 自定义分辨率 + 已知不会亮黑色背光”的好状态。
- 再运行同一脚本采集好状态。
- 对比两份快照中的 DisplayConfig、EDID override、NVIDIA CustomDisplay、活动路径数量、adapter/target/source id、输出技术和时序差异。

## 好状态快照：单屏 + NVIDIA 自定义分辨率

用户已切换到已知好状态：

- 单屏，仅 C340 活动。
- C340 走 RTX 3070 Ti DisplayPort。
- NVIDIA 控制面板中已添加并使用自定义分辨率。
- 用户肉眼确认：该状态不会出现黑屏后亮起黑色背光。

已采集快照：

- `work/display-state-snapshots/20260707-003019-good-single-nvidia-custom`
- `work/display-state-snapshots/20260707-003209-good-single-nvidia-custom-confirmed`

### DisplayConfig 对比

坏状态 `20260707-002548-bad-dual-cru-override`：

- 活动路径数：2
- C340：
  - outputTechnology：10，即 DisplayPort
  - active：3440x1440
  - total：3600x1481
  - pixelRate：533160000
  - hSync：148100Hz
  - vSync：100.000Hz
- H249W：
  - outputTechnology：5，即 HDMI
  - active：1920x1080
  - vSync：60.000Hz

好状态 `20260707-003209-good-single-nvidia-custom-confirmed`：

- 活动路径数：1
- C340：
  - outputTechnology：10，即 DisplayPort
  - active：3440x1440
  - total：3600x1481
  - pixelRate：533160000
  - hSync：148100Hz
  - vSync：100.000Hz

结论：

- C340 的实际 DisplayConfig target timing 在好状态和坏状态中完全一致。
- 因此，问题不能再解释为“坏状态没有真正输出 100.000Hz / 533.16MHz”。
- 关键差异转向：
  - 活动显示路径数量：单屏 vs 双屏。
  - NVIDIA 驱动内部是否存在/使用 `CustomDisplay` 自定义模式记录。

### EDID/CRU 对比

好状态和坏状态中，C340 当前活动 EDID 均显示 base detailed timing 已是：

- Pixel clock：533.16MHz
- EDID base DTD bytes offset 54-55：`44 d0`

好状态和坏状态中，C340 的 `EDID_OVERRIDE_0` hash 相同：

- `aaeae13750bc42febd85d583c92e9830fd8d9f89d1b0d40960c012accdcb4d0e`

结论：

- CRU/EDID base block override 本身不是好坏状态的决定性差异。
- 即使 C340 EDID 层已经暴露 533.16MHz / 100.000Hz，双屏坏状态仍可复现。

### NVIDIA CustomDisplay 对比

坏状态 `20260707-002548-bad-dual-cru-override`：

- `CustomDisplay.bin` hash：
  - `84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652`
- 文件内容全 0。
- 不存在 ASCII 字符串 `CUST:3440x1440x100.000Hz`。

好状态 `20260707-003209-good-single-nvidia-custom-confirmed`：

- `CustomDisplay.bin` hash：
  - `ee448a68b6e97b0f1ca36470531580cba79b80e5fbd7cf9a6b3639cd40cf9113`
- 存在两处 ASCII 字符串：
  - `CUST:3440x1440x100.000Hz`
- 二进制中可见对应时序字段：
  - 3440 / 1440
  - H front porch 48
  - H sync width 32
  - H total 3600
  - V front porch 3
  - V sync width 5
  - V total 1481
  - Pixel clock 53316，即 533.16MHz
  - Refresh 100000，即 100.000Hz

当前最重要结论：

- 好状态不是单纯因为 DisplayConfig 输出了 `533.16MHz / 100.000Hz`。
- 好状态同时具备 NVIDIA 驱动内部的 `CustomDisplay` 自定义模式记录。
- 坏状态虽然通过 CRU 让 DisplayConfig 输出同样时序，但 NVIDIA `CustomDisplay` 记录为空。
- 因此更强的新假设是：

> NVIDIA 控制面板自定义分辨率触发了驱动内部另一条模式/链路训练/DPMS 处理路径；这条路径在单屏下能让 C340 真正息屏。CRU 只改 EDID 数字，不能触发同一条 NVIDIA 内部路径。

下一步建议测试：

1. 切回双屏扩展，但不要删除 NVIDIA 自定义分辨率。
2. 确认 C340 仍选择 NVIDIA 控制面板里的 `3440x1440 @ 100.000Hz` 自定义分辨率，而不是只依赖 CRU 暴露的普通 100Hz。
3. 再采集一份“dual + NVIDIA custom active”快照。
4. 复测 DPMS。
5. 如果双屏下 `CustomDisplay` 记录存在但仍复现，说明根因主要是多活动显示路径/多 GPU 拓扑；如果双屏下 `CustomDisplay` 记录丢失或没有被选中，则修复方向是让双屏时 C340 也强制走 NVIDIA 自定义模式。

## 双屏 + NVIDIA 自定义分辨率保留快照

用户当前状态：

- 已重新插上副屏，处于双屏扩展。
- C340 仍走 RTX 3070 Ti DisplayPort。
- H249W 走 Intel UHD Graphics HDMI。
- NVIDIA 自定义分辨率未删除，仍保留。
- 用户确认：该双屏状态下息屏仍会亮起黑色背光。

已采集快照：

- `work/display-state-snapshots/20260707-003949-dual-nvidia-custom-retained`

### DisplayConfig

当前双屏状态：

- 活动路径数：2
- C340：
  - outputTechnology：10，即 DisplayPort
  - active：3440x1440
  - total：3600x1481
  - pixelRate：533160000
  - hSync：148100Hz
  - vSync：100.000Hz
- H249W：
  - outputTechnology：5，即 HDMI
  - active：1920x1080
  - vSync：60.000Hz

结论：

- C340 当前实际输出时序仍与单屏好状态完全一致。

### NVIDIA CustomDisplay

当前双屏状态中，`CustomDisplay.bin` hash 为：

- `ee448a68b6e97b0f1ca36470531580cba79b80e5fbd7cf9a6b3639cd40cf9113`

该 hash 与单屏好状态 `20260707-003209-good-single-nvidia-custom-confirmed` 完全一致。

当前双屏状态中也存在：

- `CUST:3440x1440x100.000Hz`

结论修正：

- “双屏坏状态”并不是因为 NVIDIA 自定义分辨率记录丢失。
- 在当前双屏状态里，NVIDIA `CustomDisplay` 记录存在，并且内容与单屏好状态相同。
- 因此，当前证据更强地指向：

> C340 的 DPMS 黑背光问题由第二条活动显示路径/多显示拓扑触发；即使 C340 本身走同一套 NVIDIA 自定义 100.000Hz 时序，双屏活动状态仍会让 C340 在 DPMS 后进入异常黑背光。

下一步最有区分度的测试：

1. 保持副屏线缆物理连接不变。
2. 在 Windows 中临时切换为“仅 C340/仅主屏显示”，让第二条显示路径 inactive。
3. 复测 DPMS。
4. 如果此时 C340 不再亮黑色背光，说明触发条件是“第二条活动显示路径”，不是副屏线缆存在本身。
5. 如果此时仍然亮黑色背光，说明只要副屏被系统枚举/热插拔存在，就可能影响 C340 的 DPMS。

## 副屏物理连接但仅主屏活动测试

测试目的：

- 区分“副屏物理存在/被枚举”与“第二条显示路径处于 active”哪个才是触发条件。

测试步骤：

1. 保持副屏线缆物理连接不变。
2. 使用 `DisplaySwitch.exe /internal` 临时切到仅主屏。
3. 采集快照。
4. 强制 DPMS off 45 秒。
5. 自动唤醒后使用 `DisplaySwitch.exe /extend` 恢复双屏扩展。

测试期间快照：

- `work/display-state-snapshots/20260707-004126-primary-only-secondary-plugged`

测试后恢复快照：

- `work/display-state-snapshots/20260707-004224-after-primary-only-test-restored-extend`

### 测试期间 DisplayConfig

`20260707-004126-primary-only-secondary-plugged`：

- 活动路径数：1
- 只有 C340 活动。
- C340：
  - outputTechnology：10，即 DisplayPort
  - active：3440x1440
  - total：3600x1481
  - pixelRate：533160000
  - hSync：148100Hz
  - vSync：100.000Hz

`CustomDisplay`：

- `CUST:3440x1440x100.000Hz` 仍存在。

结论：

- 测试期间 Windows 拓扑确实切到了“只有 C340 一条活动路径”。
- 副屏线缆仍物理连接，但 H249W 不再是 active display path。
- 用户肉眼反馈：这 45 秒内 C340 仍然亮起黑色背光。

结论修正：

- 触发条件不是单纯的“第二条显示路径 active”。
- 即使 Windows 桌面拓扑只剩 C340 一条活动路径，只要副屏仍物理连接/被系统枚举，C340 的 DPMS 仍会进入黑色背光异常。
- 这把问题范围进一步缩小为：
  - 副屏的物理热插拔/HPD/EDID 枚举状态影响了 NVIDIA/C340 的 DPMS。
  - 或者 Windows/NVIDIA/Intel 多适配器环境中，即便副屏 inactive，显示栈仍保留了副屏 target，导致 C340 DP 链路低功耗失败。

下一步：

- 查询 DisplayConfig 的 all paths/available targets，而不只看 active paths，确认“仅主屏”时 H249W 是否仍作为 inactive target 保留。
- 如果 H249W 仍被保留，则后续修复方向应从“切换显示拓扑”升级为“息屏前禁用/断开副屏 target 或显示设备枚举”。

### All paths 复查

已修改采集脚本：

- `work/capture-display-state.ps1`
- 新增输出：`displayconfig-all.txt`

采集步骤：

1. `DisplaySwitch.exe /internal` 切到仅主屏。
2. 采集 all paths 快照。
3. `DisplaySwitch.exe /extend` 恢复扩展。

快照：

- 仅主屏但副屏连接：`work/display-state-snapshots/20260707-004422-primary-only-secondary-plugged-allpaths`
- 恢复扩展后：`work/display-state-snapshots/20260707-004430-extend-after-allpaths-capture`

结果：

- `displayconfig.txt`：只有 1 条 active path，即 C340。
- `displayconfig-all.txt`：仍保留大量 inactive paths。
- H249W 对应 targetId `20530`，在 all paths 中仍出现。
- `wmi-monitor-connections.json` 中，H249W 仍显示：
  - `InstanceName`: `DISPLAY\HKCB241\4&24219e88&0&UID20530_0`
  - `Active`: `true`
  - `VideoOutputTechnology`: `5`
- `Get-PnpDevice -Class Monitor` 中，H249W 仍为：
  - `Status`: `OK`
  - `InstanceId`: `DISPLAY\HKCB241\4&24219E88&0&UID20530`

结论：

- `DisplaySwitch.exe /internal` 只移除了 H249W 的桌面 active path。
- 它没有让 H249W 从 Windows 显示栈/PnP/WMI 中真正消失。
- 这解释了为什么“仅主屏但副屏仍插着”仍会触发 C340 黑背光。
- 当前根因范围进一步收敛为：

> C340 DPMS 异常不是由第二个桌面扩展画面本身触发，而是由第二个物理连接/枚举中的显示 target 存在触发。

权限观察：

- 当前受限会话为 medium integrity。
- `BUILTIN\Administrators` 显示为 deny only。
- 因此当前会话不能直接执行需要管理员权限的 PnP disable/enable 修复测试。

## 候选修复验证：临时禁用 H249W PnP 监视器设备

由于 `DisplaySwitch.exe /internal` 不能让 H249W 从 WMI/PnP 中真正消失，下一步验证升级为：

1. 以管理员权限临时禁用 H249W 的 Monitor PnP 设备。
2. 等待 Windows 显示栈刷新。
3. 对 C340 触发 DPMS off。
4. 观察 C340 是否仍亮黑色背光。
5. 自动唤醒并重新启用 H249W。

已创建测试脚本：

- `work/test-disable-h249w-dpms.ps1`
- `work/reenable-h249w-monitor.ps1`

脚本特性：

- 需要管理员权限。
- 目标设备为 FriendlyName 包含 `H249W` 的 Monitor PnP 设备。
- 使用 `try/finally`，测试结束后自动重新启用 H249W。
- 生成日志：`work/pnp-disable-h249w-dpms-*.log`
- 已通过 PowerShell parser 语法检查。

如果该测试中 C340 不再亮黑色背光：

- 说明可行修复路线是“息屏前临时禁用副屏 PnP/target，唤醒后恢复”。
- 后续可以做成一个更完整的管理员计划任务/托盘脚本。

如果该测试中 C340 仍然亮黑色背光：

- 说明即使禁用监视器 PnP 设备也不足以消除 HDMI/HPD/显示栈影响。
- 后续只能进一步测试：
  - 关闭副屏电源但不拔线。
  - 拔掉副屏 HDMI/DP 线。
  - 禁用副屏所在显示适配器。
  - 从硬件层面使用可控 HDMI/DP 开关或电源控制。

### H249W PnP 禁用测试结果

测试日志：

- `work/pnp-disable-h249w-dpms-20260707-005239.log`

脚本执行记录确认：

- `00:52:39` 开始禁用 H249W。
- 禁用后 H249W 的 PnP 状态由 `OK` 变为 `Error`。
- `00:52:47` 对显示器强制执行 DPMS off，持续 45 秒。
- `00:53:36` 重新启用 H249W。
- 用户观察：C340 仍然在黑屏数秒后亮起黑色背光。

结论：

- 本次结果不是 `Disable-PnpDevice` 未执行造成的；监视器 PnP 节点确实已被禁用。
- 只禁用 H249W 的 Monitor 类 PnP 节点，不会撤销 Intel 显示适配器所维护的物理 HDMI target/HPD 状态。
- 因而“息屏前禁用副屏 Monitor 节点”不能作为修复方案。
- 下一项软件对照测试升级为临时禁用 H249W 所在的 `Intel(R) UHD Graphics 730` 显示适配器。如果这样仍然复现，软件枚举层面的绕过方向基本可以排除，下一步应直接比较“副屏断电但线保留”和“副屏信号线物理拔除”。

新增脚本：

- `work/test-disable-intel-adapter-dpms.ps1`
- `work/reenable-intel-adapter.ps1`

### Intel 显示适配器禁用测试结果

测试日志：

- `work/pnp-disable-intel-adapter-dpms-20260707-005513.log`

脚本执行记录确认：

- 精确命中 `Intel(R) UHD Graphics 730`，没有操作 RTX 3070 Ti。
- 禁用后 Intel 适配器状态由 `OK` 变为 `Error`，H249W 由 `OK` 变为 `Unknown`。
- 随后对 C340 执行了 45 秒 DPMS off。
- 用户观察：C340 仍然在黑屏数秒后亮起黑色背光。
- 脚本结束后 Intel 适配器和 H249W 均已恢复为 `OK`。

结论修正：

- Intel 核显驱动不是必要触发条件；禁用整个 Intel 显示适配器仍不能修复 C340。
- 用户此前也验证过两块物理显示器同时连接 NVIDIA 时同样复现。
- 因此当前最强假设是 NVIDIA Windows 驱动在“系统曾/仍存在多个显示目标”时，对 C340 的 DisplayPort DPMS 采用了错误的链路电源转换：先熄灭，数秒后又输出黑色有效视频或把 DP sink 拉回工作态。
- “黑背光后鼠标立即出现”与该假设相符：当时面板已经重新收到有效 DP 链路，并非仍处于真正的低功耗待机。

额外观察：

- 禁用 Intel 后，`DISPLAY\\HKCB34C\\1&8713BCA&0&UID0` 从 `Unknown` 变为 `OK`；其父设备为 `ROOT\\BasicDisplay\\0000`（Microsoft 基本显示驱动程序），并非 NVIDIA 或 MuMu。
- 这意味着热禁用适配器时 Windows 仍可能建立临时 BasicDisplay 设备，后续拓扑采集需要记录实际 active paths，不能只依据 PnP 的 `OK/Unknown`。
- 正常单屏和异常双屏快照中的 NVIDIA `nvidia-smi` 状态均为 `P8`，因此问题不是多屏令 GPU 进入不同 P-State 所致。

后续方向：

1. 抓取 DPMS 前、黑背光出现后 NVIDIA/Windows 显示事件与 active topology，确认是否发生额外 mode-set 或 target power-on。
2. NVIDIA 官方公开 NVAPI 提供显示/EDID 接口，但当前公开头文件未暴露 DP AUX/DPCD 原始读取接口，暂不使用不受支持的私有调用直接操作 DP 寄存器。
3. 探测 C340 的 DDC/CI VCP `0xD6`（电源模式）能力。如果支持，可把它作为不依赖 NVIDIA DPMS 的候选软件修复路径。

新增只读探测脚本：

- `work/query-monitor-ddcci.ps1`

### DDC/CI 能力探测结果

桌面映射：

- `\\.\\DISPLAY30`：3440×1440，主屏，即 C340。
- `\\.\\DISPLAY39`：1920×1080，副屏，即 H249W。

读取 VCP `0xD6` 的结果：

- C340：`current=0x01, maximum=0x04`。
- H249W：`current=0x01, maximum=0x05`，能力字符串明确列出 `D6(01 04 05)`。
- C340 能力字符串读取发生 I2C 错误，但单独读取 `0xD6` 成功，因此可以进行受控写入试验。

候选绕过原理：

- `0xD6=0x01` 表示显示器电源开启。
- `0xD6=0x04` 表示 DPMS/MCCS 电源关闭模式。
- Windows 官方 `SetVCPFeature` API 可以通过 DDC/CI 写入该 VCP 值。
- 如果 C340 在 `0x04` 下能够抵抗 NVIDIA 数秒后的异常 DP 链路恢复并保持背光关闭，就可以开发常驻修复程序：监听 Windows `GUID_CONSOLE_DISPLAY_STATE`，息屏时写 `0x04`，用户唤醒时写回 `0x01`。

新增受控测试脚本：

- `work/test-c340-ddcci-dpms.ps1`
- 默认关闭 35 秒，并在 `finally` 中尝试恢复 `0x01` 和模拟鼠标移动。

### C340 DDC/CI 电源写入测试结果

运行时间：`01:03:17`

执行结果：

- 成功定位 C340：`\\.\\DISPLAY30`。
- 成功读取 VCP `0xD6`：`current=0x01, maximum=0x04`。
- 写入 `0xD6=0x04` 失败，Windows 返回“将数据传输到 I2C 总线上的设备时出错”。
- 写入失败发生在 Windows DPMS off 之前，因此本次没有进入 35 秒观察阶段。
- 脚本 `finally` 已执行；由于关闭命令没有成功确认，未写入其他显示器设置。

初步解释：

- C340 能读取 DDC/CI 电源值，但不一定接受写入。
- 也可能是当前 NVIDIA DisplayPort AUX/I2C 路径允许读取但写入失败。
- 已查阅 C340 用户手册列出的 OSD 菜单，未发现 DDC/CI 启用/禁用选项，暂时不能通过显示器菜单开启写入。
- 下一步使用标准亮度 VCP `0x10` 做“读取当前值并原值写回”的无视觉变化探针，以区分“仅 D6 不可写”和“整个 DDC/CI 写通道不可用”。

亮度安全探针结果：

- C340 的 VCP `0x10` 读取同样返回 I2C 传输错误，因此没有执行原值写回。
- C340 的 capabilities 字符串读取也返回同一 I2C 错误。
- 作为对照，H249W 的 `0x10` 可正常读取为 `current=90, maximum=100`，完整 capabilities 也能读取。

结论：

- DDC/CI API 与 Windows 枚举代码本身正常，故障只发生在 C340 的 DP DDC/CI 通道。
- C340 的 `D6` 单次读取不能证明其支持可靠写入，现已实测电源写入失败。
- DDC/CI 强制关屏不能作为当前连接方式下的修复方案，停止继续写入，避免不可预测的显示器固件行为。

## GPU/Power ETW 取证

目的：

- 记录 DPMS 后先真正熄屏、数秒后亮起黑色背光的时间窗口。
- 检查 `Microsoft-Windows-DxgKrnl` 与电源事件中是否出现第二次 mode-set、present/display engine 恢复或目标电源转换。
- 生成可用于后续分析或提交 NVIDIA 的原始 `.etl` 证据。

环境确认：

- Windows 内置 WPR 提供 `GPU` 和 `Power` profile。
- `Microsoft-Windows-DxgKrnl`、`Microsoft-Windows-Display`、`Microsoft-Windows-Kernel-Power` provider 均存在。
- 未发现独立公开的 NVIDIA ETW provider。
- 本机没有 WPA/WPAExporter，但有系统自带 `tracerpt.exe`，可将 ETL 转换后筛选事件。

新增脚本：

- `work/capture-dpms-etw.ps1`
- 默认记录 DPMS off 45 秒，并在 2、8、15、30、40 秒和唤醒后写入墙钟时间标记。
- 输出目录：`work/dpms-etw/<timestamp>/`。

### 首次 ETW 测试结果与调整

首次测试：

- 输出目录：`work/dpms-etw/20260707-010802/`。
- DPMS off 观察窗口：18 秒。
- 用户观察：18 秒内没有看到黑色背光重新亮起。
- 结论：该窗口短于本机故障可能出现的延迟，只能记为“短窗口未复现”，不能作为故障消失或修复的证据。
- WPR 的完整 GPU+Power profile 在该短窗口内生成约 700 MB ETL，包含大量与显示电源问题无关的逐帧/系统活动。

脚本调整：

- 观察窗口延长至 45 秒。
- 改用轻量 `logman` ETW 会话，只抓取 DxgKrnl 显示状态/电源/驱动、Kernel-Power、Display 与 UserModePowerService。
- 不启用高流量 Present 关键字。
- ETL 使用 256 MB 环形上限，避免长测试产生数 GB 文件。

轻量脚本首次启动失败：

- 时间：`01:11:24`。
- `logman` 返回 `-2147024809`（`0x80070057`，参数无效）。
- `logman-start.txt` 明确显示“参数 p 定义的次数过多”。
- 原因：当前 Windows 版本的 `logman` 只允许一个 `-p`；多个 provider 必须通过 `-pf` 文件提供。
- 修复：新增 `work/dpms-etw-providers.txt`，每行一个 provider；脚本改用单个 `-pf` 参数。
- 该次失败没有启动 ETW 会话，也没有触发 DPMS。
- 修复后已在非管理员会话执行短启动自检：参数解析成功，返回预期的 `Access is denied`，而非参数错误；测试会话未启动且无残留。这确认管理员会话可继续正式测试。

### 45 秒有效复现 ETW 分析

输出目录：

- `work/dpms-etw/20260707-011255/`

跟踪质量：

- DPMS off：`01:12:58.199`。
- 自动唤醒：`01:13:43.543`。
- ETL 大小约 51 MB。
- 共处理 386,249 条事件，丢失 0 条。
- 用户观察：45 秒内 C340 再次亮起黑色背光。

关键事件序列：

1. DPMS 后，DxgKrnl 对 AdapterHandle `0xFFFFE78C07F69000` 不断记录 D3 与 D0 请求：
   - `SuspendRequestSent`
   - `IrpRequestSentD3`
   - `IrpRequestSentD0`
2. `01:13:22.814`（DPMS 后约 24.6 秒），Kernel-Power 记录 C340：
   - 设备：`DISPLAY\\HKCB34C\\5&239bc59c&0&UID4357`
   - `DevicePreparation`
   - `Prepared=false`
3. 随后 DxgKrnl 明确记录四次 `DevicePoweredOn`：
   - `01:13:25.888`（DPMS 后约 27.7 秒）
   - `01:13:26.419`（约 28.2 秒）
   - `01:13:26.939`（约 28.7 秒）
   - `01:13:30.047`（约 31.8 秒）
4. 这些 `DevicePoweredOn` 全部发生在脚本的自动鼠标唤醒 `01:13:43.543` 之前，因此不是鼠标、键盘或人为输入造成的正常唤醒。
5. 第一次 18 秒 ETW 测试没有看到黑背光，是因为该次故障的关键 C340/DevicePoweredOn 序列直到约 24–32 秒才出现。

设备归属：

- C340 PnP 实例的父/总线关系明确属于 `NVIDIA GeForce RTX 3070 Ti`：
  - GPU：`PCI\\VEN_10DE&DEV_2482...`
  - BusRelations：`DISPLAY\\HKCB34C\\5&239bc59c&0&UID4357`
- 因此 C340 的这段设备准备与 D3/D0/DevicePoweredOn 序列属于 NVIDIA 所承载的显示链路，而不是 Intel 上的 H249W。

当前根因结论：

> Windows 发出 DPMS off 后，NVIDIA 所承载的 C340 链路并没有稳定保持低功耗状态。显示适配器/链路在 D3 与 D0 之间反复转换，并在系统仍处于显示关闭窗口时触发 `DevicePoweredOn`，使 C340 收到有效但全黑的 DP 输出并重新打开 LCD 背光。

该结论同时解释：

- 为什么黑背光状态下鼠标一动就能立即显示指针：链路/面板已经被驱动提前拉回工作态。
- 为什么拔鼠标键盘无效：异常 D0/DevicePoweredOn 发生在无用户输入的 ETW 测试中。
- 为什么 HDMI 或单屏 NVIDIA 自定义分辨率可能规避：它们改变了 NVIDIA 的链路模式/电源状态机路径，但双屏拓扑仍会进入异常转换。

### 候选修复测试：关闭 PCIe ASPM

当前电源方案：

- `平衡`。
- 交流电源 PCIe 链接状态电源管理：`中等电源节省量`（索引 1）。

测试目的：

- 临时关闭 PCIe Link State Power Management，观察是否能阻止 NVIDIA/C340 链路的 D3/D0 循环与 `DevicePoweredOn`。
- 测试结束后自动恢复原始 AC/DC 设置。

新增脚本：

- `work/test-aspm-off-dpms.ps1`

### ASPM 测试脚本解析修复

时间：2026-07-07

现象：
- 运行 `work/test-aspm-off-dpms.ps1` 时，在读取当前 PCIe ASPM 电源设置阶段报错：`Cannot parse the current PCIe ASPM power settings.`

原因：
- 脚本原先用中文文本匹配 `powercfg /QUERY` 输出里的“当前交流/直流电源设置索引”。
- `.ps1` 在 Windows PowerShell 中按本地 ANSI 读取时，UTF-8 中文匹配字符串会变成乱码，导致正则匹配失败。

修复：
- `work/test-aspm-off-dpms.ps1` 已改为直接解析输出中的两个 `0x...` 数值。
- 当前验证结果：AC=1，DC=2；PowerShell 语法检查通过。
- 脚本仍保持原逻辑：临时把 PCIe Link State Power Management 设为 Off，运行 45 秒 DPMS/ETW 测试，最后自动恢复原 AC/DC 设置。

### PCIe ASPM 关闭测试结果

时间：2026-07-07 01:45

测试日志：
- `work/aspm-off-dpms-20260707-014546.log`
- `work/dpms-etw/20260707-014551/`

执行确认：
- 原始 PCIe ASPM：AC=1，DC=2。
- 测试期间 PCIe ASPM 已临时设为：AC=0，DC=0。
- 测试结束后已自动恢复：AC=1，DC=2。

用户观察：
- C340 仍然亮起黑色背光。
- 新增关键现象：亮起黑色背光之前，C340 会先显示“无信号”提示。

ETW 复查：
- `DevicePoweredOn` 仍在 ASPM 关闭后出现：
  - `01:46:07.020`，DPMS off 后约 13.6 秒。
  - `01:46:17.952`，DPMS off 后约 24.5 秒。
  - `01:46:18.472`，DPMS off 后约 25.0 秒。
  - `01:46:20.551`，DPMS off 后约 27.1 秒。
- C340 相关 Kernel-Power `DevicePreparation Prepared=false` 仍出现于 `01:46:18.270`。
- DxgKrnl 的 D3/D0 runtime power 循环仍大量存在。

结论修正：
- 关闭 Windows 电源计划里的 PCIe Link State Power Management 不能修复该问题。
- 这说明故障不主要由主板/PCIe ASPM 省电策略触发，而更像 NVIDIA 显示目标/DisplayPort 链路自身的 runtime power 转换。
- “无信号”提示说明 C340 在 DPMS 后确实经历了信号断流；随后 NVIDIA/显示器又把 DP 链路拉回到有同步但黑画面的状态，因此 LCD 背光重新亮起。

下一步候选：
- 先测试“DPMS re-off watchdog”：在显示器应关闭期间，每隔数秒重新发送一次 DPMS off，验证软件层是否能把被拉回来的 DP 链路重新压回无信号/息屏状态。
- 新增脚本：`work/test-dpms-reoff-watchdog.ps1`

### DPMS re-off watchdog 测试结果

时间：2026-07-07 01:55

测试日志：
- `work/dpms-reoff-watchdog-20260707-015507.log`

执行确认：
- 初始发送 DPMS off：`01:55:07`。
- 之后每 6 秒重新发送一次 DPMS off，持续到 84 秒。
- `01:56:37` 自动唤醒。

用户观察：
- 问题依旧，C340 仍会亮起黑色背光，情况无变化。

结论：
- 单纯在 display-off 窗口中重复发送 `SC_MONITORPOWER / DPMS off`，不能把 C340 重新压回真正息屏。
- 这支持一个判断：Windows 侧可能仍认为显示器处于 off，重复 DPMS off 只是无效的重复命令；实际异常发生在 NVIDIA/DisplayPort 链路或 C340 sink 的电源/链路状态。

### 候选修复测试：NVIDIA 时钟锁定

目的：
- 当前异常始终伴随 DxgKrnl runtime power D3/D0 循环与 `DevicePoweredOn`。
- 下一步用 `nvidia-smi` 短时锁定 GPU/显存时钟，观察避免 P8/低频状态后，C340 是否仍会在 DPMS 后“无信号 -> 黑背光”。
- 如果该测试有效，后续再寻找更温和的长期方案，例如 NVIDIA 控制面板“电源管理模式：最高性能优先”或特定 profile。

当前空闲状态：
- P-state：`P8`
- GPU clock：`210MHz`
- Memory clock：`405MHz`
- Video clock：`555MHz`

已确认支持的测试锁定值：
- Memory：`9501MHz`
- GPU：`1200MHz`

新增脚本：
- `work/test-nvidia-clock-lock-dpms.ps1`

脚本特性：
- 需要管理员 PowerShell。
- 测试前执行 `nvidia-smi -lgc 1200,1200` 与 `nvidia-smi -lmc 9501,9501`。
- 锁定后运行 45 秒 DPMS/ETW 跟踪。
- `finally` 中自动执行 `nvidia-smi -rgc` 和 `nvidia-smi -rmc` 恢复默认时钟。

### NVIDIA 时钟锁定脚本首次运行修复

时间：2026-07-07 02:00

日志：
- `work/nvidia-clock-lock-dpms-20260707-020013.log`

现象：
- 脚本报错：`Neither GPU clock lock nor memory clock lock succeeded. Test is not meaningful.`

复查日志：
- `nvidia-smi -lgc 1200,1200` 实际成功：`GPU clocks set to "(gpuClkMin 1200, gpuClkMax 1200)"`。
- `nvidia-smi -lmc 9501,9501` 实际成功：`Memory clocks set to "(memClkMin 9501, memClkMax 9501)"`。
- 脚本随后进入 `finally` 并成功执行 `-rgc`、`-rmc`，没有残留锁频。

原因：
- PowerShell 函数 `Log()` 使用 `Tee-Object` 时会把日志文本也写入函数返回流，导致 `Run-NvidiaSmi` 的返回值不再是纯退出码 `0`，脚本误判锁频失败。

修复：
- `work/test-nvidia-clock-lock-dpms.ps1` 已修复：
  - `Log()` 末尾加入 `Out-Null`，避免污染返回值。
  - `Run-NvidiaSmi` 参数显式声明为 `[string[]]`。
- 语法检查通过。
- 当前 GPU 已回到默认空闲状态：`P8, 210, 405, 555`。

### NVIDIA 时钟锁定测试结果

时间：2026-07-07 02:01

日志：
- `work/nvidia-clock-lock-dpms-20260707-020135.log`
- `work/dpms-etw/20260707-020138/`

执行确认：
- 锁定前：`P8, 210, 405, 555, 9.43W`。
- 执行 `nvidia-smi -lgc 1200,1200` 成功。
- 执行 `nvidia-smi -lmc 9501,9501` 成功。
- 锁定后：`P0, 1200, 9501, 1305, 58.84W`。
- 测试结束后自动执行 `-rgc`、`-rmc`，当前 GPU 已回到默认空闲状态。

用户观察：
- C340 依然会出现“无信号 -> 黑色背光”。

ETW 复查：
- DPMS off：`02:01:40.609`。
- `DevicePoweredOn` 仍出现：
  - `02:02:06.865`，DPMS off 后约 26.3 秒。
  - `02:02:07.383`，DPMS off 后约 26.8 秒。
  - `02:02:15.727`，DPMS off 后约 35.1 秒。
- C340 相关 Kernel-Power `DevicePreparation Prepared=false` 仍出现于 `02:02:05.205`，DPMS off 后约 24.6 秒。

结论：
- 锁定 GPU/显存时钟到高性能状态不能修复该问题。
- 因此问题基本不是由 GPU 处于 `P8`、核心/显存低频、或普通性能省电策略导致。
- 更强的判断是：异常发生在 NVIDIA 对 C340 这个 DisplayPort 显示目标/sink 的 runtime power 或链路重训练状态机中。

### 候选 workaround 测试：临时禁用 C340 Monitor target

目的：
- 既然 C340 的异常路径是 DPMS 后先“无信号”，随后又被 NVIDIA/DP 链路拉回“有同步黑画面”，下一步测试不再发送 DPMS，而是让 Windows/NVIDIA 临时移除 C340 这个 Monitor PnP 目标。
- 如果 C340 在 target 被禁用后能保持真正无信号休眠，则后续可开发为“息屏时禁用 C340 target，唤醒时恢复”的软件 workaround。
- 如果 target 禁用后仍然出现黑色背光，则说明仅移除 Monitor PnP 节点也不足以让 C340 DP 真正休眠。

当前安全前提：
- WMI 确认当前有两个 active monitor：
  - C340：`DISPLAY\HKCB34C\5&239bc59c&0&UID4357_0`，DisplayPort。
  - H249W：`DISPLAY\HKCB241\4&24219e88&0&UID20530_0`，HDMI。
- 因此可临时禁用 C340，仍保留 H249W 作为可见桌面与恢复路径。

新增脚本：
- `work/test-disable-c340-monitor-target.ps1`

脚本特性：
- 需要管理员 PowerShell。
- 如果没有检测到除 C340 之外的 active monitor，会拒绝执行。
- 只禁用 active 的 C340 Monitor PnP 节点：`DISPLAY\HKCB34C\5&239BC59C&0&UID4357`。
- 默认观察 75 秒。
- `finally` 中自动重新启用 C340。

### C340 target 禁用脚本首次运行观察

时间：2026-07-07 02:06 / 02:08

日志：
- `work/disable-c340-monitor-target-20260707-020644.log`
- `work/disable-c340-monitor-target-20260707-020810.log`

结果：
- `02:06:44` 这次运行成功禁用了 C340 Monitor PnP 节点。
- 禁用后状态：
  - C340 PnP：`Error`
  - H249W PnP：`OK`
  - WMI active monitor 只剩 H249W：`DISPLAY\HKCB241\4&24219e88&0&UID20530_0`
- 脚本观察了完整 75 秒，并在 `02:08:05` 开始重新启用 C340。
- 当前复查：C340 已恢复 `OK`，H249W 也为 `OK`，没有残留禁用状态。

用户反馈：
- PowerShell 看起来一直卡着、没有进度。

原因：
- 这是脚本显示问题：`Log()` 原本只写日志文件，没有实时输出到控制台。
- 禁用后的 75 秒观察窗口也没有控制台进度，因此看起来像卡住。

修复：
- `work/test-disable-c340-monitor-target.ps1` 已改为同时输出到控制台和日志文件。
- 之后会显示每一步，以及 `Observation marker +15s / +30s / ...` 进度。
- `work/reenable-c340-monitor-target.ps1` 也补充了恢复后的状态提示。

### C340 target 禁用测试结果

时间：2026-07-07 02:11

日志：
- `work/disable-c340-monitor-target-20260707-021145.log`

执行确认：
- 禁用前：
  - C340 PnP：`OK`
  - H249W PnP：`OK`
  - WMI active monitor：C340 + H249W
- 禁用后：
  - C340 PnP：`Error`
  - H249W PnP：`OK`
  - WMI active monitor：只剩 H249W
- 脚本完整观察 75 秒后重新启用 C340。
- 重新启用后 C340/H249W 均恢复 `OK`。

用户观察：
- 全程 C340 都没有息屏。

结论：
- 只禁用 C340 的 Monitor PnP 节点，能够让 Windows/WMI 不再把它列为 active monitor，但不能让物理 C340 进入真正息屏。
- 因此“息屏时禁用 C340 Monitor target，唤醒时恢复”不能作为有效 workaround。
- 这进一步说明问题发生在 NVIDIA display adapter / DP 端口 / sink 链路层，而不是 Monitor PnP 节点层。

下一步候选：
- 更强一层的验证是临时禁用承载 C340 的 `NVIDIA GeForce RTX 3070 Ti` 显示适配器，保留 H249W 所在的 Intel UHD 730 作为可见桌面。
- 如果禁用整个 NVIDIA adapter 后 C340 才能真正无信号息屏，说明可行 workaround 需要操作 adapter 或硬件信号层。
- 如果禁用 NVIDIA adapter 后 C340 仍然不息屏，则说明 C340 对当前 DP 物理状态的处理本身也存在问题，软件 workaround 空间会明显缩小。

### 候选 workaround 测试：临时禁用 NVIDIA display adapter

目的：
- Monitor PnP target 禁用无效后，下一层验证是直接禁用承载 C340 的 NVIDIA 显示适配器。
- 这会让 C340 所在的 DP 输出从源端消失，比禁用 Monitor 节点更接近“拔掉/关闭 NVIDIA DP 端口”。

当前安全前提：
- Intel UHD 730：`OK`
- H249W：WMI active，`DISPLAY\HKCB241\4&24219e88&0&UID20530_0`
- NVIDIA RTX 3070 Ti：`OK`
- C340：WMI active，`DISPLAY\HKCB34C\5&239bc59c&0&UID4357_0`

新增脚本：
- `work/test-disable-nvidia-adapter-dp-signal.ps1`
- `work/reenable-nvidia-adapter.ps1`

脚本特性：
- 需要管理员 PowerShell。
- 如果 H249W 不 active，或 Intel display adapter 不是 `OK`，脚本会拒绝禁用 NVIDIA。
- 禁用 NVIDIA 前会启动一个隐藏的延迟救援进程，默认 240 秒后尝试重新启用 NVIDIA。
- 主脚本默认禁用 NVIDIA 后观察 90 秒，并在 `finally` 中重新启用 NVIDIA。
- 运行时 C340 会掉线/闪屏，桌面可能重排；建议把 PowerShell 窗口先移到 H249W 上再运行。
- 两个脚本均已通过 PowerShell 语法检查。

### NVIDIA display adapter 禁用测试结果

时间：2026-07-07 02:16

日志：
- `work/disable-nvidia-adapter-dp-signal-20260707-021623.log`
- `work/reenable-nvidia-adapter-rescue-20260707-021623.log`

执行确认：
- 禁用前：
  - NVIDIA RTX 3070 Ti：`OK`
  - Intel UHD 730：`OK`
  - C340 + H249W 均为 WMI active monitor。
- 禁用 NVIDIA 后：
  - NVIDIA RTX 3070 Ti：`Error`
  - C340 Monitor PnP：`Unknown`
  - WMI active monitor 只剩 H249W。
- 观察 90 秒后，主脚本重新启用 NVIDIA。
- 重新启用后：
  - NVIDIA RTX 3070 Ti：`OK`
  - C340 + H249W 均恢复 WMI active。

用户观察：
- C340 表现为“无信号 -> 持续黑屏”，没有亮起黑色背光。
- H249W 副屏全程没有黑屏，窗口都迁移到 H249W。
- C340 在该状态下属于正常黑屏休眠。

结论：
- 临时禁用整个 NVIDIA display adapter 是目前第一个能让 C340 真正进入持续黑屏休眠的源端软件操作。
- 这确认根因在 NVIDIA adapter/DP 端口层，而不是 Windows Monitor PnP、EDID、自定义分辨率、ASPM、GPU P-state 或重复 DPMS 命令。
- 代价是 Windows 桌面拓扑会重排，窗口会迁移到 H249W；因此长期 workaround 需要处理“禁用 NVIDIA 时窗口重排/副屏保持亮”的副作用。

下一步候选：
- 测试更接近最终方案的流程：
  1. 先发送 Windows DPMS off，让两块屏进入正常关屏流程。
  2. 在 C340 异常亮背光前禁用 NVIDIA adapter。
  3. 禁用后再补发一次 DPMS off，尝试让 H249W 也保持息屏。
  4. 观察 C340 是否保持正常黑屏休眠、H249W 是否也能熄屏。
  5. 测试结束时唤醒 H249W，再重新启用 NVIDIA。

### DPMS + 禁用 NVIDIA adapter 组合测试结果

时间：2026-07-07 02:22

日志：
- `work/dpms-then-disable-nvidia-20260707-022211.log`
- `work/reenable-nvidia-adapter-rescue-dpms-20260707-022211.log`

流程确认：
- `02:22:12.809` 发送初始 Windows DPMS off。
- `02:22:21.103` 在显示器关闭窗口中禁用 NVIDIA display adapter。
- `02:22:27.258` 对剩余显示路径补发 DPMS off。
- 观察 90 秒。
- `02:23:57.364` 唤醒剩余显示路径。
- `02:24:00.535` 重新启用 NVIDIA。
- `02:24:12` C340 + H249W 均恢复 active。

用户观察：
- 两个显示器都息屏。
- C340 没有亮起黑色背光。

结论：
- “DPMS off -> 禁用 NVIDIA adapter -> 补发 DPMS off -> 唤醒后启用 NVIDIA”是当前第一个完整有效的软件 workaround 流程。
- 它同时解决：
  - C340 不再被 NVIDIA DP 链路拉回黑背光。
  - H249W 在 NVIDIA 禁用导致桌面重排后，也能通过补发 DPMS off 保持息屏。

剩余副作用/风险：
- NVIDIA adapter 被禁用时，Windows 桌面拓扑会临时重排到 H249W。
- 唤醒后重新启用 NVIDIA 时，窗口位置可能发生变化，需要后续实测长期可接受性。
- 该方案依赖 H249W/Intel 保持可用；如果只有 C340 一块屏，不应自动禁用 NVIDIA。

### 自动 workaround 脚本

新增脚本：
- `work/c340-dpms-nvidia-workaround.ps1`
- `work/install-c340-dpms-workaround-task.ps1`
- `work/uninstall-c340-dpms-workaround-task.ps1`

自动脚本逻辑：
- 监听 Windows `GUID_CONSOLE_DISPLAY_STATE` 与 `GUID_MONITOR_POWER_ON`。
- 检测到 display off 后，等待 8 秒。
- 确认 H249W 仍为 active、Intel display adapter 为 `OK`、NVIDIA adapter 为 `OK`。
- 启动延迟救援进程。
- 禁用 NVIDIA adapter。
- 等待 5 秒后补发 DPMS off。
- 检测到 display on 后，重新启用 NVIDIA adapter。

安装脚本：
- 创建计划任务：`C340 DPMS NVIDIA Workaround`
- 触发器：当前用户登录时。
- 权限：Highest / 管理员。
- PowerShell 参数：`-STA -WindowStyle Hidden`

卸载脚本：
- 停止并删除计划任务。
- 可选 `-ReenableNvidia` 用于卸载时顺手恢复 NVIDIA。

当前状态：
- 三个脚本均已通过 PowerShell parser 语法检查。
- 由于当前受限会话不是管理员，`#Requires -RunAsAdministrator` 的脚本无法在本会话中完成实际编译/运行测试；需要用户在管理员 PowerShell 中执行。

### 自动 workaround 脚本 GUID 修复

时间：2026-07-07 02:30

现象：
- 运行 `work/c340-dpms-nvidia-workaround.ps1 -TestOnce -TriggerDpmsAfterSeconds 5` 时，脚本在初始化阶段报错。
- 错误：无法将 `02731015-4510-4526-99e6-e5a17ebd1aea4` 转换为 `System.Guid`。

原因：
- `GUID_MONITOR_POWER_ON` 写错了一个字符。
- 错误值：`02731015-4510-4526-99e6-e5a17ebd1aea4`
- 正确值：`02731015-4510-4526-99e6-e517ebd1aea4`

影响：
- 错误发生在注册 power setting 通知之前。
- NVIDIA adapter 没有被禁用，系统显示状态没有被改变。
- 复查确认 NVIDIA/Intel 均为 `OK`，C340/H249W 均为 active。

修复：
- `work/c340-dpms-nvidia-workaround.ps1` 已替换两处 GUID。
- PowerShell parser 语法检查通过。
- 两个 GUID 均已通过 `[Guid]` 解析检查。

### 自动 workaround 脚本初始 On 通知修复

时间：2026-07-07 02:32

日志：
- `work/c340-dpms-nvidia-workaround-20260707-023218.log`

现象：
- 脚本启动后立刻收到 `ConsoleDisplayState=1`。
- 旧逻辑把该初始状态通知当成“用户唤醒”，于是 `TestOnce` 立即退出，没有等到 5 秒后的 DPMS trigger。

原因：
- `RegisterPowerSettingNotification` 后，Windows 可能立即推送当前电源状态。
- 这个 `On` 事件不是一次从 display off 恢复的唤醒事件。

修复：
- 新增 `$script:SleepCycleStarted` 状态位。
- 只有先收到 display off 并开始一次 sleep cycle 后，display on 才会触发 NVIDIA re-enable / TestOnce 退出。
- 启动时收到的当前 `On` 状态会记录为：`Display wake/current-on notification received before any display-off cycle; ignoring.`
- PowerShell parser 语法检查通过。

### 自动 workaround TestOnce 成功

时间：2026-07-07 02:36

日志：
- `work/c340-dpms-nvidia-workaround-20260707-023617.log`
- `work/reenable-nvidia-adapter-rescue-workaround-20260707-023630.log`

流程确认：
- `02:36:17` 脚本启动并注册 power setting 通知。
- 启动时收到 `ConsoleDisplayState=1`，新逻辑正确忽略。
- `02:36:22` 测试触发 DPMS off。
- `02:36:22` 收到 `ConsoleDisplayState=0`，安排 8 秒后禁用 NVIDIA。
- `02:36:30` 启动延迟救援进程，并禁用 NVIDIA RTX 3070 Ti。
- `02:36:36` 禁用 NVIDIA 后补发 DPMS off。
- `02:38:35` 用户移动鼠标唤醒，收到 `ConsoleDisplayState=1`。
- `02:38:35` 重新启用 NVIDIA。
- `02:38:45` NVIDIA re-enable 完成，`TestOnce` 正常退出。

用户观察：
- 两块显示器可以正常息屏。
- C340 没有亮起黑色背光。
- 移动鼠标可以正常唤醒。

结论：
- 自动监听版 workaround 已验证可用。
- 该脚本可以进入“登录自启任务”安装阶段。

后续优化：
- `work/c340-dpms-nvidia-workaround.ps1` 已补充救援进程句柄管理。
- 正常唤醒并重新启用 NVIDIA 后，会停止延迟救援进程，避免后台多留一个睡眠 PowerShell。
- 如果 display off 后用户很快唤醒、尚未禁用 NVIDIA，脚本会复位 sleep-cycle 状态。
- PowerShell parser 语法检查通过。

### NVIDIA 禁用期间的 GPU 任务影响与保护

时间：2026-07-07 02:48

用户确认：
- 删除 NVIDIA 自定义分辨率后，自动息屏仍然正常。
- 窗口重排可以接受。
- 关注点转为：息屏期间临时禁用 NVIDIA adapter 是否会影响 Blender 等 GPU 渲染任务。

影响判断：
- 临时禁用 NVIDIA display adapter 会拆掉 RTX 3070 Ti 的显示/计算设备上下文。
- 如果 Blender 正在使用 CUDA/OptiX/Cycles 调用 RTX 3070 Ti 渲染，息屏触发该 workaround 时，渲染很可能失败、中断、报错，甚至导致 Blender 设备丢失或崩溃。
- 如果 Blender 使用 CPU 渲染，渲染本身不依赖 NVIDIA 计算设备，但禁用 adapter 仍可能影响 Blender 窗口、GPU viewport 或桌面重排。
- 因此默认策略应当优先保护正在运行的 GPU 工作负载，而不是强行追求本次息屏完美。

脚本保护逻辑：
- `work/c340-dpms-nvidia-workaround.ps1` 新增默认保护参数：
  - `SkipWhenNvidiaBusy = true`
  - `BusyGpuUtilizationPercent = 15`
  - `ProtectedProcessNames = blender, blender-launcher`
- 在准备禁用 NVIDIA 前，脚本会先检查保护进程。
- 如果发现 `blender.exe` 或 `blender-launcher.exe` 正在运行，跳过禁用 NVIDIA。
- 如果没有保护进程，但 `nvidia-smi` 读取到 GPU 利用率大于等于阈值，也跳过禁用 NVIDIA。
- 跳过禁用时，C340 可能回到原始的 NVIDIA DP 黑色背光 bug，但不会主动打断重要 GPU 任务。

当前验证：
- `work/c340-dpms-nvidia-workaround.ps1` 已通过 PowerShell parser 语法检查。
- `nvidia-smi.exe` 可从 `C:\Windows\System32\nvidia-smi.exe` 调用。
- 空闲复测 GPU 利用率约 2% 到 5%，保护阈值 15% 当前不会阻止正常自动息屏。

后续修正：
- 该方向已废弃。按用户反馈，这属于软件名单/负载阈值式的治标方案，不能覆盖游戏、渲染器、计算软件等所有场景。
- `work/c340-dpms-nvidia-workaround.ps1` 中的 `SkipWhenNvidiaBusy`、`BusyGpuUtilizationPercent`、`ProtectedProcessNames`、`Get-NvidiaGpuUtilizationPercent`、`Test-NvidiaWorkloadAllowsDisable` 已回滚删除。
- 后续正确方向改为：移除 C340 的显示输出路径，但保持 NVIDIA GPU/adapter 本体可用。

### DisplayConfig 移除 C340 输出路径测试

时间：2026-07-07 03:01 - 03:03

新增脚本：
- `work/test-c340-displayconfig-remove-output.ps1`

目标：
- 不禁用 NVIDIA display adapter。
- 不禁用 Monitor PnP 设备。
- 通过 Windows CCD / DisplayConfig API 从 active display topology 中移除 C340 所在 path。
- 保留 H249W/Intel path 作为当前桌面输出。
- 验证 RTX 3070 Ti 是否仍然 `OK`，`nvidia-smi` 是否仍能访问。

关键实现：
- `QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS)` 读取当前 active paths。
- `DisplayConfigGetDeviceInfo(GET_TARGET_NAME)` 识别目标 path：
  - C340: `DISPLAY#HKCB34C#...`，DP，100Hz，targetId=4357。
  - H249W: `DISPLAY#HKCB241#...`，HDMI，60Hz，targetId=20530。
- `SetDisplayConfig(SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_ALLOW_CHANGES)` 只提交 H249W path。
- 单屏剩余 path 的 source position 归零为 `0,0`。
- 测试结束后用保存的原始 active paths 恢复 C340 + H249W 双屏。

第一次实现问题：
- 直接提交保留 path 但保留旧 mode 数组时，`SetDisplayConfig` 返回 Win32 error 87。
- 加入 `SDC_ALLOW_PATH_ORDER_CHANGES` 后仍返回 87；查证后该 flag 不能和 `SDC_USE_SUPPLIED_DISPLAY_CONFIG` 组合。
- 修正为：
  - 先尝试 `SDC_TOPOLOGY_SUPPLIED` path-only。
  - 如果失败，再使用 packed modes 的 supplied display config。

30 秒不 DPMS 短测：
- 日志：`work/c340-displayconfig-remove-output-20260707-030108.log`
- 移除 C340 path 成功：
  - `applyStrategy=use-supplied-display-config`
  - `topologyErr=87`
  - `suppliedErr=0`
- 移除后 `DisplayConfig activePaths=1 modes=2`，仅剩 H249W。
- NVIDIA RTX 3070 Ti 全程 `OK`。
- `nvidia-smi` 在 C340 path 移除后仍可访问。
- 30 秒后恢复原双屏成功。

75 秒 DPMS 组合测试：
- 日志：`work/c340-displayconfig-remove-output-20260707-030206.log`
- 流程：
  - 移除 C340 active path。
  - 验证只剩 H249W active path，NVIDIA 仍为 `OK`。
  - 5 秒后发送 DPMS off。
  - 观察 75 秒。
  - 恢复原 C340 + H249W 双屏。
- 日志层结论：
  - C340 输出 path 确实被移除。
  - NVIDIA GPU 未被禁用。
  - `nvidia-smi` 可用。
  - 恢复双屏成功。
- 待用户物理观察确认：
  - C340 在 75 秒 DPMS 观察期间是否保持“无信号 -> 持续黑屏”。
  - 是否仍出现“无信号 -> 黑色背光”。

用户反馈：
- 最后一次 75 秒 DPMS 组合测试中，C340 仍然亮起黑色背光。

结论更新：
- `SetDisplayConfig` 移除 C340 active desktop path 可以让 Windows 桌面只剩 H249W，并且能保持 NVIDIA GPU/adapter 可用。
- 但该操作不足以让 C340 在 Windows 全局 DPMS off 后维持真正断信号休眠。
- 这说明问题不只是桌面 active topology 仍在向 C340 输出黑画面；即使 C340 不在 active path 内，全局 DPMS/显示电源流程仍会让 NVIDIA DP target 或显示器链路重新进入“有效黑信号/黑色背光”状态。
- 因此，“移除 C340 active path + 再发全局 DPMS off”不是最终方案。

下一条更合理的测试方向：
- 避开 Windows 全局 DPMS off。
- 先移除 C340 active path，让 C340 自己进入无信号。
- 不再发送全局 `SC_MONITORPOWER` DPMS。
- 对 H249W 单独使用 DDC/CI VCP D6 power off，让副屏息屏。
- 目标是验证：是否是“全局 DPMS off”这个动作把非 active 的 C340/NVIDIA DP target 又拉回黑背光。

### DisplayConfig NoDpms 180 秒复测

时间：2026-07-07 03:06 - 03:09

命令：
- `work/test-c340-displayconfig-remove-output.ps1 -NoDpms -ObserveSeconds 180`

日志：
- `work/c340-displayconfig-remove-output-20260707-030641.log`

日志层结果：
- `03:06:41` 移除 C340 active path 成功。
- `03:06:45` `DisplayConfig after remove` 显示 `activePaths=1`，仅剩 H249W。
- NVIDIA RTX 3070 Ti 保持 `OK`。
- `nvidia-smi` 可用。
- 脚本没有提前恢复，直到 `03:09:45` 才执行 restore。

用户物理观察：
- C340 刚显示“无信号”后，就直接亮起屏幕回到桌面。
- 副屏 H249W 全程亮着。
- C340 回到桌面的节奏与之前“亮起黑色背光”的节奏一致，只是这次因为没有全局 DPMS，表现为直接回到桌面。

结论更新：
- 临时 `SetDisplayConfig` 移除 C340 path 本身可以成功。
- 但临时配置不会压住系统/驱动的显示拓扑恢复行为；在观察期内，C340 会被重新拉回到桌面输出。
- 这说明需要测试 `SDC_SAVE_TO_DATABASE`：临时把 H249W-only 拓扑写入 CCD persistence database，观察 C340 是否还会自动回到桌面；测试结束再恢复并保存原双屏拓扑。

### DisplayConfig SaveToDatabase 180 秒复测

时间：2026-07-07 03:11 - 03:15

命令：
- `work/test-c340-displayconfig-remove-output.ps1 -NoDpms -SaveToDatabase -ObserveSeconds 180`

日志：
- `work/c340-displayconfig-remove-output-20260707-031153.log`

变更：
- `work/test-c340-displayconfig-remove-output.ps1` 新增 `-SaveToDatabase` 参数。
- 移除 C340 path 时使用：
  - `SDC_USE_SUPPLIED_DISPLAY_CONFIG`
  - `SDC_APPLY`
  - `SDC_ALLOW_CHANGES`
  - `SDC_SAVE_TO_DATABASE`
- 观察期间每 15 秒 dump 一次 active DisplayConfig。
- 测试结束恢复原 C340 + H249W 双屏，并同样保存回数据库。

日志层结果：
- `applyStrategy=use-supplied-display-config-save-to-database`
- `suppliedErr=0`
- 移除后 `activePaths=1`，仅剩 H249W。
- 180 秒内每个 observation marker 均保持：
  - `activePaths=1`
  - 仅 H249W active path
  - C340 没有回到 Windows active topology
- NVIDIA RTX 3070 Ti 全程 `OK`。
- `nvidia-smi` 可用。
- 测试结束后恢复 C340 + H249W 双屏成功。

待用户物理观察确认：
- 这 180 秒内 C340 是否仍然回桌面。
- 如果没有回桌面，说明 `SDC_SAVE_TO_DATABASE` 可以压住自动恢复双屏的问题，下一步可测试“保存 H249W-only + C340 无信号 + H249W DDC/CI 单独关屏”。

用户物理观察：
- C340 没有回到桌面。
- C340 显示“无信号”后，全程保持黑屏。
- 没有亮起黑色背光。
- H249W 副屏全程保持亮屏。

结论：
- `SDC_SAVE_TO_DATABASE` + H249W-only 拓扑是目前第一个同时满足以下条件的方向：
  - C340 真正无信号黑屏。
  - 不禁用 NVIDIA GPU/adapter。
  - 不触发 C340 黑色背光。
  - 不依赖 NVIDIA 自定义分辨率。
- 下一步应该避开全局 DPMS，改为对 H249W 单独 DDC/CI power off。

### SaveToDatabase + H249W DDC/CI 关屏组合测试

时间：2026-07-07 03:18 - 03:19

命令：
- `work/test-c340-displayconfig-remove-output.ps1 -NoDpms -SaveToDatabase -H249wDdcciOff -ObserveSeconds 90`

日志：
- `work/c340-displayconfig-remove-output-20260707-031814.log`

变更：
- `work/test-c340-displayconfig-remove-output.ps1` 新增 `-H249wDdcciOff` 参数。
- 流程：
  - 保存 H249W-only topology 到 CCD database。
  - C340 从 active DisplayConfig path 移除。
  - 不发送全局 DPMS。
  - 对 H249W 发送 DDC/CI VCP D6=0x04。
  - 观察 90 秒。
  - 对 H249W 发送 DDC/CI VCP D6=0x01。
  - 恢复并保存原 C340 + H249W 双屏 topology。

日志层结果：
- 移除 C340 path 成功：
  - `applyStrategy=use-supplied-display-config-save-to-database`
  - `suppliedErr=0`
- 移除后 `activePaths=1`，仅剩 H249W。
- H249W DDC/CI 关屏成功：
  - `previousD6=0x01`
  - `Set H249W VCP D6=0x04`
- 90 秒内每个 observation marker 均保持：
  - `activePaths=1`
  - 仅 H249W active path
- H249W DDC/CI 唤醒成功：
  - `previousD6=0x02`
  - `Set H249W VCP D6=0x01`
- 恢复原 C340 + H249W 双屏成功。
- NVIDIA RTX 3070 Ti 全程 `OK`，`nvidia-smi` 可用。

待用户物理观察确认：
- C340 是否保持“无信号 -> 全程黑屏”，无黑色背光。
- H249W 是否在 DDC/CI D6=0x04 后真正息屏。
- 两屏是否在脚本结束后正常恢复。

用户物理观察：
- 90 秒测试里，两个屏幕都是真正黑屏。
- C340 没有亮起黑色背光。
- H249W 也一并黑屏。
- 测试结束后两块屏都恢复。

当前最佳方案结论：
- 不禁用 NVIDIA GPU/adapter。
- 不使用全局 Windows DPMS。
- 睡眠进入流程：
  1. 用 `SetDisplayConfig + SDC_SAVE_TO_DATABASE` 保存 H249W-only topology。
  2. C340 从 active topology 中移除，进入“无信号 -> 真黑屏”。
  3. 用 DDC/CI VCP D6=0x04 单独关闭 H249W。
- 唤醒/恢复流程：
  1. 用 DDC/CI VCP D6=0x01 打开 H249W。
  2. 恢复并保存原 C340 + H249W 双屏 topology。
- 这是目前第一个同时满足以下条件的 workaround：
  - C340 不亮黑色背光。
  - H249W 也能真正息屏。
  - NVIDIA GPU 保持可用，`nvidia-smi` 可访问。
  - 不依赖 NVIDIA 自定义分辨率。
  - 不需要按应用进程名单做例外判断。

### 自动监听 TestOnce 状态机测试

时间：2026-07-07 03:24 - 03:31

目标：
- 把已验证的手动流程提升为监听 Windows display-off 事件的自动流程。
- 进入显示器关闭状态后，不禁用 NVIDIA，不发额外全局 DPMS，而是执行：
  - 保存 H249W-only topology。
  - C340 无信号黑屏。
  - H249W DDC/CI D6=0x04。
- 唤醒或自动恢复时：
  - H249W DDC/CI D6=0x01。
  - 恢复并保存 C340 + H249W 双屏 topology。

第一次监听 TestOnce：
- 命令：
  - `work/test-c340-displayconfig-remove-output.ps1 -Listen -TestOnce -TriggerDpmsAfterSeconds 5 -AutoRestoreAfterSeconds 90`
- 日志：
  - `work/c340-displayconfig-remove-output-20260707-032440.log`
- 结果：
  - Windows DPMS 触发瞬间连续出现 `ConsoleDisplayState=0/1/0/1` 抖动。
  - 旧状态机会在 apply 尚未完成时执行 restore，随后又重复 apply。
  - 最后出现“原始拓扑被覆盖成 H249W-only”的风险。
- 处置：
  - 立即用 `work/restore-c340-h249w-dual-topology.ps1` 恢复 C340 + H249W 双屏 supplied config 并保存到数据库。
  - 恢复验证快照：
    - `work/display-state-snapshots/20260707-032819-after-restore-dual-topology-script-2/displayconfig.txt`
    - `activePaths=2`
    - C340 3440x1440@100
    - H249W 1920x1080@60

状态机修复：
- 新增状态：
  - `Idle`
  - `PendingApply`
  - `Applying`
  - `Active`
  - `Restoring`
- apply 期间拒绝重复 apply。
- apply 期间收到 wake 事件时延迟处理，不允许 restore/apply 重入。
- 新增 `WakeDebounceSeconds`，默认用于忽略 DPMS/SetDisplayConfig 触发初期的伪 wake。
- restore 完成后清理 `WakeIgnoreUntil`、`PendingWake`、partial flags。

第二次监听 TestOnce：
- 命令：
  - `work/test-c340-displayconfig-remove-output.ps1 -Listen -TestOnce -TriggerDpmsAfterSeconds 5 -AutoRestoreAfterSeconds 45 -WakeDebounceSeconds 8`
- 日志：
  - `work/c340-displayconfig-remove-output-20260707-033019.log`
- 日志层结果：
  - 初始 `ConsoleDisplayState=1` 被正确忽略。
  - `03:30:25` 触发 Windows DPMS off。
  - `03:30:27` 保存 H249W-only topology 成功。
  - `03:30:28` H249W DDC/CI D6=0x04 成功。
  - `03:31:13` 恢复 H249W DDC/CI D6=0x01。
  - `03:31:13` 恢复原 C340 + H249W 双屏 topology 成功。
  - `03:31:19` 验证 `activePaths=2 modes=4`。
  - NVIDIA RTX 3070 Ti 全程 `OK`，`nvidia-smi` 可用。

待用户物理观察确认：
- 自动监听 TestOnce 的 45 秒黑屏阶段，C340 是否仍然没有黑色背光。
- H249W 是否真正黑屏。
- 恢复时两屏是否正常回到桌面。

用户物理观察：
- C340 没有黑色背光。
- H249W 也真正黑屏。
- 两块屏幕都可以正常回到桌面。
- 目前看起来没有问题。

最终方向确认：
- 自动监听版 workaround 已通过日志层和物理观察双重验证。
- 核心方案为：
  - 监听 Windows display-off 事件。
  - 使用 `SetDisplayConfig + SDC_SAVE_TO_DATABASE` 保存 H249W-only topology，让 C340 进入无信号真黑屏。
  - 使用 H249W DDC/CI VCP D6=0x04 关闭副屏。
  - 唤醒时 H249W DDC/CI D6=0x01，并恢复保存 C340 + H249W 双屏 topology。
- 该方案不禁用 NVIDIA GPU/adapter，因此比之前禁用 NVIDIA 的 workaround 更接近最终目标。

### 正式脚本与计划任务安装

时间：2026-07-07 03:35 - 03:40

新增正式入口：
- `work/c340-topology-ddcci-workaround.ps1`
  - 固定调用已验证的 topology/DDC listener 模式。
  - 默认参数：
    - `WakeDebounceSeconds=8`
    - `ApplyDelayMilliseconds=0`
  - 不包含禁用 NVIDIA GPU/adapter 的逻辑。

新增安装脚本：
- `work/install-c340-topology-ddcci-workaround-task.ps1`
  - 创建计划任务：`C340 Topology DDC Sleep Workaround`
  - 触发器：当前用户登录时启动。
  - 运行方式：隐藏 PowerShell，`-STA`，`ExecutionPolicy Bypass`。
  - `RunLevel=Limited`。
  - 支持 `-StartNow` 立即启动。

新增卸载脚本：
- `work/uninstall-c340-topology-ddcci-workaround-task.ps1`
  - 停止并删除计划任务。
  - 可选 `-RestoreDualTopology`，卸载时顺手恢复 C340 + H249W 双屏。

新增恢复脚本：
- `work/restore-c340-h249w-dual-topology.ps1`
  - 用 supplied DisplayConfig 明确恢复：
    - C340：3440x1440@100，DP。
    - H249W：1920x1080@60，HDMI。
  - 保存回 CCD database。

验证：
- `work/c340-topology-ddcci-workaround.ps1 -CompileOnly` 通过。
- 正式入口 TestOnce 通过：
  - 命令：`work/c340-topology-ddcci-workaround.ps1 -TestOnce -TriggerDpmsAfterSeconds 5 -AutoRestoreAfterSeconds 30 -WakeDebounceSeconds 8`
  - 日志：`work/c340-displayconfig-remove-output-20260707-033537.log`
  - 结果：
    - C340 被移出 active topology。
    - H249W DDC/CI D6=0x04 成功。
    - 30 秒后 H249W DDC/CI D6=0x01 成功。
    - 恢复 C340 + H249W 双屏成功。
    - 恢复阶段重复 wake 事件被正确忽略。
- 安装任务成功：
  - `C340 Topology DDC Sleep Workaround`
  - 状态：`Running`
  - 最新常驻日志：`work/c340-displayconfig-remove-output-20260707-033653.log`

真实 1 分钟自动息屏测试：
- 测试前电源设置：
  - AC display timeout：900 秒。
  - DC display timeout：180 秒。
- 临时设置：
  - AC display timeout：60 秒。
- 日志结果：
  - `03:37:54` 收到 `ConsoleDisplayState=0`，真实系统 idle 触发。
  - `03:37:54` 保存 H249W-only topology。
  - `03:37:55` H249W DDC/CI D6=0x04 成功。
  - `03:38:51` 收到 `ConsoleDisplayState=1` 并恢复。
  - `03:38:51` H249W DDC/CI D6=0x01 成功。
  - `03:38:51` 恢复 C340 + H249W 双屏 topology 成功。
  - `03:38:56` 验证 `activePaths=2 modes=4`。
- 测试后电源设置已恢复：
  - AC display timeout：900 秒。
  - DC display timeout：180 秒。
- 计划任务仍为 `Running`。
- 当前 DisplayConfig 快照：
  - `work/display-state-snapshots/20260707-033950-after-installed-task-real-idle-test/displayconfig.txt`
  - C340 + H249W 双屏 active。

待确认：
- 真实 1 分钟测试中，`03:38:51` 的 wake 事件早于脚本预设的鼠标唤醒；需要确认用户是否在这之前移动了鼠标/键盘，或屏幕是否自行提前亮起。

用户确认：
- `03:38:51` 的 wake 事件是用户主动唤醒。

最终安装状态：
- `C340 Topology DDC Sleep Workaround` 计划任务已安装并处于 `Running`。
- 真实系统自动息屏、用户主动唤醒、双屏恢复链路均已验证通过。

### 强制恢复双屏 baseline 改造

时间：2026-07-07 04:22

用户反馈：
- 执行强制恢复双屏后，H249W 会跑到右侧。
- 用户手动将 H249W 改回左侧，希望做成“保存当前布局为基准，再按基准恢复”。

当前布局读取：
- C340: `3440x1440 @ 0,0`
- H249W: `1920x1080 @ -1920,182`

改动：
- `restore-c340-h249w-dual-topology.ps1` 新增参数：
  - `-SaveCurrentAsBaseline`
  - `-IgnoreBaseline`
  - `-BaselinePath`
- 新增 baseline 文件：
  - `display-layout-baseline.ini`
- 默认强制恢复时优先读取 baseline。
- 没有 baseline 或指定 `-IgnoreBaseline` 时，才使用脚本内置 fallback 布局。

已保存 baseline：
- C340: `(0,0)`
- H249W: `(-1920,182)`

验证：
- 执行 `restore-c340-h249w-dual-topology.ps1 -SaveCurrentAsBaseline` 成功保存当前左侧布局。
- 执行 `restore-c340-h249w-dual-topology.ps1` 后，DisplayConfig 验证：
  - C340: `3440x1440 @ 0,0`
  - H249W: `1920x1080 @ -1920,182`
- 结论：强制恢复双屏现在会按用户当前左侧布局恢复。

### Restore baseline MethodNotFound fix

Time: 2026-07-07 04:26

User report:
- Running `restore-c340-h249w-dual-topology.ps1 -SaveCurrentAsBaseline` in the same PowerShell session failed with:
  - `[C340RestoreDual.Topology] does not contain a method named SaveBaseline`

Cause:
- PowerShell had already loaded the old embedded C# type `C340RestoreDual.Topology`.
- Loaded .NET types cannot be replaced inside the same PowerShell process.
- The updated script file contained `SaveBaseline`, but the current session was still calling the old cached type.

Fix:
- Renamed the embedded C# namespace/type reference from `C340RestoreDual.Topology` to `C340RestoreDualBaseline.Topology`.
- This avoids the old session cache and lets the updated restore-baseline script run without requiring the user to close PowerShell.

Verification:
- Syntax check passed.
- `restore-c340-h249w-dual-topology.ps1 -SaveCurrentAsBaseline` succeeded.
- Saved baseline:
  - C340: `(0,0)`
  - H249W: `(-1920,182)`

### Wake restore race and forced-restore improvement

Time: 2026-07-07 04:30 - 04:35

User report:
- During wake, C340 or H249W can sometimes fail to physically wake even though Windows receives a wake event.
- Running `restore-c340-h249w-dual-topology.ps1` reported `activePaths=2`, but the command seemed ineffective.

Evidence:
- At `2026-07-07 04:27:21`, the listener received `ConsoleDisplayState=1`.
- It immediately tried `H249W DDC/CI VCP D6=0x01`.
- The DDC/CI call failed with:
  - `Cannot get H249W physical monitor count`
  - `The specified GDI device does not have any monitors associated with it`
- `SetDisplayConfig` then succeeded and reported `activePaths=2`.

Interpretation:
- Wake notification can arrive before the display stack and physical monitor handles are ready.
- `SetDisplayConfig` success means Windows topology is active; it does not guarantee that the physical monitor has accepted wake/power-on yet.
- The old forced-restore script only restored topology. It did not send H249W DDC/CI power-on, so it could report success while H249W stayed physically asleep.

Code changes:
- `c340-topology-ddcci-core.ps1`
  - Added wake restore delay: `RestoreWakeDelayMilliseconds=1200`.
  - Added DisplayConfig restore retry: `DisplayRestoreRetryCount=3`.
  - Added H249W DDC/CI power-on retry: `H249wPowerOnRetryCount=8`.
  - Changed wake restore order:
    - wait briefly after wake
    - restore original C340 + H249W topology, with retries
    - then power on H249W via DDC/CI, with retries
  - If H249W DDC/CI power-on still fails, the pending flag is kept so the next wake/restore event can retry.
- `restore-c340-h249w-dual-topology.ps1`
  - Added DisplayConfig restore retry.
  - Added H249W DDC/CI `D6=0x01` power-on retry after topology restore.
  - Added `-SkipH249wPowerOn` escape hatch.
- `c340-topology-ddcci-workaround.ps1` and installer now pass/use the new restore parameters.

Local verification:
- Syntax checks passed for all release `.ps1` files.
- `c340-topology-ddcci-workaround.ps1 -CompileOnly` passed.
- Manual forced restore succeeded:
  - DisplayConfig restore: attempt `1/3`
  - H249W DDC/CI power-on: attempt `1/8`
  - DDC result: `Set H249W VCP D6=0x01`
- Scheduled task was restarted and is running with:
  - `RestoreWakeDelayMilliseconds=1200`
  - `DisplayRestoreRetryCount=3`
  - `H249wPowerOnRetryCount=8`
- Existing scheduled task registration could not be overwritten from the restricted process due to Windows access control.
  - The task was still restarted successfully.
  - The existing task action calls the wrapper script, and the wrapper loads the current defaults from disk.
  - `install-c340-topology-ddcci-workaround-task.ps1` now reports `RegistrationUpdated=False` as a warning case instead of failing with red errors.

Pending physical verification:
- Let Windows idle-sleep normally.
- Wake with mouse/keyboard.
- Confirm both C340 and H249W physically wake every time.
- If either screen still stays asleep, compare the newest listener log for retry counts and failures.

### Hidden launcher and no-log install mode

Time: 2026-07-07 04:50 - 04:53

User report:
- After installing the script, a visible PowerShell/cmd window remains open.
- Closing that window changes the scheduled task state to `Ready`, and the workaround stops working.
- Runtime logs are too noisy for normal daily use; logs should be for testing/debugging.

Cause:
- The scheduled task was directly launching `powershell.exe`.
- Even with `-WindowStyle Hidden`, an interactive scheduled task can still show a console window.
- Closing that visible console closes the listener process.

Code changes:
- Added `start-c340-topology-ddcci-hidden.vbs`.
  - It is launched by `wscript.exe`, which has no console window.
  - It starts `powershell.exe` hidden and waits for it, so the listener can remain alive without a visible window.
- Added `-NoLog` to:
  - `c340-topology-ddcci-core.ps1`
  - `c340-topology-ddcci-workaround.ps1`
- Updated `install-c340-topology-ddcci-workaround-task.ps1`.
  - Scheduled task action now targets `wscript.exe`.
  - It passes the hidden launcher path.
  - Formal install defaults to `-NoLog`.
  - Added `-EnableLog` for debug installs.
  - It stops old listener processes before starting the new one.
  - If task registration cannot be updated due to access control, it starts the hidden launcher directly and reports `RegistrationUpdated=False`.
- Updated `uninstall-c340-topology-ddcci-workaround-task.ps1`.
  - It stops both the old direct PowerShell listener and the hidden launcher process.

Local verification:
- All release `.ps1` files pass PowerShell parser checks.
- `c340-topology-ddcci-workaround.ps1 -CompileOnly -NoLog` succeeds.
- `cscript //B //Nologo start-c340-topology-ddcci-hidden.vbs -CompileOnly -NoLog` exits with code `0`.
- The restricted process could not update the existing scheduled task registration because Windows returned `Access is denied`.
- Fallback hidden launcher started successfully:
  - `wscript.exe ... start-c340-topology-ddcci-hidden.vbs ... -NoLog`
  - child `powershell.exe ... c340-topology-ddcci-workaround.ps1 ... -NoLog`

Required user-side action for permanent install:
- Run `install-c340-topology-ddcci-workaround-task.ps1 -StartNow` from an elevated/admin PowerShell window.
- Expected result: `RegistrationUpdated=True`.
- Daily install should not generate runtime logs unless `-EnableLog` is supplied.

### Interrupted display-off race fix

Time: 2026-07-07 05:21 - 05:30

User report:
- If the mouse is moved at the exact moment display sleep starts, or before the workaround finishes its display-off sequence, one or both monitors can fail to wake.
- Recovery required manually running force-restore or waiting for another display-off/display-on cycle.

Evidence from `c340-displayconfig-remove-output-20260707-050036.log`:
- At `05:16:37`, display-off started.
- At `05:16:38`, C340 had been removed from active topology and H249W had been powered off through DDC/CI.
- At `05:16:41`, a real wake arrived inside the debounce window.
- The old code logged:
  - `Ignoring debounced wake event ... State=Active`
- Result: the listener stayed in the sleep-workaround state until a later cycle.

Evidence from `c340-displayconfig-remove-output-20260707-052016.log`:
- At `05:21:21`, display-off started.
- C340 was removed from topology.
- At `05:21:22`, H249W DDC/CI power-off failed with:
  - `Cannot read H249W VCP D6`
- The old cleanup path called restore while state was still `Applying`.
- The restore request was deferred:
  - `Restore requested while apply is running; deferring restore`
- At `05:21:24`, a real wake arrived inside the debounce window and was ignored while `State=Applying`.

Root cause:
- The wake debounce logic was too broad.
- It treated early real user wake events the same as fake/driver-generated wake events.
- Apply failure cleanup also went through the normal anti-reentry path, so it could be deferred and then swallowed by debounce.

Code changes:
- `Restore-TopologyDdcciSleep` now supports:
  - `-Force`
  - `-SkipWakeDebounce`
- Wake events inside the debounce window are no longer silently ignored.
  - `PendingApply`: cancel the pending apply immediately.
  - `Applying`: mark `PendingWake`; successful apply restores immediately afterward.
  - `Active` or partial state: schedule a restore at the end of the debounce window.
- Added `DebouncedRestoreTimer`.
  - It runs the delayed forced restore once the debounce window expires.
- Apply failure cleanup now calls:
  - `Restore-TopologyDdcciSleep -Force -SkipWakeDebounce`
  - It no longer rethrows from the event callback after scheduling cleanup.
- Added `H249wDdcciOffAttempted`.
  - If DDC/CI power-off was attempted but failed ambiguously, recovery still tries `D6=0x01`.
- Listener exit cleanup now also restores if `H249wDdcciOffAttempted` is pending.

Local verification:
- All release `.ps1` files pass PowerShell parser checks.
- `c340-topology-ddcci-workaround.ps1 -CompileOnly -NoLog` succeeds.
- `cscript //B //Nologo start-c340-topology-ddcci-hidden.vbs -CompileOnly -NoLog` exits with code `0`.

Pending physical verification:
- Install the updated task from elevated/admin PowerShell.
- Test the interrupt case:
  - let display-off begin
  - move mouse during the first few seconds
  - expected result: the listener restores dual topology instead of leaving one/both screens asleep

### S1.1: Remove hard H249W dependency from runtime workaround

Time: 2026-07-07

Motivation:

- User noted that depending on H249W-specific DDC/CI power control is not elegant.
- Current evidence shows the C340 fix itself is the DisplayConfig topology removal, not H249W DDC/CI.
- H249W DDC/CI is only needed to make the remaining secondary display sleep as well.

Code changes:

- Added `-RemainingDisplayPowerMode`:
  - `DdcciAllRemaining`: after removing C340/problem target, send DDC/CI `D6=0x04` to all remaining active logical displays.
  - `Disabled`: do not use DDC/CI for remaining displays.
  - `H249W`: legacy compatibility path.
- Added `-DdcPowerOnRetryCount` and `-DdcPowerOnRetryDelayMilliseconds`.
  - Old `-H249wPowerOnRetryCount` and `-H249wPowerOnRetryDelayMilliseconds` remain as aliases.
- Runtime listener default remains feature-complete through `c340-topology-ddcci-workaround.ps1`:
  - `RemainingDisplayPowerMode=DdcciAllRemaining`.
- Low-level `c340-topology-ddcci-core.ps1` defaults to:
  - `RemainingDisplayPowerMode=Disabled`
  - This preserves old focused topology-only test behavior unless DDC/CI is explicitly requested.
- Generic DDC/CI handling now:
  - enumerates active logical monitors after C340/problem target removal
  - attempts `VCP D6=0x04`
  - records only successful logical display names
  - on wake, sends `D6=0x01` only to those recorded displays
- DDC/CI failure no longer aborts or rolls back the topology workaround.
  - C340 topology removal remains the primary fix.
  - Remaining-display power-off becomes a best-effort enhancement.

Local verification:

- PowerShell parser checks pass for:
  - `c340-topology-ddcci-core.ps1`
  - `c340-topology-ddcci-workaround.ps1`
  - `install-c340-topology-ddcci-workaround-task.ps1`
- `c340-topology-ddcci-workaround.ps1 -CompileOnly -NoLog` succeeds.

Pending physical verification:

- Reinstall task from elevated/admin PowerShell.
- Test default mode:
  - `RemainingDisplayPowerMode=DdcciAllRemaining`
  - expected: C340 true black/no black backlight, H249W DDC/CI off if supported.
- Test fallback mode if desired:
  - `-RemainingDisplayPowerMode Disabled`
  - expected: C340 still true black/no black backlight, H249W may remain lit.

### S1.2: Generalize target display selection

Time: 2026-07-09

Migration step:

- Created a separate `work` directory for the generalized codebase.
- Copied all files from `C340-Topology-DDC-Sleep-Workaround` into `work`.
- Left the original source directory untouched.

Motivation:

- The verified workaround should remain available for C340.
- The runtime path should also be configurable enough to test other monitors that have similar display-sleep problems.

Code changes:

- Added target matching parameters to `c340-topology-ddcci-core.ps1`:
  - `-TargetNeedles`
  - `-TargetId`
  - `-TargetOutputTechnology`
  - `-ProfileName`
  - `-LogFilePrefix`
  - `-ListDisplays`
- Kept `-TargetNeedle` as an alias for compatibility.
- Added `PathControl.RemoveTargetMatching(...)`.
  - Multiple `TargetNeedles` are OR-matched against DisplayConfig friendly/path.
  - `TargetId` and `TargetOutputTechnology` are AND-matched when provided.
  - The script still refuses to remove the last active display path.
- Renamed the runtime embedded C# namespace from `C340DisplayConfig` to `TopologyDdcciDisplayConfig` to avoid stale type collisions in reused PowerShell sessions.
- Updated `c340-topology-ddcci-workaround.ps1` and the C340 installer to pass the new parameters.
- Added generic entry files:
  - `topology-ddcci-workaround.ps1`
  - `install-topology-ddcci-workaround-task.ps1`
  - `start-topology-ddcci-hidden.vbs`
  - `uninstall-topology-ddcci-workaround-task.ps1`
- Left `restore-c340-h249w-dual-topology.ps1` as a C340 + H249W-specific rescue script because it still embeds fixed target IDs, resolutions, refresh rates, and layout assumptions.

Pending physical verification:

- Copy `work` to the Windows target machine.
- Run `.\topology-ddcci-workaround.ps1 -ListDisplays -NoLog`.
- Pick a unique target criterion from the output.
- Run a `-TestOnce` cycle before installing the scheduled task.

### 2026-07-10: Natural single-display A/B capture

Two complete 120-second natural display-sleep captures were compared on NVIDIA driver `32.0.16.1062`:

- `20260710-142806-current-native-bad`
- `20260710-143319-current-custom-good`

Both runs received Windows `ConsoleDisplayState=0`, retained the same single C340 DisplayPort active path, remained at NVIDIA P8, and had no active `powercfg /requests` blocker. The decisive difference at the 120-second marker was:

```text
native bad:        Display Attached=Yes, Display Active=Enabled
CustomDisplay good: Display Attached=Yes, Display Active=Disabled
```

Before sleep and after wake, both modes reported `Display Active=Enabled`. This proves that the good CustomDisplay state makes the NVIDIA driver deactivate the display output during natural DPMS, while the native bad state leaves the output active even though Windows considers the display off.

The native ETW trace contained 10 D0/Suspend/D3 cycles and the CustomDisplay trace contained 9. Neither natural trace contained the previously observed `DevicePoweredOn` or `DevicePreparation` text. The extra native cycle is not yet proven causal. The investigation should now target the NVIDIA DisplayPort output/target power transition rather than treating the issue as a monitor-only backlight command failure.

### 2026-07-10: Public CCD exact-mode reapply experiment prepared

Added `diagnostics/test-displayconfig-mode-reapply.ps1` to test whether the public Windows CCD path can make NVIDIA deactivate the native-mode output without creating an NVIDIA CustomDisplay.

The experiment has two isolated strategies:

- `NoOptimization`: resubmit the exact queried single-display paths and modes with `SDC_NO_OPTIMIZATION`, which Microsoft documents as forcing the mode change down to the driver.
- `ForceModeEnumeration`: add `SDC_FORCE_MODE_ENUMERATION`, which gives the driver an opportunity to refresh its GDI mode list.

Neither strategy saves to the CCD database. The script validates first, requires one matching active path, captures and restores the original arrays, requires timed visual confirmation after the mode blink, and arms an independent `DisplaySwitch.exe /extend` watchdog. The production listener remains unchanged until physical evidence shows that one strategy changes natural-sleep `Display Active` from `Enabled` to `Disabled`.

### 2026-07-10: Public CCD mode reapply rejected

Both prepared strategies completed on the Windows target:

- `NoOptimization`: validation and apply succeeded with flags `0x000001A0`.
- `ForceModeEnumeration`: validation and apply succeeded with flags `0x000011A0`.

Both retained the exact native `3440x1440`, `533150000`, `99.998Hz` path. At the 120-second natural display-off marker, both still reported `Display Attached=Yes, Display Active=Enabled`. Both also showed four D0/Suspend/D3 cycles around 20 seconds after display-off, matching the failing native pattern. The NVIDIA `CustomDisplay` values were all-zero records with the known bad hash `84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652`.

Conclusion: neither forced driver mode submission nor mode-list enumeration reaches the internal CustomDisplay DPMS path. The production listener remains unchanged.

The next branch is anchor discovery. Added read-only `diagnostics/inspect-displayconfig-anchor-candidates.ps1`, which uses `QDC_ALL_PATHS` to report inactive targets that are already available or forceable. If no candidate exists, single-physical-display topology removal requires a real Indirect Display Driver or a physical dummy target.

### 2026-07-10: Existing anchor discovery completed

`displayconfig-anchor-candidates-20260710-152642.log` reported:

```text
allPaths=172 modes=2 activeTargets=1
candidateTargets=0
NO_CANDIDATE
```

The only available target was the already active C340. Every inactive target had `targetAvailable=False` and `forcible=False`; no existing disconnected target can be activated through CCD as an anchor.

This closes the public-CCD reuse branch. A physical dummy plug or a driver that reports a genuinely connected virtual monitor is required. Added an isolated `anchor-driver/` prototype derived from Microsoft's official Indirect Display sample (MS-PL). It reports exactly one EDID-less indirect-wired monitor with three conservative modes and uses a stable container ID. The controller owns the software-device lifetime.

The prototype is not integrated into `topology-ddcci-workaround.ps1`. Its first acceptance gate is a Windows build/load test proving that exactly one identified anchor appears as `targetAvailable=True`, `outputTech=16`. Windows may initially activate a newly arrived monitor, so the diagnostic reports `ANCHOR active=...` separately from generic inactive candidates. Controlled activation is explicitly deferred until that evidence exists.

### 2026-07-10: NVIDIA native CommitVidPn experiment prepared

Before accepting a virtual display as the single-monitor solution, the next experiment returns to the NVIDIA-native power path. NVIDIA's public R610 NVAPI exposes `NvAPI_DISP_GetDisplayConfig`, `NvAPI_DISP_SetDisplayConfig`, and `NV_FORCE_COMMIT_VIDPN (0x10)`. NVIDIA documents the flag as preventing optimization of the `CommitVidPn` call during a modeset.

Added `diagnostics/NvApiDisplayCommit.cs` and `diagnostics/test-nvapi-force-commit-vidpn.ps1`. The PowerShell process compiles the bridge in memory and calls the installed `nvapi64.dll`; no WDK build or custom driver is involved. The experiment queries the full current NVAPI structure graph, validates it, then resubmits it unchanged with only `NV_FORCE_COMMIT_VIDPN`. It rejects non-x64 processes, multiple NVAPI paths or targets, non-NVIDIA paths, zero display IDs, any NVAPI signature change, and any Windows CCD text change.

The first command is read-only (`-QueryOnly`). The apply test arms a recovery watchdog, requires visual confirmation after the commit, and then launches the existing 120-second natural-sleep capture. Production code remains unchanged until NVIDIA changes from `Display Active: Enabled` to `Disabled` in physical testing.

### 2026-07-10: NVIDIA native CommitVidPN experiment rejected

The `screenshot/test3` apply run proves that the NVAPI bridge and ABI were functioning:

- one NVAPI path and one NVIDIA target were returned, with display ID `0x80061086`, `3440x1440`, and `refreshRate1K=99998`;
- `NvAPI_DISP_SetDisplayConfig` validation and apply both returned `0` with only `NV_FORCE_COMMIT_VIDPN (0x10)`;
- the before/after NVAPI signatures were identical, Windows CCD remained on the same single native path, and the user confirmed that the image was visible after the commit.

The natural-sleep result still matched the bad state. At the 120-second marker, NVIDIA reported `DisplayAttached=Yes DisplayActive=Enabled PerformanceState=P5`. ETW recorded `DevicePoweredOn` at `+90.337955s`, `IrpRequestSentD3` at `+114.341833s`, and `IrpRequestSentD0` at `+114.493246s`. The unchanged native VidPN force commit therefore does not change the failing output-power state machine.

This closes the NVIDIA mode-resubmission branch. The diagnostic remains for reproducibility, but it will not be integrated or expanded with additional NVIDIA-only flags.

### 2026-07-10: Documented user-mode display-power boundary

An audit of Microsoft's documented interfaces found no generic application API that directly sets the physical power state of a normal desktop display output while retaining its active desktop path:

- `GUID_CONSOLE_DISPLAY_STATE` and `GUID_MONITOR_POWER_ON` are notifications.
- `Windows.Devices.Display.Core.DisplaySource.Status` is read-only and belongs to the custom-compositor model for specialized displays.
- `IOCTL_VIDEO_SET_POWER_MANAGEMENT` is obsolete and unsupported on modern Windows.
- `DxgkDdiSetPowerState` is implemented inside a WDDM display miniport driver.
- `CIM_Display.SetPowerState` is not implemented by WMI.

`SC_MONITORPOWER` can request display power-off, but the OS and GPU display driver own the physical DPMS/link transition. A script cannot generically replace a faulty driver transition. With one physical display, the vendor-neutral topology workaround therefore requires a second valid target (physical, dummy, or IDD). Without such a target, the remaining fixes are GPU-driver changes or monitor-specific DDC/CI behavior.

### 2026-07-10: Active-path alternatives prepared

The topology constraint applies only to removing the final active path, so three experiments now test mechanisms that retain the single C340 path:

1. `LowPower` sends documented `SC_MONITORPOWER` state `1`, which has not previously been tested; the rejected re-off watchdog used state `2`.
2. `ModeTransition` temporarily changes to a genuinely different enumerated mode through `ChangeDisplaySettingsEx`, waits for natural display sleep, and restores the exact original `DEVMODE`. This is distinct from resubmitting unchanged CCD arrays.
3. `D3dKeepAlive` creates a D3D11 device on the exact target adapter by matching DisplayConfig and DXGI LUIDs. A timer updates and flushes a 256-byte constant buffer without a window, swap chain, present, or display power request. This tests whether active WDDM work suppresses the D3/D0 cycle that precedes the powered black state; clock locking did not test this condition.

Implemented `diagnostics/ActivePathSleepExperiment.cs` and `diagnostics/test-active-path-sleep-experiment.ps1`, and extended the existing capture with an opt-in explicit display-power trigger. The default capture remains natural. The new bridge compiles locally and reports expected x64 ABI sizes: path `72`, mode `64`, source name `84`, target name `420`, and `DEVMODEW` `220`. Production code is unchanged pending physical Windows results.

### 2026-07-10: SC_MONITORPOWER LowPower rejected

The `screenshot/test4` run sent state `1` at `20:11:21.483` and returned from the call successfully. `ConsoleDisplayState=0` did not arrive until `20:12:06.196`, approximately 45 seconds later. The command therefore did not initiate an immediate console display-off; the later event was consistent with the configured natural display timeout.

The user observed the same powered black backlight. At the snapshot, the single native C340 path remained active and NVIDIA reported `DisplayAttached=Yes DisplayActive=Enabled PerformanceState=P5`. Relative to the actual console-off event, repeated `SuspendRequestSent` activity began at approximately `+20.6s` and continued throughout the observation. LowPower is rejected and will not be integrated.

The explicit-trigger capture now records `ConsoleDisplayOffAt` separately. If a real console-off event arrives after an explicit trigger, it restarts the full observation interval and uses the actual off time as the ETW reference. Natural capture behavior is unchanged.

### 2026-07-10: D3D11 keep-alive rejected

The `screenshot/test5` run confirms that the experiment operated on the intended device. The DisplayConfig target and DXGI adapter both used LUID `00000000:00010309`, identifying the NVIDIA GeForce RTX 3070 Ti. The keep-alive had completed two pulses before capture, reached `254` pulses at cleanup, reported feature level `0xB000`, and recorded no failure. It therefore remained active throughout the natural display-off and full 120-second observation.

The physical black backlight still returned. At the 120-second marker, the unchanged single native C340 path remained active and NVIDIA reported `DisplayAttached=Yes DisplayActive=Enabled PerformanceState=P8`. Repeated `SuspendRequestSent` activity began at `+67.950408s` and continued through wake. This was later than in `test4`, but one timing difference without physical success is not evidence of a useful mechanism.

Conclusion: retaining an adapter-matched D3D11 context and periodically submitting a small buffer update/flush does not correct the display-output power transition. Increasing artificial GPU load would raise power consumption without a strong causal basis, so this branch is closed. The remaining user-mode active-path experiment is a real temporary transition to another enumerated display mode.

### 2026-07-10: First ModeTransition run invalidated

The user observed the same black backlight during `screenshot/test7`, but the run did not actually retain the requested `3440x1440 @ 60Hz` mode. `ChangeDisplaySettingsEx` returned success and passed the immediate readback, then the old `CDS_FULLSCREEN` mode reverted before the capture started. The experiment status at `20:40:39` already reported 100Hz, and the before, off-plus-120s, and after-wake CCD snapshots all reported `99998/1000=99.998Hz`. NVIDIA remained `DisplayActive=Enabled`, with repeated `SuspendRequestSent` activity beginning near `+68s`, matching the bad native state.

This run is evidence that the previous experiment guard was insufficient, not evidence for or against a real mode transition. The bridge now uses a non-persistent dynamic apply (`dwFlags=0`), validates the selected mode with `CDS_TEST`, and samples the current mode every 500ms for five seconds. Any reversion aborts before the natural-sleep capture and restores the original mode.

### 2026-07-10: Active-path mode experiments closed after test8

`screenshot/test8` again physically showed the black backlight, but it also remained at the native `99998/1000=99.998Hz` in the experiment status and every CCD snapshot. The run reused the V1 bridge type already loaded in the same PowerShell process; replacing `ActivePathSleepExperiment.cs` cannot replace a .NET type in that process.

No additional rerun is justified. An earlier physical `3440x1440 @ 60Hz` DPMS test had already reproduced the fault, while the native-bad versus NVIDIA-CustomDisplay-good capture proves the meaningful difference is the driver's final output state: native mode remains `Display Active: Enabled`, while the saved NVIDIA custom mode reaches `Display Active: Disabled`. CRU had already proved that reproducing the exact 533.16MHz timing without the NVIDIA CustomDisplay state is insufficient.

Decision: close `LowPower`, `D3dKeepAlive`, and `ModeTransition`. Do not add more active-path, refresh-rate, GPU-load, or repeated-DPMS variants. The production topology workaround stays unchanged and supports configurations where at least one other active path remains. A single-display solution without DDC/CI requires either a second topology target or an optional vendor-specific backend; Windows exposes no generic user-mode physical-output power setter.

### 2026-07-10: CustomDisplay causality corrected

The fact that NVIDIA Control Panel CustomDisplay produces a good single-display state does not prove that NVIDIA fixed the problem in that mode, nor that the root cause belongs exclusively to the GPU driver. CustomDisplay is an intervention that changes an opaque state in the GPU-driver-DisplayPort-sink chain. Possible changed variables include mode provenance, link training, AUX/DPCD command order, VidPN or port caches, and C340 scaler behavior after signal removal. The existing ETW and CCD data cannot distinguish those variables.

The proposed delete/reset/reboot persistence matrix was cancelled as redundant. The user had already established the decisive transition: the NVIDIA custom-resolution record may remain saved, but switching the active mode to any native resolution or refresh rate immediately restores the powered black-backlight fault. The good state is therefore associated with the actively selected custom-mode path, not a persistent one-time reset caused by creating the record. This still does not assign ownership of the underlying compatibility defect to the driver or monitor firmware.

### 2026-07-10: User-mode DP observability audit completed

The native-bad and CustomDisplay-good captures were re-audited field by field in `diagnostics/NATIVE-CUSTOMDISPLAY-DIFF.md`. The strongest difference remains NVIDIA's reported state at the 120-second marker: native is `Display Active: Enabled`, CustomDisplay is `Disabled`. Hardware, boot, driver, topology, P8, display attachment, and application power requests are controlled. The filtered ETW traces contain 10 versus 9 D0/Suspend/D3 groups, but neither contains `DevicePoweredOn` or `DevicePreparation`, so the one-cycle difference is not causal evidence.

Microsoft's documented user-mode structures expose connector type, target timing, topology, wire color depth, and color space. They do not expose negotiated DP link rate/lane count, DPCD sink power/link registers, AUX ordering, or link-training history. WDDM defines both nonintrusive link diagnostics and raw AUX/DPCD transactions, but explicitly behind kernel display interfaces queried from the miniport driver. `dispdiag` saves an opaque file without a documented extraction schema for these fields.

Decision: do not add another user-mode collector. Further causal work requires IHV diagnostics, a DP protocol analyzer, or a signed kernel diagnostic component. None belongs in the production script runtime; the validated multi-path workaround remains unchanged.

### 2026-07-11: DP probe v1 rejected; monitor-child v2 interface gate passed

The signed x64 KMDF package built and installed successfully on the affected Windows machine with test signing enabled. The v1 `list` gate opened all four `GUID_DISPLAY_DEVICE_ARRIVAL` targets, including NVIDIA (`VEN_10DE&DEV_2482`), but every `GUID_DXGK_DP_INTERFACE` query returned:

```text
open=0x00000000 dpInterface=0xC00000BB caps=0xC00000BB
```

`0xC00000BB` is `STATUS_NOT_SUPPORTED`. This rules out signing, device start, controller access, and target-open failures. It also exposed a design error: the v1 probe queried adapter-arrival interfaces, while `DXGK_DP_INTERFACE` is returned by the display miniport's `DxgkDdiQueryInterface` in the context of a display child device. WDDM 2.7 availability does not mean an arbitrary adapter-stack PnP query is equivalent to that DDI contract.

Version 2 now enumerates `GUID_DEVINTERFACE_MONITOR` instead. Windows registers one such interface for each configured monitor, and each monitor node is a child of the display adapter. Sending the same read-only remote `IRP_MN_QUERY_INTERFACE` through the monitor stack gives `Dxgkrnl` the child identity it needs when forwarding the query to the miniport. The root probe remains independent and does not attach as a filter. The wire structure version was bumped to 2, CLI terminology changed from `adapter` to `monitor`, and `--adapter` remains an undocumented compatibility alias.

The rebuilt v2 package replaced the v1 root device successfully. Its `list` result on the single-display C340 configuration was:

```text
monitorInterfaces=1 returned=1
monitor=0 open=0x00000000 dpInterface=0x00000000 caps=0x00000000 rootPorts=3 dp=1.4
  path=\??\DISPLAY#HKCB34C#5&239bc59c&0&UID4357#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}
interfaceGate=PASS safeToRunRead=true
```

This proves that the monitor-child route reaches NVIDIA's public DP interface and correctly identifies the C340 target without a display filter driver. The next gate is one awake-state snapshot for `TargetId=4357`, `MonitorIndex=0`; no display-off capture should run until that snapshot returns coherent DP address and DPCD results.

The first v2 awake snapshot is invalid. The process returned exit code `0`, but its entire redirected UTF-16 output was only `000` (12 bytes including BOM and CRLF); the subsequent `list` gate still passed. Source review found that the METHOD_BUFFERED read IOCTL retrieved input and output views and then zeroed the output before preserving the input. Because METHOD_BUFFERED can use the same system buffer for both views, this could overwrite the requested monitor, target, DPCD address, and length before the callback calls. No returned bytes from that run may be treated as DPCD evidence.

Version 3 copies the complete validated input structure to a local stack value before clearing output, echoes all request identity fields in the response, and makes the controller reject any echo mismatch. It also flushes explicit before/after IOCTL stage markers. The wire version and package version were bumped so a mixed v2/v3 installation fails closed. A rebuilt v3 `list` gate and awake snapshot are required; display-off capture remains prohibited.

The rebuilt v3 interface gate passed, but its snapshot again emitted exactly `000` and exited `0`. Because v3 rejects a request-identity echo mismatch, the remaining failure is in user-mode presentation rather than the buffered IOCTL contract. The three visible zeros match the timestamp's first `setw(4)` field: `SYSTEMTIME` members are `WORD` (`unsigned short`), and this WDK application toolset can make `wchar_t` compatible with that type. The wide stream then treats the year as one character, writes three padding zeros, fails while converting that non-ASCII code point for the redirected stream, and suppresses all subsequent output.

Controller revision 2 explicitly casts every `SYSTEMTIME` field to `ULONG`, checks stream health before the first read, and identifies itself in `list` output. This is controller-only; after rebuilding, only `TopologyDpProbeCtl.exe` needs replacement on the affected machine. The already loaded protocol-v3 driver does not need reinstalling for this presentation fix.

Controller revision 2 produced the first valid awake DPCD snapshot. All four requests preserved and echoed `MonitorIndex=0` and `TargetId=4357`; interface, capability, address, and AUX statuses were all `STATUS_SUCCESS`. `GetDPAddress` resolved the C340 to NVIDIA `RootPortIndex=2`, `NumLinks=0`, proving a direct non-MST connection suitable for native AUX reads.

The awake baseline was:

```text
0x000: 12 14 84 00 01 00 01 40 02 00 06 00 00 00 00 00
0x100: 14 84 00 01 01 01 01 00 01 00 00 00 00 00 00 00
0x200: 41 00 77 77 01 03 11 11
0x600: 01
```

The sink advertises DPCD revision 1.2, HBR2 (`0x14`, 5.4 Gbit/s per lane), four lanes with enhanced framing (`0x84`), while the GPU/driver capability query reports DP 1.4. Current link configuration is HBR2/four lanes; all four lane-status nibbles report clock recovery, channel equalization, and symbol lock, interlane alignment is complete, and sink power state is D0 (`0x600=01`). This is coherent link evidence. The next gate is one controlled 120-second native-bad display-off capture; the post-off read remains an observation side effect and must occur only after the full observation interval.

The controlled 120-second native-bad capture completed and the user physically observed the powered black backlight. No probe request occurred during the observation interval. Before/after DPCD differences were narrowly scoped:

```text
0x108 MAIN_LINK_CHANNEL_CODING_SET: 01 -> 00
0x204 LANE_ALIGN_STATUS_UPDATED:    01 -> 81
0x600 SET_POWER:                    01 -> 01
0x202/0x203 lane status:            77 77 -> 77 77
```

Receiver capabilities and all other captured bytes were stable. `0x204=81` retains interlane alignment while adding the link-status-updated bit. All four lanes still report clock recovery, channel equalization, and symbol lock. Most importantly, the sink still reports D0 at `0x600=01`; it did not report D3 (`02`) at the observation marker. This provides a concrete DP-level description of the black-backlight state: the main-link coding control changed and status was marked updated, but the directly attached sink remained powered and the trained-link status remained present.

The post-off snapshot is still an observation side effect: interface/caps/address queries and the first AUX read can cause the miniport to service hardware. The next experiment must therefore use the exact same probe order on the known-good active NVIDIA CustomDisplay mode before changing any collector behavior. Only that controlled A/B can determine whether the good state returns D3, a powered-off/not-connected AUX error, loss of lane lock, or the same observable registers after probe servicing.

The same-order 120-second CustomDisplay-good capture completed and the user confirmed that the backlight physically turned off. Unlike the native-bad state, the good post-off snapshot reported:

```text
0x100 LINK_BW_SET:                 14 -> 06
0x108 MAIN_LINK_CHANNEL_CODING:   00 -> 00
0x202/0x203 lane status:          77 77 -> 00 00
0x204 LANE_ALIGN_STATUS_UPDATED:  01 -> 80
0x600 SET_POWER:                  01 -> 02
```

The controlled A/B discriminator is therefore decisive:

```text
native bad after off: HBR2, lanes locked/aligned, sink D0, black backlight
CustomDisplay good:   link status down/unlocked, sink D3, backlight off
```

The pre-off snapshots also contain a mode-associated difference at `0x108`: native began at `01`, while CustomDisplay began at `00`, despite both using HBR2/four lanes and reporting full lane lock. The meaning of that stale/selected coding value in NVIDIA's state machine is not yet proven, but the final physical failure is no longer ambiguous: the native path does not complete the standard sink D3 and link-down transition.

The next implementation branch is a narrowly constrained standard-DPCD power experiment, not a general AUX writer. Protocol v4 may expose only address `0x600`, one byte, values D0 (`01`) and D3 (`02`), only after `GetDPAddress` proves a direct non-MST target and root-port bounds pass. The first write gate must be an awake D0-to-D0 request; if the miniport rejects public AUX writes, stop without attempting D3. A D3 test requires independent recovery and must remain diagnostic until repeated sleep/wake validation succeeds.

The v4 awake D0-to-D0 gate was rejected without changing the display:

```text
read 0x600 before: data=01
write status:      0xC000000D (STATUS_INVALID_PARAMETER)
native error:      0xC0000022 (STATUS_ACCESS_DENIED)
bytesDone:         0
controller exit:   3
```

Open, interface, capability, and direct-address resolution all succeeded, so the rejection is specifically at `DxgkDdiDPAuxIoTransmission` with `Write=1`. This NVIDIA miniport exposes native AUX reads through `DXGK_DP_INTERFACE` but blocks native AUX writes, matching the documented access-denied boundary. Do not try D3 and do not vary address, size, or payload to bypass that policy.

The direct standard-DPCD repair branch is closed on this stack. Source now accepts only the harmless D0 capability gate and rejects D3 in kernel and controller code; a future protocol can reconsider D3 only on different hardware that first completes D0 with `bytesDone=1` and has an independent recovery watchdog. Remaining software routes must either induce the miniport's own valid D3/link-down transition or use a vendor/private hardware control path; the public DP interface cannot inject it.

The vendor-neutral implementation branch therefore returns to the optional IDD anchor. The existing one-monitor `anchor-driver` remains isolated from the production listener, but its phase-one engineering is now complete: deterministic `out\<platform>` packaging, explicit test-certificate trust, Driver Store install/removal helpers, and a one-command availability test. That test does not call `SetDisplayConfig`; it records baseline physical active targets, requires exactly one available `outputTech=16` anchor while the controller runs, withdraws the software device, and verifies the physical active-target set is restored. No sleep/topology experiment is allowed until this lifecycle gate passes on the affected Windows machine.

### 2026-07-11: D3 retention boundary and public CCD supplied-mode gate

One-shot protocol-v4 captures established the physical transition boundary on NVIDIA 610.62 native mode. At 3 and 10 seconds after `SC_MONITORPOWER`, C340 reported `SET_POWER=02` with lane status `00 00`; by 30 seconds it had returned to `SET_POWER=01`, HBR2 `14`, and trained lanes `77 77`. NVIDIA CustomDisplay on 610.62 and native mode on 537.58 both retained D3/link-down through 30 and 120 seconds. Natural-sleep capture on 537.58 confirmed the same result without a scripted power request and without a hidden CustomDisplay record.

The 610.62 G-SYNC/VRR-disabled control (`screenshot/test13`) still reported D0, HBR2, and trained lanes after 30 seconds. VRR is therefore not the trigger and no longer belongs in the test matrix.

Added `diagnostics/SuppliedModeExperiment.cs` and `diagnostics/test-displayconfig-supplied-mode.ps1` for one final documented Windows CCD distinction. Unlike the rejected exact-current-mode reapply, this test retains the sole path but replaces its target timing for the current session with exact `533160000 / 148100 / 100.000Hz`. It deliberately does not claim that timing is causal: CRU already disproved that. The test asks whether direct nonpersistent CCD supplied-mode submission itself causes a different miniport mode classification.

The gate requires one matching path, coherent timing arithmetic, successful `SDC_VALIDATE`, exact post-apply readback, interactive visibility confirmation, and a passing DP-probe interface check. It never uses `SDC_SAVE_TO_DATABASE`. An external `DisplaySwitch /extend` watchdog is armed before apply, original unmodified arrays are captured separately, and `finally` restores them after the 30-second DPCD capture. Validation error, driver coercion, or a post-off D0 result closes this branch without production integration.

Strict validation on NVIDIA 610.62 returned `1610 (ERROR_BAD_CONFIGURATION)` and applied nothing. Microsoft documents this as best-mode logic being unable to solve the supplied configuration without adjusting path or mode information. Added an explicit, default-off `-AllowChanges` gate for the documented `SDC_ALLOW_CHANGES` follow-up. This does not relax the experiment's result criterion: apply must still query back exact `533160000 / 100.000Hz`, otherwise it restores immediately and never requests display-off.

The `SDC_ALLOW_CHANGES` validation returned `validationErr=0` with flags `0x00000460`, but the full apply did not retain the supplied timing. Immediate readback remained native `pixelRate=533150000`, `hSync=533150000/3600`, and `vSync=99998/1000`; source mode, active/total dimensions, target ID, and path were unchanged. The script aborted before DPMS, cancelled the external watchdog, and restored the original arrays with `applyErr=0`. No DPCD capture was created. This closes public CCD supplied timing: without adjustment the request is unsolvable, and with adjustment the NVIDIA miniport selects the existing native mode.

### 2026-07-11: synchronized ETW and physical D3 boundary capture

The original NVIDIA 610.62 native-bad and CustomDisplay-good ETW traces were aligned to their `ConsoleDisplayState=0` timestamps. Both contain a D0 request at approximately `+19.44s`, followed by several D0/Suspend/D3 cycles. Native bad has one additional cycle, but CustomDisplay remains physically D3 despite its own cycles. The 537.58 native-good capture contains substantially more high-level D0/D3 traffic while the sink remains physically D3 through 120 seconds. A filtered DxgKrnl D0 request is therefore not equivalent to the miniport propagating D0 to DPCD `0x600`, and PID suppression cannot be justified from existing logs.

Extended `capture-natural-display-sleep.ps1` with an optional, default-off synchronized DPCD mode. It is restricted to explicit `DisplayPowerTrigger=Off`, gates the read-only DP interface before capture, takes one snapshot immediately before the off request and one at the observation marker, and makes no AUX calls during the wait. The marker DPCD read occurs before all WMI/NVIDIA/DisplayConfig snapshots. Full ETW CSV and a process inventory are retained for correlation. Added `capture-d3-retention-transition.ps1` as a constrained entry point; the first boundary is 20 seconds, followed by either 15 or 25 seconds based on the physical result.

The first synchronized 20-second run (`screenshot/test14`) was valid. Before off, C340 reported D0, HBR2, and trained lanes `77 77`. At the marker it reported D3 (`0x600=02`) and lanes `00 00`; NVIDIA simultaneously reported `Display Active: Disabled`, while the native `99.998Hz` DisplayConfig path remained active. All 55 `IrpRequestSentD0` events before the marker used PID `1976` (`dwm.exe`) and were followed by D3 requests, proving this traffic is routine and does not force physical D0. VidPN events began after the marker DPCD/system collectors and are observation effects. This reduced the physical transition boundary to 20-30 seconds and selected 25 seconds for the second run.

The 25-second native run (`screenshot/test15`) captured the failure transition. The post-off DPCD controller began at the marker but returned exit code `3` before its first range result; immediately afterward NVIDIA reported `Display Active: Enabled`. Crucially, the triggering ETW sequence preceded the marker. `DpiFdoMessageInterruptRoutine` ran at `+24.416s`; `VidMmWakeReason_StatusChangeEvent` followed at `+24.419870s`; a target query returned target `4357`; DMM reported `DMM_CT_UNINITIALIZED / DMM_CVR_UNINITIALIZED`; and System called `DdiSetTimingsFromVidPn` at `+24.420739s` and `DdiSetVidPnSourceVisibility` at `+24.422608s`. More than one thousand filtered VidPN events then rebuilt target and monitor modes. `NVDisplay.Container.exe` and DWM participated later, but the initial interrupt/status-change path was kernel/System and not caused by either process.

This sequence is consistent with the display miniport reporting a connector or child status change, potentially HPD-related, but ETW does not measure the physical HPD wire and cannot establish electrical origin. The old repeated-off test already proves that sending another `SC_MONITORPOWER` after the black state is not a repair. Native boundary timing was complete, so the same 25-second synchronized capture on the known-good NVIDIA CustomDisplay became the final controlled A/B described below.

The matching 25-second CustomDisplay-good run (`screenshot/test16`) completed with a nonempty CustomDisplay record, CCD `100/1`, and the expected physical off result. At the marker, the DPCD controller also returned exit code `3`, but NVIDIA still reported `Display Active: Disabled`. Exit code `3` at this boundary therefore means only that the sleeping target was not readable; it is not evidence of D0. The native run's simultaneous `Display Active: Enabled` remains the discriminator.

The decisive A/B result is that CustomDisplay does not remove the status-change sequence. Its initial chain occurred at essentially the same boundary: `DpiFdoMessageInterruptRoutine` at `+24.372s`, `VidMmWakeReason_StatusChangeEvent` at `+24.373051s`, the same `DMM_CT_UNINITIALIZED / DMM_CVR_UNINITIALIZED` record, `DdiSetTimingsFromVidPn` at `+24.373206s`, and `DdiSetVidPnSourceVisibility` at `+24.373688s`. It also invalidated monitor connections and rebuilt monitor modes while the physical display remained asleep.

The first actionable divergence occurs inside `DxgkInvalidateMonitorConnections`. Native bad entered `WakeUpAdapter` at `+24.429275s`, emitted `IrpRequestSentD0`, then began `VidMmOpRestoreSegments` and 40 `DdiBuildPagingBuffer` calls. The aligned CustomDisplay-good path completed connection invalidation without `WakeUpAdapter`, adapter D0, segment restore, or paging-buffer rebuild. Both paths then continued through monitor-mode recommendation and scheduler transitions. This places the unwanted physical D0 propagation in the adapter/miniport recovery decision made after the common status-change and VidPN sequence.

The status notification itself, a possible HPD event, DWM, and `NVDisplay.Container.exe` are rejected as standalone causes: the known-good CustomDisplay path contains the same kernel-originated notification and target rebuild. Suppressing connector invalidation would also suppress behavior required by the good path and is not a justified repair. Public ETW exposes the recovery branch but not the NVIDIA-private mode classification or condition that selects it. No further boundary-timing run is warranted; the next meaningful research would require observing or controlling that private miniport decision, not another DPMS/topology variant.
