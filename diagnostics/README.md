# Natural Display-Sleep Root-Cause Capture

This diagnostic compares NVIDIA/C340 natural display-sleep behavior. It does not run the topology workaround, change the power plan, or send scripted `SC_MONITORPOWER`.

## Capture Matrix

Run the first pair with the same current driver and the same single-monitor hardware state:

| Label | NVIDIA mode | Expected observation |
| --- | --- | --- |
| `current-native-bad` | NVIDIA custom resolution removed/disabled; EDID-native mode selected | C340 returns to powered black backlight |
| `current-custom-good` | Validated NVIDIA `3440x1440 @ 100.000Hz` custom mode selected | C340 remains truly asleep |

Only after this comparison is stable should driver A/B testing begin:

| Label | Driver branch | Mode | Expected observation |
| --- | --- | --- | --- |
| `r535-53758-native-good` | 537.58 / R535 | EDID-native | Normal sleep |
| `r545-first-bad-native` | First confirmed bad R545 driver | EDID-native | Powered black backlight |

Version 537.58 was an R535 release dated 2023-10-10. Version 545.84 moved to R545 one week later and included display-sleep-related fixes. This boundary is evidence, not proof, because public release notes list only a subset of internal changes:

- [NVIDIA 537.58 release notes](https://us.download.nvidia.com/Windows/537.58/537.58-win11-win10-release-notes.pdf)
- [NVIDIA 545.84 driver page](https://www.nvidia.com/Download/driverResults.aspx/212898/en-us/Guide/)

## Preparation

1. Physically disconnect every display cable except C340.
2. Stop the installed topology listener.
3. Configure a practical Windows display-off timeout; the script does not change it.
4. Close media players, presentation tools, and other applications that hold display power requests.
5. Run the diagnostic from an elevated PowerShell window.

```powershell
Stop-ScheduledTask -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
```

Verify that no listener remains:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*topology-ddcci-workaround.ps1*" } |
  Select-Object ProcessId,Name,CommandLine
```

## Current-Driver Pair

Native bad state:

```powershell
.\diagnostics\capture-natural-display-sleep.ps1 `
  -Label "current-native-bad" `
  -ObserveAfterDisplayOffSeconds 120
```

NVIDIA custom good state:

```powershell
.\diagnostics\capture-natural-display-sleep.ps1 `
  -Label "current-custom-good" `
  -ObserveAfterDisplayOffSeconds 120
```

Do not use the mouse or keyboard after starting a capture. The script waits for the Windows power plan's natural display-off transition, records 120 seconds, sends minimal mouse movement to wake the display, and captures post-wake state. The default observation window is now 120 seconds.

Record whether C340 showed no-signal first, when powered black backlight appeared, whether it stayed truly asleep for the full observation window, and whether automatic wake succeeded.

## Output

Captures and archives are written under:

```text
.\log\diagnostics\YYYYMMDD-HHMMSS-LABEL\
.\log\diagnostics\YYYYMMDD-HHMMSS-LABEL.zip
```

Key artifacts include `capture.log`, `result.txt`, the raw ETL, filtered `relevant-events.txt`, a display-off-relative `relevant-events-relative.txt`, DisplayConfig snapshots, `nvidia-display-state-summary.txt`, before/after `dispdiag`, the NVIDIA driver file version/hash, and matched CustomDisplay registry values.

If ETW startup fails, inspect `logman-start.txt`. `-SkipEtl` performs state-only capture, but that is insufficient for comparing driver power transitions.

## Interpretation

The current-driver A/B pair captured on 2026-07-10 contains a more direct difference than the ETW event counts:

| State | Before sleep | 120 seconds after natural display-off | After wake |
| --- | --- | --- | --- |
| Native bad | `Display Active: Enabled` | `Enabled` | `Enabled` |
| NVIDIA CustomDisplay good | `Display Active: Enabled` | `Disabled` | `Enabled` |

Both runs received `ConsoleDisplayState=0`, and both retained the C340 active DisplayConfig path. Windows therefore initiated natural display sleep, but the two states ended in different output-power states. CustomDisplay is an intervention in the GPU-driver-DisplayPort-sink chain; this A/B result alone does not identify whether the decisive behavior belongs to mode classification, the driver, link sequencing, or C340 firmware.

The user has already established the decisive transition behavior: keeping the saved custom-resolution record is insufficient. Switching away from the active custom mode to any native resolution or refresh rate immediately restores the powered black-backlight fault. Deleting/restarting persistence tests are therefore redundant and are not part of the test plan.

Continue comparing these ETW events:

- `SuspendRequestSent`
- `IrpRequestSentD3`
- `IrpRequestSentD0`
- `DevicePreparation`
- `DevicePoweredOn`

The native run contained one more D0/Suspend/D3 cycle than the CustomDisplay run. Neither natural-sleep trace contained a filtered `DevicePoweredOn` or `DevicePreparation` event. One pair is insufficient to claim that the extra cycle is causal.

The completed field-by-field comparison and public-interface audit are in [NATIVE-CUSTOMDISPLAY-DIFF.md](NATIVE-CUSTOMDISPLAY-DIFF.md). It concludes that the missing DP link-rate, lane-count, DPCD, AUX, and training data are not exposed by documented general-purpose user-mode APIs.

## Completed: Public CCD Mode Reapply

`test-displayconfig-mode-reapply.ps1` does not create an NVIDIA custom resolution. It reads the current single-display native mode, temporarily resubmits the exact same path and mode through Windows `SetDisplayConfig`, and then starts the natural-sleep capture.

Microsoft defines `SDC_NO_OPTIMIZATION` as forcing the mode change down to the driver for every active display. `SDC_FORCE_MODE_ENUMERATION` additionally gives the driver an opportunity to update the GDI mode list:

- [SetDisplayConfig function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setdisplayconfig)
- [SetDisplayConfig summary and scenarios](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/setdisplayconfig-summary-and-scenarios)

The experiment requires exactly one active path matching `TargetNeedle`, validates before applying, does not use `SDC_SAVE_TO_DATABASE`, restores the captured arrays in `finally`, and arms an independent `DisplaySwitch.exe /extend` recovery watchdog. Press Enter within 45 seconds after the image has returned; if the display remains blank, do not press anything.

First strategy:

```powershell
.\diagnostics\test-displayconfig-mode-reapply.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy NoOptimization
```

Second strategy:

```powershell
.\diagnostics\test-displayconfig-mode-reapply.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy ForceModeEnumeration
```

Both strategies completed on 2026-07-10 with successful validation and apply calls. Both retained the native `533150000 / 99.998Hz` mode, remained `Display Active: Enabled` 120 seconds after natural display-off, and showed four D0/Suspend/D3 cycles around 20 seconds after display-off. Their `CustomDisplay` values had the all-zero bad-state hash `84ff92691f909a05b224e1c56abb4864f01b4f8e3c854e4bb4c7baf1d3f6d652`.

Exact public CCD mode resubmission and forced mode enumeration therefore do not enter NVIDIA's internal CustomDisplay DPMS path. This strategy is rejected and is not integrated into the production runtime.

## Rejected: Exact CCD Supplied Timing

`test-displayconfig-supplied-mode.ps1` tests one narrower question that exact-mode reapply did not answer: can a new target timing supplied directly for the current session through documented Windows CCD APIs enter a different miniport mode path without NVIDIA CustomDisplay?

For the validated C340 case, the experiment keeps the current `3440x1440` active area, `3600x1481` totals, scan ordering, video standard, source mode, topology, and active path. It changes only the target signal from native `533150000 / 99.998Hz` to the internally consistent `533160000 / 148100Hz / 100.000Hz` timing. This is intentionally the same effective timing that CRU failed to repair; the variable under test is the direct, nonpersistent CCD supplied-mode submission path, not the timing numbers themselves.

Safety boundaries:

- Requires exactly one active path matching `TargetNeedle`.
- Runs `SDC_VALIDATE` before apply. Strict validation is the default; `-AllowChanges` explicitly enables the Microsoft-documented best-mode adjustment path.
- Applies with `SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_NO_OPTIMIZATION` only.
- Does not use `SDC_SAVE_TO_DATABASE`, write the registry, or create an NVIDIA CustomDisplay.
- Requires exact post-apply CCD readback. Driver coercion back to the native mode aborts the sleep test.
- Saves the original arrays before modification, restores them in `finally`, and arms an independent `DisplaySwitch.exe /extend` watchdog before apply.
- Runs the existing read-only DP probe for 30 seconds only after the user confirms that the image is visible.

The first strict validation on NVIDIA 610.62 returned `1610 (ERROR_BAD_CONFIGURATION)`, so no mode was applied. Microsoft documents this result as best-mode logic being unable to find a solution without changing supplied path or mode information. Validation with `SDC_ALLOW_CHANGES` then returned `validationErr=0` with flags `0x00000460`:

```powershell
.\diagnostics\test-displayconfig-supplied-mode.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -AllowChanges `
  -ValidateOnly
```

The controlled apply was then run with the same adjustment flag:

```powershell
.\diagnostics\test-displayconfig-supplied-mode.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -AllowChanges `
  -MonitorIndex 0 `
  -ObserveAfterDisplayOffSeconds 30
```

`SetDisplayConfig` accepted the adjusted apply request, but immediate `QueryDisplayConfig` readback was the unchanged native `533150000 / 99.998Hz` timing. The exact-readback gate aborted before display-off, cancelled the watchdog, and restored the original arrays successfully with `applyErr=0`. No DPCD sleep capture was run.

This closes the documented public CCD supplied-mode branch. Strict submission cannot be solved, while allowing changes causes the miniport to select the already-enumerated native target mode instead of retaining the requested timing. The script remains only as reproducible evidence and should not be integrated into production or rerun on the validated machine.

## Next: Synchronized D3-Retention Boundary

Existing ETW captures were realigned after the DP probe established that NVIDIA 610.62 native mode changes from physical D3/link-down at 10 seconds to D0/trained HBR2 by 30 seconds. Both native-bad and CustomDisplay-good captures contain a similar `IrpRequestSentD0` at approximately `+19.44s`, and both contain additional D0/D3 cycles. The 537.58 native-good trace contains many more high-level D0/D3 requests while its physical sink remains in D3. These events therefore do not directly represent physical sink power and cannot identify a process to suppress.

`capture-d3-retention-transition.ps1` adds synchronized physical evidence to the existing ETW harness. It requires an explicit `SC_MONITORPOWER Off` trigger and records:

- The existing full ETW provider set and expanded CSV.
- A process inventory for PID correlation.
- One DPCD snapshot immediately before display-off.
- No DPCD/AUX calls during the observation interval.
- One DPCD snapshot at the requested boundary before WMI, NVIDIA, or DisplayConfig marker snapshots.

The first run is 20 seconds:

```powershell
.\diagnostics\capture-d3-retention-transition.ps1 `
  -TargetId 4357 `
  -MonitorIndex 0 `
  -ObserveAfterDisplayOffSeconds 20 `
  -Label "61062-native-boundary-20s"
```

Use NVIDIA 610.62, one C340 active path, native `99.998Hz`, and no NVIDIA CustomDisplay. Stop the production listener and run from an elevated interactive PowerShell console. Do not provide input during the short capture. If the 20-second DPCD marker is D3, the next boundary is 25 seconds; if it is already D0, the next boundary is 15 seconds. Do not run either follow-up until the 20-second ETW/DPCD result has been reviewed.

The validated 20-second run remained physically off: `0x600=02`, lane status `00 00`, and NVIDIA `Display Active: Disabled`. DisplayConfig retained the native active path. All 55 pre-marker `IrpRequestSentD0` events were emitted by `dwm.exe` and followed by D3 requests, yet none propagated physical D0 by the marker. VidPN activity began only after the marker collectors ran and cannot be treated as the fault trigger. The transition boundary is now 20-30 seconds; the next single run is 25 seconds.

The 25-second native run captured the transition itself. At `+24.416s`, before the marker probe, DxgKrnl serviced a display interrupt; at `+24.4199s`, `VidMmWakeReason_StatusChangeEvent` started a target-4357 rebuild from `DMM_CT_UNINITIALIZED / DMM_CVR_UNINITIALIZED`. The System path immediately called `DdiSetTimingsFromVidPn` and `DdiSetVidPnSourceVisibility`, followed by a large VidPN/mode-enumeration sequence. At the marker, the DPCD snapshot could no longer complete and returned exit code `3`, while NVIDIA already reported `Display Active: Enabled`. This is not caused by the marker probe and is not initiated by a user process. It is consistent with, but does not electrically prove, a miniport-reported connector/child status change such as HPD handling.

Do not repeat native boundary tests or retry `SC_MONITORPOWER`; re-off was already rejected. The next controlled discriminator is the same 25-second synchronized capture on NVIDIA 610.62 with the known-good NVIDIA CustomDisplay mode active. If the status-change sequence is absent, the active mode changes the pre-interrupt link/sink behavior. If it is present while D3 is retained, the miniport handles the same status differently by mode classification.

## Rejected: NVIDIA Native CommitVidPn

`test-nvapi-force-commit-vidpn.ps1` tests NVIDIA's documented display-control path without creating a custom resolution, changing topology, or saving display configuration. It reads the exact current NVAPI configuration and resubmits it with `NV_FORCE_COMMIT_VIDPN (0x10)`, which NVIDIA defines as preventing optimization of the `CommitVidPn` call during a modeset.

The bridge is compiled in memory from `NvApiDisplayCommit.cs` and calls the installed `nvapi64.dll`; it does not require Visual Studio, WDK, a custom driver, or a bundled NVIDIA binary. The API constants and x64 structures were checked against the public NVIDIA R610 SDK. See `NVAPI-NOTICE.md`.

The 2026-07-10 `test3` run completed correctly but did not fix the black-backlight state:

- The query returned one path and one target with display ID `0x80061086`, native `3440x1440`, and `99.998Hz`.
- Validation and apply both returned `0`; apply flags were exactly `0x10`.
- NVAPI and Windows DisplayConfig signatures remained unchanged, and the user confirmed a visible image after the commit.
- At the 120-second natural display-off marker, NVIDIA still reported `Display Attached: Yes, Display Active: Enabled, P5`.
- ETW recorded `DevicePoweredOn` about 90.34 seconds after display-off, followed by D3/D0 activity.

This rejects the hypothesis that force-committing the unchanged native VidPN repairs the power transition. The script is retained only to reproduce the evidence and is not a production dependency or a recommended fix.

For reproduction, first run the read-only ABI/query check:

```powershell
.\diagnostics\test-nvapi-force-commit-vidpn.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -QueryOnly
```

Required query evidence includes one NVAPI path, one NVIDIA target, a nonzero `displayId`, the current source mode, and `refreshRate1K`. If this command fails, do not run the apply test.

Then run the isolated natural-sleep test:

```powershell
.\diagnostics\test-nvapi-force-commit-vidpn.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -ObserveAfterDisplayOffSeconds 120
```

Preparation is the same as the native-bad capture: connect only C340, disable/remove NVIDIA CustomDisplay, select the native `99.998Hz` mode, stop the topology listener, and use an elevated interactive PowerShell window. After the brief mode commit, press Enter only when the image is fully visible, then do not touch input until capture completes.

Safety boundaries:

- NVAPI first validates the queried configuration.
- Apply flags are exactly `NV_FORCE_COMMIT_VIDPN`; persistence and mode-enumeration flags are absent.
- Both NVAPI and Windows DisplayConfig signatures must remain unchanged after apply.
- A hidden watchdog runs `DisplaySwitch.exe /extend` if visibility is not confirmed.
- The existing capture waits for natural display-off; no scripted DPMS is sent.

The required success condition was `Display Active: Disabled` at the 120-second marker while the C340 DisplayConfig path remained active. The observed `Enabled` result means force-committing the native VidPN is insufficient. Do not integrate this strategy into the production listener or extend it with additional NVIDIA-specific submission flags.

## Next: Active-Path Sleep Experiments

`test-active-path-sleep-experiment.ps1` tests three mechanisms that keep the single physical display path active. It never removes a path, creates a virtual display, saves a display configuration, or calls an NVIDIA API. Stop the scheduled topology listener and test with only the problem display connected, with NVIDIA CustomDisplay disabled and the known bad native mode selected.

Run each command separately. Start with the read-only mode inventory:

```powershell
.\diagnostics\test-active-path-sleep-experiment.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy ListModes
```

### 1. Low-power system command

This sends `SC_MONITORPOWER` state `1` (`LowPower`) instead of the already rejected state `2` (`Off`). ETW and snapshots start first; the command is sent after five seconds, observed for 120 seconds, and then the script wakes the display.

```powershell
.\diagnostics\test-active-path-sleep-experiment.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy LowPower `
  -TriggerAfterSeconds 5 `
  -ObserveAfterDisplayOffSeconds 120
```

Rejected by the 2026-07-10 `test4` run. State `1` was sent at `20:11:21`, but `ConsoleDisplayState=0` did not arrive until about 45 seconds later, so LowPower did not initiate an immediate display-off transition. After the actual off event, the trace entered dense `SuspendRequestSent` activity at about `+21s`; the physical black backlight returned, and the observation snapshot still reported `Display Active: Enabled`. Do not repeat or integrate this strategy.

### 2. Real temporary mode transition

Choose a mode that appears in `ListModes` and differs from `CURRENT`. The example below is valid only if that exact mode was listed:

```powershell
.\diagnostics\test-active-path-sleep-experiment.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy ModeTransition `
  -TemporaryWidth 1920 `
  -TemporaryHeight 1080 `
  -TemporaryRefreshRate 60 `
  -ObserveAfterDisplayOffSeconds 120
```

The mode uses `ChangeDisplaySettingsEx` with a dynamic, non-persistent apply. It first validates the enumerated `DEVMODE` with `CDS_TEST`, then requires the requested mode to remain current for ten consecutive 500 ms samples. Confirm the picture with Enter only after that check succeeds, then stop using input and wait for the normal power-plan display timeout. The exact original mode is restored after wake or error. This differs from the rejected CCD test because it performs a real transition to a different enumerated mode instead of resubmitting the unchanged native mode.

### 3. Target-adapter D3D11 keep-alive

```powershell
.\diagnostics\test-active-path-sleep-experiment.ps1 `
  -TargetNeedle "DISPLAY#HKCB34C" `
  -Strategy D3dKeepAlive `
  -KeepAliveIntervalMilliseconds 1000 `
  -ObserveAfterDisplayOffSeconds 120
```

The bridge matches the target DisplayConfig adapter LUID to the same DXGI adapter. It creates one 256-byte D3D11 constant buffer and periodically updates and flushes it. It has no window, swap chain, present call, or `DISPLAY_REQUIRED` request. This tests whether a live WDDM graphics context prevents the faulty D3/D0 output-power cycle; it is not intended as a permanent power-efficient solution.

Rejected by the 2026-07-10 `test5` run. The D3D11 device matched the C340 NVIDIA adapter LUID `00000000:00010309`, completed `254` pulses with no failure, and remained active throughout natural display-off and the full 120-second observation. The black backlight still returned and NVIDIA remained `Display Active: Enabled`; repeated `SuspendRequestSent` activity began at about `+68s`. The later onset compared with another run is not enough to establish a useful effect. Do not increase GPU load or integrate this strategy.

The `test7` and `test8` captures are invalid as mode-transition results. In both runs the experiment status and all three CCD snapshots showed `3440x1440 @ 99.998Hz`, not the requested 60 Hz. `test8` reused the already-loaded V1 bridge type from the same PowerShell process, so replacing the C# source did not reload that type. A new PowerShell process would load the corrected bridge, but no further run is requested.

This branch is closed. The earlier physical 60 Hz DPMS test had already reproduced the black backlight, and changing among ordinary enumerated modes has no evidence of selecting the known-good NVIDIA CustomDisplay power path. `LowPower`, `D3dKeepAlive`, and `ModeTransition` must not be integrated into the production listener.

## Public API Boundary

The remaining documented Windows interfaces do not provide a general user-mode physical-output power setter for a normal desktop monitor:

- [`GUID_CONSOLE_DISPLAY_STATE` and `GUID_MONITOR_POWER_ON`](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids) report power-setting notifications.
- [`DisplaySource.Status`](https://learn.microsoft.com/en-us/uwp/api/windows.devices.display.core.displaysource) is read-only; `Windows.Devices.Display.Core` is intended for custom compositors driving specialized displays.
- [`IOCTL_VIDEO_SET_POWER_MANAGEMENT`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddvdeo/ni-ntddvdeo-ioctl_video_set_power_management) is obsolete and unsupported on modern Windows.
- [`DxgkDdiSetPowerState`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/dispmprt/nc-dispmprt-dxgkddi_set_power_state) is a WDDM display miniport-driver callback, not an application API.
- [`CIM_Display.SetPowerState`](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/setpowerstate-method-in-class-cim-display) is not implemented by WMI.

`SC_MONITORPOWER` remains the documented user-mode request used by the diagnostic trigger, but the OS and display driver still own how that request becomes a physical link/output transition. A script cannot replace that driver behavior in a vendor-neutral way.

## Completed: Existing Anchor Discovery

```powershell
.\diagnostics\inspect-displayconfig-anchor-candidates.ps1
```

This read-only command calls `QueryDisplayConfig(QDC_ALL_PATHS)` and PnP queries, then writes `log\diagnostics\displayconfig-anchor-candidates-*.log`. It now prints only active paths and candidate summaries by default; add `-IncludeAllPaths` only when full inactive-path evidence is needed.

The C340 single-display run on 2026-07-10 returned `allPaths=172`, `activeTargets=1`, and `candidateTargets=0`. Every inactive target was unavailable and non-forceable.

The next isolated experiment is the one-monitor IDD under `anchor-driver/`. The inspector reports recognized prototype targets as `ANCHOR` lines even if Windows initially activates the newly arrived monitor. Do not integrate it with the runtime until it produces exactly one `ANCHOR` with `targetAvailable=True` and `outputTech=16`.

- [QueryDisplayConfig function](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig)
- [Forced versus connected targets](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/forced-versus-connected-targets)

Do not roll back drivers until the current-driver pair is complete; changing only the NVIDIA mode controls substantially more variables.

NVIDIA also requests paired working/non-working captures for display regressions in its [display issue logging guide](https://nvidia.custhelp.com/app/answers/detail/a_id/5149/). Kernel dumps intentionally crash Windows and are outside this script; collect them only when preparing a formal NVIDIA report.
