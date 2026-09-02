# Validation

Last updated: 2026-09-02

## NVIDIA 616.56 Native Fix Validation

The original affected HKC C340 / RTX 3070 Ti DisplayPort system was retested after updating from NVIDIA `610.88` (R610) to `616.56` (R615).

Controlled result:

| Driver | Physical displays | Active mode | NVIDIA CustomDisplay | Workaround | Result |
| --- | --- | --- | --- | --- | --- |
| `610.88` | C340 only | Native | Absent | Stopped | Powered black backlight after display-off |
| `610.88` | C340 + H249W | Native | Absent | Stopped | Powered black backlight after display-off |
| `616.56` | C340 only | Native | Absent | Stopped | Normal native sleep |
| `616.56` | C340 + H249W | Native | Absent | Stopped | Both displays sleep normally |

This validates a driver-version boundary rather than a workaround effect. `610.88` and `616.56` are consecutive public GeForce WHQL releases, so `616.56` is the first confirmed public fix on this hardware. No topology removal, DDC/CI power command, custom resolution, virtual display, or experimental driver was involved in the successful result.

NVIDIA's public `616.56` release notes do not name this issue. They state that the listed fixes are only a subset of all changes, so the responsible display-miniport or DisplayPort power-management change is undocumented. The exact internal fix must not be represented as known. Existing pre-fix evidence still places the failure at the native recovery branch that entered `WakeUpAdapter`, propagated D0 to the sink, and retrained the link after display-off. A post-fix DPCD/ETW capture would be needed to prove how `616.56` changed that branch, but it is not required to establish the functional fix.

Runtime status:

- Prefer native Windows display sleep on the confirmed `616.56` system.
- Do not install the workaround unless the powered black-backlight fault is reproducible.
- Retain the runtime and diagnostics for older affected drivers and future regressions.
- Treat `616.56` as the known-good reference point; test later releases independently.

## Current Runtime

The generic runtime consists of:

- `topology-ddcci-core.ps1`
- `topology-ddcci-workaround.ps1`
- `install-topology-ddcci-workaround-task.ps1`
- `start-topology-ddcci-hidden.vbs`
- `uninstall-topology-ddcci-workaround-task.ps1`

Runtime behavior is selected explicitly by target matching criteria. No C340 or H249W identifier is hardcoded.

## Confirmed Root Behavior

Validated hardware:

- Problem display: HKC C340, NVIDIA RTX 3070 Ti DisplayPort, 3440x1440 at 100 Hz.
- Remaining display: HKC H249W, Intel UHD 730 HDMI, 1920x1080 at 60 Hz.

Direct topology test confirmed on 2026-07-10:

1. `SetDisplayConfig + SDC_SAVE_TO_DATABASE` removed the C340 path successfully.
2. With no global DPMS command, C340 entered no-signal true sleep.
3. The reduced topology stayed stable for the full 180-second observation.
4. Every 15-second marker reported one active path containing only H249W.
5. NVIDIA remained enabled and `nvidia-smi` remained available.
6. The captured dual-display topology and original H249W position were restored successfully.

Installed natural power-event test confirmed on 2026-07-10 in `display-topology-ddcci-20260710-125854.log`:

1. The listener started with `TriggerMode=PowerEvent` and `RemainingDisplayPowerMode=Disabled`.
2. Target preflight found two active paths, one target match, and one path to keep.
3. The Windows power plan naturally reported `ConsoleDisplayState=0` at `13:00:46`.
4. C340 was removed successfully with `SDC_SAVE_TO_DATABASE`; H249W remained the only active path.
5. The log explicitly confirmed that remaining-display DDC/CI power-off was disabled.
6. The user confirmed that both C340 and H249W physically slept correctly.
7. On `ConsoleDisplayState=1`, the exact two-display topology and original H249W position were restored on the first attempt.

The combined evidence is:

```text
natural Windows power-plan sleep + PowerEvent removal: both displays sleep without DDC/CI
scripted SC_MONITORPOWER + later target removal: C340 can retain black backlight
target removal without DPMS: C340 sleeps while the remaining display stays lit
```

The scripted `SC_MONITORPOWER` test is therefore not a reliable substitute for the Windows power plan's natural transition on this hardware. The default runtime is now `PowerEvent`, which preserves native sleep for healthy displays and does not require DDC/CI. `IdlePreempt` remains an explicit fallback when the target must be removed before DPMS.

## Rejected Or Limited Approaches

- EDID/CRU or NVIDIA custom-resolution-only fixes in dual-display mode.
- Direct C340 DDC/CI `VCP D6` power-off; the monitor accepted the call but did not physically sleep.
- Scripted or repeated `SC_MONITORPOWER` as a substitute for natural power-plan validation.
- Disabling the monitor PnP device or only the secondary adapter/display.
- Disabling the NVIDIA adapter as a final solution because it disrupts GPU workloads.
- Temporary topology removal without `SDC_SAVE_TO_DATABASE`, because Windows/driver restored the path.
- `IdlePreempt + Disabled` as a complete multi-display sleep solution, because its display-required execution state also keeps remaining displays awake.

## New Runtime Safety

- Target criteria are checked against active DisplayConfig paths before listener startup.
- The literal documentation placeholder `YOUR_MONITOR_ID` is rejected.
- `IdlePreempt` and `PowerEvent` are separate trigger modes.
- `TriggerDpmsAfterSeconds` is rejected in `IdlePreempt` mode.
- Normal runs still refuse to remove every active display path.
- The single-display experiment is restricted to `IdlePreempt + TestOnce`, explicit idle/automatic recovery timeouts, and DDC/CI disabled.
- An independent `DisplaySwitch.exe /extend` watchdog is armed before attempting a zero-active-path configuration.
- A current-user `RunOnce` fallback covers a reboot during the zero-path experiment.
- The scheduled-task installer cannot enable the zero-path experiment.

## Single-Display Result

The experimental test was run on 2026-07-10 with exactly one active C340 path:

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

Observed in `display-topology-ddcci-20260710-132510.log`:

- Preflight correctly reported `activePaths=1`, `matchedPaths=1`, and `keptPaths=0`.
- The emergency watchdog was armed before the API request.
- `SetDisplayConfig` rejected validation of zero active paths with Win32 error `87 (ERROR_INVALID_PARAMETER)`.
- No topology removal was applied; the C340 path remained active.
- The watchdog was cancelled after the safe validation failure.
- A `TestOnce` timer bug retried the same validation 19 times before exit. The runtime now marks the test complete and stops all listener timers after the first success or failure.

Zero-active-path single-display mode is not supported by this Windows/GPU stack. The next implementation direction is an optional active virtual-display anchor, preferably backed by an Indirect Display Driver. Do not expose single-display installation until an anchor-based design has passed repeated Windows tests.

## Root-Cause Investigation Boundary

NVIDIA custom resolution is a proven single-display workaround but is not accepted as a production dependency. It is now treated only as an A/B probe.

Current evidence:

- 537.58 / R535 is the last user-confirmed driver without the native single-display failure.
- The regression appeared after the transition to later NVIDIA drivers; 545.84 was the first public R545 GeForce release after 537.58.
- Current-driver native mode reproduces the powered black-backlight state.
- Current-driver NVIDIA CustomDisplay mode with the same effective 533.16 MHz / 100.000 Hz timing sleeps correctly in a true single-display setup.
- CRU/EDID timing alone does not reproduce the CustomDisplay fix.
- Earlier failing-state ETW showed unsolicited D3/D0 transitions and `DevicePoweredOn` roughly 24 to 32 seconds after display-off.

Controlled natural-sleep A/B captures completed on 2026-07-10:

- Native bad: `20260710-142806-current-native-bad`.
- NVIDIA CustomDisplay good: `20260710-143319-current-custom-good`.
- Both used the same NVIDIA driver (`32.0.16.1062`), the same single C340 DisplayPort target, a 120-second post-off observation, and completed automatic wake capture.
- Both received `ConsoleDisplayState=0`; both retained one active C340 DisplayConfig path throughout the observation.
- Native mode stayed at `99.998000 Hz`; NVIDIA reported `Display Active: Enabled` before sleep, after 120 seconds of display-off, and after wake.
- CustomDisplay used `100.000000 Hz`; NVIDIA changed from `Display Active: Enabled` before sleep to `Disabled` after 120 seconds, then back to `Enabled` after wake.
- Both remained in P8. Power requests were empty, so neither P-State nor an application display request explains the difference.
- Native ETW contained 10 D0/Suspend/D3 cycles; CustomDisplay contained 9. Neither filtered natural-sleep trace contained `DevicePoweredOn` or `DevicePreparation`. The extra native cycle is a clue, not yet a proven cause.

The A/B result proves a state-path difference, not ownership of the defect. Creating and selecting CustomDisplay may change mode classification, link training, AUX/DPCD sequencing, cached VidPN state, or how the C340 scaler reacts to signal removal. Windows requests natural display-off in both modes, but native and CustomDisplay states end with different physical and reported output states. The responsible component and exact transition remain unproven.

The user has already tested the relevant transition: the saved custom-resolution record can remain present, but switching the active mode to any native resolution or refresh rate immediately restores the fault. The good state is therefore associated with the actively selected custom-mode path, not a persistent one-time state change caused by creating the record. Delete, driver-reset, and reboot persistence tests are redundant.

The completed audit in `diagnostics/NATIVE-CUSTOMDISPLAY-DIFF.md` found no additional causal discriminator in the existing user-mode artifacts. Documented CCD and DXGI APIs expose mode timing, topology, wire color depth, and color space, but not negotiated DP link rate, lane count, DPCD power/link registers, AUX transaction order, or training history. Microsoft exposes those details only through kernel display/miniport interfaces. No new user-mode collector is justified.

`diagnostics/capture-natural-display-sleep.ps1` captures this controlled natural-sleep A/B without changing topology, power-plan values, or issuing forced DPMS. It now defaults to a 120-second observation and emits a focused NVIDIA state summary plus a display-off-relative ETW timeline.

## Rejected Public-API Mode Reapply

`diagnostics/test-displayconfig-mode-reapply.ps1` tested two temporary single-display CCD strategies while the NVIDIA custom resolution was disabled:

1. `NoOptimization`: exact current paths and modes with `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_NO_OPTIMIZATION`.
2. `ForceModeEnumeration`: the same flags plus `SDC_FORCE_MODE_ENUMERATION`.

Results from `screenshot/test2`:

- Both strategies returned `validationErr=0` and `applyErr=0`.
- `NoOptimization` used flags `0x000001A0`; `ForceModeEnumeration` used `0x000011A0`.
- Before and after apply, the active mode stayed at `533150000 / 99.998Hz`.
- Both natural-sleep captures completed, but NVIDIA remained `Display Active: Enabled` at the 120-second marker.
- Both traces contained four D0/Suspend/D3 cycles around 20 seconds after display-off, matching the native bad-state pattern.
- All four captured NVIDIA `CustomDisplay` values were empty and had the known bad-state SHA-256 `84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652`.

Public exact-mode resubmission does not reproduce the CustomDisplay power path and must not be added to the production listener.

## Rejected NVAPI Native Commit Test

The isolated NVIDIA display-control diagnostic completed on 2026-07-10:

- `NvApiDisplayCommit.cs` binds the public R610 `NvAPI_DISP_GetDisplayConfig` and `NvAPI_DISP_SetDisplayConfig` interfaces through the installed `nvapi64.dll`.
- `test-nvapi-force-commit-vidpn.ps1` requires one matching physical path and one NVIDIA NVAPI target.
- The exact queried configuration is validated and applied with only `NV_FORCE_COMMIT_VIDPN (0x10)`.
- No custom timing, persistence flag, topology removal, DDC/CI, or scripted DPMS is used.
- Post-apply NVAPI and Windows CCD signatures equaled their pre-apply values before the natural-sleep capture started.

The query returned one path and one target at native `3440x1440 @ 99.998Hz`. Validation and apply both returned `0`, the apply flag was exactly `0x10`, and the image was visible after the commit. At the 120-second natural-off marker, however, NVIDIA still reported `Display Attached=Yes, Display Active=Enabled, P5`. ETW also recorded `DevicePoweredOn` at approximately `+90.337955s` after display-off and D3/D0 activity near `+114s`.

The NVAPI force-commit hypothesis is rejected. It is not integrated into production, and further NVIDIA-specific mode-submission flags are outside the generic-project direction. The production listener remains unchanged; the IDD branch remains isolated research rather than a runtime dependency.

## Active-Path Experiments Closed

`diagnostics/test-active-path-sleep-experiment.ps1` provides three isolated single-display strategies that do not remove the target path:

- `LowPower` was physically rejected by `test4`. State `1` was sent successfully, but `ConsoleDisplayState=0` arrived about 45 seconds later rather than as an immediate result. The black backlight returned, NVIDIA remained `Display Active=Enabled`, and dense `SuspendRequestSent` activity began about 21 seconds after the actual off event.
- `ModeTransition` did not produce a valid 60 Hz capture in `test7` or `test8`; both remained at `99.998Hz`. `test8` reused the V1 bridge type already loaded in the same PowerShell process. The branch is nevertheless closed rather than repeated because an earlier physical 60 Hz DPMS test already reproduced the black backlight, and ordinary mode changes do not reproduce the distinct NVIDIA CustomDisplay driver state.
- `D3dKeepAlive` was physically rejected by `test5`. It matched NVIDIA adapter LUID `00000000:00010309`, completed `254` pulses with no failure through the full natural-off capture, but the black backlight returned and NVIDIA remained `Display Active=Enabled`. Repeated `SuspendRequestSent` activity began near `+68s`.

All strategies require exactly one active path matching the supplied target criterion. The C# bridge ABI sizes are `pathInfo=72`, `modeInfo=64`, `sourceName=84`, `targetName=420`, and `DEVMODEW=220`. All three active-path strategies are closed and none is integrated into production. The production listener remains the validated multi-path topology workaround and continues to refuse removal of the final active path by default.

## Anchor Discovery

The 2026-07-10 `displayconfig-anchor-candidates-20260710-152642.log` result was definitive:

- `allPaths=172`, `activeTargets=1`, `candidateTargets=0`.
- C340 was the only `targetAvailable=True` target and was already active.
- Every inactive target was unavailable and non-forceable.

No existing target can be activated as a topology anchor through public CCD calls on this machine. `anchor-driver/` now contains an experimental one-monitor IDD derived from Microsoft's official sample. It is deliberately not connected to the production listener. Its first Windows acceptance gate is exactly one `ANCHOR` with `targetAvailable=True` and `outputTech=16`. Windows may initially mark a newly arrived target active; that state must be recorded before controlled activation/deactivation is implemented.

The phase-one harness is now complete in source. `build-anchor-driver.ps1` creates a consolidated `out\<platform>` package and exports its test certificate; install and uninstall remain explicit administrator operations. `test-anchor-availability.ps1` performs baseline, connected, and withdrawn inspections without calling `SetDisplayConfig`. It passes only when exactly one available indirect-wired anchor appears, then becomes unavailable after controller exit, with the active physical target set restored.

## DP Link Probe Interface Gate

The first signed `dp-link-probe` package built, installed, and started successfully on the affected machine. Its root control device enumerated four display-adapter arrival interfaces and opened every one, including the NVIDIA RTX 3070 Ti. All four DP interface requests returned `0xC00000BB (STATUS_NOT_SUPPORTED)` while `open` remained `0x00000000`.

The v1 adapter-interface route is rejected. No DPCD command was run. Version 2 enumerates `GUID_DEVINTERFACE_MONITOR`, because monitor nodes are children of display adapters and `Dxgkrnl` forwards child-stack `IRP_MN_QUERY_INTERFACE` requests to the miniport's `DxgkDdiQueryInterface`. The driver remains an independent root device and does not attach to any display stack.

The rebuilt v2 interface gate passed on the single-display C340 system. It enumerated exactly one monitor at `DISPLAY#HKCB34C`, opened it successfully, obtained `DXGK_DP_INTERFACE`, queried capabilities successfully, and reported three DP 1.4 root ports. Output ended with `interfaceGate=PASS safeToRunRead=true`. No filter driver, topology change, or DPCD request was involved.

The next allowed operation is one awake-state read-only snapshot for monitor index `0` and current DisplayConfig target ID `4357`. Display-off capture remains unvalidated.

The first v2 awake snapshot did not produce valid evidence. It exited with code `0` but emitted only UTF-16 text `000`; the interface-only `list` command continued to pass. Review identified an unsafe METHOD_BUFFERED input/output alias: the driver cleared the output view before copying the input fields. Version 3 preserves validated input in a local value first, echoes the request identity in its response, rejects mismatches in the controller, and emits flushed IOCTL stage markers. No v2 snapshot result is accepted. The v3 package still requires Windows build and awake-state validation before any display-off test.

The rebuilt v3 snapshot also emitted only `000` with exit code `0`, while its interface gate passed. Since the v3 controller would return failure on an IOCTL request-echo mismatch, source review isolated a separate output bug: the wide stream can treat `SYSTEMTIME`'s `WORD` year as a wide character under the WDK application toolset. `setw(4)` emits three padding zeros, conversion of the year code point fails, and the failed stream discards later output. Controller revision 2 casts all timestamp fields to `ULONG`, checks stream state before any DPCD call, and prints its revision. This controller-only rebuild remains pending Windows validation.

Controller revision 2 passed the awake snapshot gate. Every query returned `open/interface/caps/address/aux=0`, with exact request echoes and expected byte counts. The C340 resolved to NVIDIA root port `2` with `numLinks=0`, so it is directly attached rather than behind MST. Receiver capability reported DPCD 1.2, HBR2, four lanes and enhanced framing; active link configuration matched HBR2/four lanes, all lane status bits were locked/aligned, and DPCD `0x600` reported D0 (`01`). Awake native AUX evidence is now validated. Display-off evidence is still pending.

The first controlled 120-second display-off capture physically reproduced the native-mode black backlight. At the post-off marker all AUX reads still succeeded. DPCD `0x108` changed from `01` to `00`, and link status `0x204` changed from `01` to `81`; lane status remained `77 77`, receiver capabilities were unchanged, and `0x600` remained D0 (`01`). Thus the failing state retains a powered sink and trained/aligned lane status while changing main-link coding control and marking link status updated. A same-order CustomDisplay-good capture is required before this can be treated as a causal discriminator rather than a bad-state description.

The matching CustomDisplay-good capture physically turned off the backlight and produced the opposite DP state. `0x600` changed from D0 (`01`) to D3 (`02`), `LINK_BW_SET` changed from HBR2 (`14`) to RBR (`06`), lane status changed from `77 77` to `00 00`, and `0x204` changed from aligned `01` to updated/not-aligned `80`. The native-bad versus CustomDisplay-good distinction is now validated at the sink/link level: bad retains D0 plus a trained HBR2 link; good reaches D3 plus link-down status.

An isolated protocol-v4 write experiment is justified, but arbitrary DPCD writes are not. The only candidate write is the standard one-byte `SET_POWER` register at `0x600`, restricted to D0/D3 and direct non-MST targets. It must first prove that an awake D0-to-D0 write is accepted before any guarded D3 experiment.

The protocol-v4 D0 gate failed safely. An immediate read confirmed `0x600=01`; the idempotent D0 write then returned `STATUS_INVALID_PARAMETER (0xC000000D)`, native `STATUS_ACCESS_DENIED (0xC0000022)`, `bytesDone=0`, and controller exit code `3`. All preceding target/interface/address checks succeeded. NVIDIA therefore permits public native AUX reads but denies native AUX writes on this stack. No D3 request was made. D3 is now disabled in source, and the direct DPCD-write repair route is rejected.

The 610.62 native-mode retention timing was isolated with one-shot DPCD captures: the sink reached D3 and lane-down state at 3 and 10 seconds, but had returned to D0 with a trained HBR2 link by 30 seconds. The same 610.62 system with active NVIDIA CustomDisplay and the 537.58 native system both retained D3 through 30 and 120 seconds. Disabling G-SYNC/VRR on 610.62 did not change the 30-second D0/HBR2 result, so that branch is rejected.

The exact public CCD supplied-mode diagnostic is rejected. `diagnostics/test-displayconfig-supplied-mode.ps1` attempted to submit `533160000 / 100.000Hz` while retaining the sole active path. Strict validation returned `1610 (ERROR_BAD_CONFIGURATION)` and applied nothing. Validation with explicit `SDC_ALLOW_CHANGES` returned success with flags `0x00000460`, but apply immediately queried back the unchanged native `533150000 / 99.998Hz` target timing. The exact-readback gate aborted before display-off, cancelled its watchdog, and restored the original arrays with `applyErr=0`; no DPCD capture ran. Public CCD cannot retain this non-enumerated target timing on the validated NVIDIA 610.62 stack.

The earlier aggregate ETW traces could not identify the physical D3-to-D0 trigger. After alignment to display-off, both 610.62 native-bad and CustomDisplay-good traces contain a similar D0 request near `+19.44s` and subsequent D0/D3 cycles. The 537.58 native-good trace contains substantially more high-level D0/D3 requests while the physical sink remains D3, proving those events are not direct sink-power evidence. The synchronized boundary runs below were required to isolate the later recovery branch.

`diagnostics/capture-d3-retention-transition.ps1` completed its synchronized 20-second and 25-second gates. It uses two read-only DPCD snapshots, makes no AUX calls during the wait, and places the marker DPCD read before all other state collectors. Production code and the DP probe driver remain unchanged.

The synchronized 20-second gate passed and remained physically off. DPCD `0x600` was D3 (`02`), lane status was `00 00`, NVIDIA reported `Display Active: Disabled`, and the native DisplayConfig path remained active. All 55 pre-marker D0 requests mapped to `dwm.exe` and were followed by D3 requests; they did not propagate physical D0. VidPN events appeared only after the marker DPCD/system collectors started and are observation effects. This selected 25 seconds as the second boundary.

The synchronized 25-second native run captured the failure onset before its marker probe. A display interrupt completed at `+24.416s`; `VidMmWakeReason_StatusChangeEvent` followed at `+24.4199s`, target `4357` was queried, DMM reported uninitialized connection/validation state, and System invoked `DdiSetTimingsFromVidPn` plus `DdiSetVidPnSourceVisibility`. A large VidPN and monitor-mode rebuild followed. At the marker, the DPCD controller returned exit code `3` before its first range result, while NVIDIA reported `Display Active: Enabled`; the native DisplayConfig path remained active. The trigger is a miniport/kernel status-change path, not the marker probe or a user process. Electrical HPD remains an inference, not a measured fact.

The identical 25-second CustomDisplay-good A/B (`test16`) remained physically off and reported `Display Active: Disabled`. Its marker DPCD read also exited with code `3`, proving that this code means the sleeping target was unreadable rather than proving D0. The same interrupt, status-change, uninitialized DMM target state, `DdiSetTimingsFromVidPn`, source-visibility update, connection invalidation, and monitor-mode rebuild all occurred at approximately `+24.37s`.

The paths diverged inside connection invalidation. Native bad called `WakeUpAdapter`, emitted `IrpRequestSentD0`, restored VidMm segments, and issued 40 paging-buffer builds; CustomDisplay good completed invalidation without that adapter recovery chain. The common status notification and VidPN rebuild are therefore not sufficient causes. The unwanted D0 is selected by a later adapter/miniport recovery decision whose private mode criterion is not exposed by public ETW. Repeated DPMS off, process suppression, status-event suppression, and additional boundary timing are rejected.

## Local Verification

This workspace is not the target Windows machine. Local checks completed on 2026-07-10:

- Every PowerShell file under `work/` passes the PowerShell 7.6.3 parser.
- The idle-control, DisplayConfig V2, DDC/CI, and NVAPI embedded C# blocks compile successfully.
- The NVAPI bridge can be compiled locally, but its `nvapi64.dll` calls and all physical display behavior require the target Windows machine.
- This Linux workspace has no Visual Studio/WDK toolchain, so the experimental IDD and its new phase-one harness still require their first Windows compile/load/lifecycle test.
- Windows Forms and actual Win32 display calls cannot be executed in this Linux workspace.
