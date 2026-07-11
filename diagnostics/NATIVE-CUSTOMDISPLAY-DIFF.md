# Native vs CustomDisplay Evidence Audit

## Scope

This report compares the completed single-display captures:

- Native bad: `screenshot/20260710-142806-current-native-bad`
- CustomDisplay good: `screenshot/20260710-143319-current-custom-good`

It separates observed facts from possible explanations. A good NVIDIA Control Panel custom mode is an intervention in the GPU-driver-DisplayPort-monitor chain; it does not by itself identify which component owns the defect.

## Confirmed Matrix

| Layer | Native bad | CustomDisplay good | Assessment |
| --- | --- | --- | --- |
| Physical topology | One C340 on NVIDIA DP | Same | Controlled |
| Windows | 11 build 28000 | Same boot and build | Controlled |
| NVIDIA adapter | RTX 3070 Ti | Same adapter and instance | Controlled |
| NVIDIA driver | `32.0.16.1062` | Same | Controlled |
| Monitor driver | Microsoft `monitor.inf` | Same | Controlled |
| Console display state | Off observed | Off observed | Windows initiated sleep in both |
| Active CCD paths | One C340 path throughout | One C340 path throughout | Same topology |
| Active size | 3440x1440 | 3440x1440 | Same |
| CCD refresh | `99998/1000` (99.998Hz) | `100/1` (100.000Hz) | Visible mode difference, not sufficient as a cause |
| GPU P-state at +120s | P8 | P8 | Same |
| GPU display attached at +120s | Yes | Yes | Same |
| GPU display active at +120s | **Enabled** | **Disabled** | Strongest observed difference |
| GPU power at +120s | 6.80W average | 6.19W average | Small consequence, not a proven cause |
| D0 / Suspend / D3 groups | 10 / 10 / 10 | 9 / 9 / 9 | One-cycle difference; insufficient evidence of causality |
| `DevicePoweredOn` / `DevicePreparation` | None in filtered trace | None in filtered trace | No discriminator in this pair |
| Application power requests | Empty | Empty | Controlled |
| Physical result | Powered black backlight | Remained asleep | Confirmed discriminator |

The user has additionally confirmed that keeping the saved custom-resolution record is not sufficient. Switching the active mode to any native resolution or refresh rate immediately restores the fault. The good state is tied to the actively selected CustomDisplay path, not a persistent one-time reset caused by creating the record.

Earlier CRU testing also reproduced the same effective `533.16MHz / 100.000Hz` timing without reproducing the good behavior. Pixel clock and refresh alone therefore do not explain the result.

## Synchronized 25-Second Boundary

The later synchronized `test15`/`test16` pair captured the first failing boundary without any AUX call during the waiting interval. Both native bad and CustomDisplay good received a kernel display interrupt at about `+24.4s`, followed by `VidMmWakeReason_StatusChangeEvent`, an uninitialized DMM target/validation state, `DdiSetTimingsFromVidPn`, `DdiSetVidPnSourceVisibility`, connection invalidation, and monitor-mode reconstruction.

The first material difference was inside `DxgkInvalidateMonitorConnections`. Native bad invoked `WakeUpAdapter`, emitted `IrpRequestSentD0`, restored VidMm segments, and built paging buffers. CustomDisplay good completed invalidation without that adapter recovery sequence and remained `Display Active: Disabled`. Its DPCD marker read was unavailable with controller exit code `3`, which is consistent with the target remaining deeply asleep; the same exit code is not a physical power-state measurement.

This rejects the common status notification as a sufficient cause. It also rejects DWM, NVIDIA Container, and the marker probe as the initiator. The remaining discriminator is a private adapter/miniport recovery decision made after the shared target rebuild. Public ETW shows which branch was selected but not the mode-classification field or condition that selected it.

## Still Unobserved After The Kernel Probe

The later read-only DP probe exposed negotiated HBR2/four-lane state, DPCD sink power, and lane status. It proved that native bad returns to D0 with a trained link while CustomDisplay good remains D3/link-down. The remaining unobserved values or sequences are:

- AUX read/write sequence during display-off;
- link-training attempts and their timing;
- main-link disable, blanking, and re-enable order;
- whether the custom path changes MSA, color transport, DSC, VRR, or another private mode attribute;
- the C340 scaler and backlight state independent of the GPU's report.

Any of these could explain why two modes with the same visible desktop geometry enter different physical power behavior.

## Public Interface Audit

### Available in user mode

Windows CCD exposes connector type, target availability, rotation, scaling, refresh, and mode indices through [`DISPLAYCONFIG_PATH_TARGET_INFO`](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_path_target_info). [`DISPLAYCONFIG_VIDEO_SIGNAL_INFO`](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_video_signal_info) adds pixel clock, horizontal/vertical sync, active size, total size, video standard, and scan-line ordering. Neither structure exposes DP link rate, lane count, DPCD state, or AUX traffic.

[`DXGI_OUTPUT_DESC1`](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_6/ns-dxgi1_6-dxgi_output_desc1) exposes desktop attachment, rotation, active wire-format bits per color, color space, primaries, and luminance data. It does not expose DP link negotiation or power registers.

[`DisplayConfigGetDeviceInfo`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-displayconfiggetdeviceinfo) provides names, preferred mode, adapter identity, advanced-color state, and related target metadata. Its documented request types do not include link rate, lane count, DPCD, or AUX history.

Power-setting GUIDs report OS-level state transitions. [`GUID_CONSOLE_DISPLAY_STATE`](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids) confirms that Windows considers the display off, but it does not report the physical DP sink or backlight state.

### Present only behind kernel display interfaces

WDDM defines a nonintrusive [`DXGK_DIAG_DISPLAY_LINK_STATE`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ne-dispmprt-dxgk_diag_display_link_state), including stable, failed, training, and repeated-training states. However, the containing [`DXGK_DISPLAY_DIAGNOSTICS_INTERFACE`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-dxgk_display_diagnostics_interface) is explicitly queried by a **kernel-mode component** from the display miniport driver.

WDDM also defines [`DXGK_DP_INTERFACE`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-dxgk_dp_interface) and [`DXGKARG_DPAUXIOTRANSMISSION`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-dxgkarg_dpauxiotransmission) for DPCD/AUX access. These are kernel display interfaces obtained through the miniport driver's `DxgkDdiQueryInterface`, not documented application APIs.

`dispdiag` can save an opaque diagnostics file, but Microsoft documents only its collection switches, not a supported schema or user-mode API for extracting those kernel link-state fields.

## Decision

Do not build another PowerShell/C# user-mode collector. It would re-collect timing, topology, color, and high-level power events that are already known while still missing the private miniport recovery decision.

Do not infer that NVIDIA alone owns the defect. The evidence supports an incompatibility in the active custom-versus-native DP power path, potentially spanning mode classification, the GPU driver, link sequencing, and C340 firmware.

The completed read-only kernel probe established the physical D3/D0 states and isolated `WakeUpAdapter` as the first recovery-branch discriminator. Public native AUX writes were denied by the NVIDIA miniport, and public ETW does not expose the mode-classification condition used by that branch. Further root-cause work therefore requires at least one of:

1. an IHV-supported driver diagnostic that exposes the display-link transition;
2. a DisplayPort protocol analyzer that captures AUX/DPCD and main-link behavior;
3. a vendor-aware kernel/display diagnostic capable of observing the miniport's private recovery decision, beyond the public read-only WDDM interfaces already tested.

None is justified as a production dependency for the current script project. The validated multi-path topology workaround remains unchanged. Generic single-display repair remains open at the protocol/driver/firmware level, but the documented user-mode script path is exhausted.
