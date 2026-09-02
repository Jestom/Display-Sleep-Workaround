# Display Sleep Workaround

Language: English | [简体中文](README.zh-CN.md)

Windows display-sleep workaround for monitors that enter a powered black-backlight or invalid-signal state instead of staying truly asleep.

## Project Status: Native Driver Fix Confirmed

On 2026-09-02, the original affected system confirmed that NVIDIA driver `616.56` restores normal native display sleep without this workaround:

| Driver | Single display | Dual display | Custom resolution | Workaround |
| --- | --- | --- | --- | --- |
| `610.88` (R610) | Powered black backlight | Powered black backlight | Not required to reproduce | Not running |
| `616.56` (R615) | Normal sleep | Normal sleep on both displays | None | Not running |

`610.88` and `616.56` are consecutive public GeForce WHQL releases. This makes `616.56` the first confirmed public driver that fixes the issue on the validated HKC C340 / RTX 3070 Ti DisplayPort system. NVIDIA's [616.56 release notes](https://us.download.nvidia.com/Windows/616.56/616.56-win11-win10-release-notes.pdf) state that the published fixes are only a subset of the driver's total changes; they do not identify this display-sleep fix or provide a public bug number.

The project is therefore in maintenance mode. On `616.56`, use native Windows display sleep and do not install the workaround unless the fault is reproducible. Keep this project for older affected drivers and for diagnosing a future regression. A newer driver should be tested independently rather than assumed fixed solely because its version is greater than `616.56`.

The program does not disable the GPU or display adapter. Its default `PowerEvent` mode preserves the Windows power plan's native display-sleep flow. After Windows reports display-off, the selected problem monitor is removed from active DisplayConfig topology; the captured topology is restored on wake. Unselected healthy monitors continue using native Windows display sleep without requiring DDC/CI.

## Confirmed Behavior

The first validated hardware case is an HKC C340 connected to an NVIDIA DisplayPort output, with an H249W as the remaining active display.

Three behaviors were confirmed on 2026-07-10:

```text
natural Windows power-plan sleep + PowerEvent removal -> both displays sleep, DDC/CI disabled
scripted SC_MONITORPOWER + subsequent C340 removal -> C340 can retain black backlight
remove C340 without DPMS -> C340 truly sleeps while the remaining H249W stays lit
```

The natural `PowerEvent` log explicitly reports `RemainingDisplayPowerMode=Disabled`, so the successful dual-display sleep did not use DDC/CI. The original dual-display topology and H249W position were restored on wake.

Scripted test DPMS is not equivalent to the Windows power plan's natural sleep path. DDC/CI remains optional and is mainly used to power off remaining displays when `IdlePreempt` suppresses native Windows DPMS.

## Files

- `topology-ddcci-workaround.ps1`
  Long-running listener and normal test entry point.

- `topology-ddcci-core.ps1`
  DisplayConfig, Windows power events, idle detection, DDC/CI, and recovery implementation.

- `install-topology-ddcci-workaround-task.ps1`
  Installs or updates the logon scheduled task.

- `start-topology-ddcci-hidden.vbs`
  Hidden launcher used by the scheduled task.

- `uninstall-topology-ddcci-workaround-task.ps1`
  Removes the scheduled task and stops the listener process.

- `VALIDATION.md`
  Validation status and remaining Windows tests.

- `RESEARCH-NOTES.md`
  Historical investigation from the first case.

- `diagnostics/`
  Read-only natural-sleep ETW/DisplayConfig/driver-state A/B capture tools. They do not run the workaround.

- `anchor-driver/`
  Experimental single-monitor Indirect Display Driver, software-device controller, and reversible one-command target-lifecycle gate. It is not yet integrated into the runtime; see [anchor-driver/README.md](anchor-driver/README.md).

- `dp-link-probe/`
  Experimental KMDF/WDDM diagnostic probe for collecting DP address and DPCD evidence while the normal active path remains present. Protocol v4 also contains an explicitly confirmed, standard `0x600` idempotent-D0 capability gate; D3 is disabled. It is not yet a workaround and is not integrated into the runtime; see [dp-link-probe/README.md](dp-link-probe/README.md).

## Select The Target

List active DisplayConfig paths:

```powershell
.\topology-ddcci-workaround.ps1 -ListDisplays -NoLog
```

Copy a stable identifier from the intended path. For example, the first validated C340 reports:

```text
friendly=C340 path=\\?\DISPLAY#HKCB34C#...
```

Its target criterion is therefore:

```powershell
-TargetNeedles "DISPLAY#HKCB34C"
```

Do not copy a documentation placeholder as a literal ID. The scripts now reject `YOUR_MONITOR_ID` before any display-power action.

Available criteria:

```text
TargetNeedles           One or more strings matched against DisplayConfig friendly/path.
TargetId                DisplayConfig targetId. Default -1 means not constrained.
TargetOutputTechnology  DisplayConfig outputTech. Default -1 means not constrained.
```

Different criterion types are combined with AND. Multiple `TargetNeedles` values are OR-matched.

## Choose A Trigger Mode

| Mode | Use | Remaining displays |
| --- | --- | --- |
| `PowerEvent` | Default and recommended for multiple displays. Listens for the Windows power plan's natural display-off/on notifications. | Continue using native Windows display sleep; DDC/CI is normally unnecessary. |
| `IdlePreempt` | Fallback. Removes the target according to session input-idle time before Windows DPMS. | Native DPMS is suppressed; sleeping them normally requires DDC/CI support. |

Specify `TriggerMode` explicitly in test and installation commands so logs and diagnostics are unambiguous. `IdleTimeoutSeconds` applies only to `IdlePreempt`.

## Multi-Display Test

Stop any installed generic or legacy listener before a direct test. The wrapper rejects concurrent listener processes instead of allowing two instances to race over topology.

```powershell
Stop-ScheduledTask -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
```

The recommended test waits for the Windows power plan to sleep the displays naturally. Windows powers down the healthy secondary monitor, and the listener removes C340 after receiving display-off. Replace the example ID with the ID from your own `-ListDisplays` output.

```powershell
.\topology-ddcci-workaround.ps1 `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -ProfileName "C340" `
  -TriggerMode PowerEvent `
  -RemainingDisplayPowerMode Disabled `
  -TestOnce `
  -AutoRestoreAfterSeconds 180
```

Expected log sequence:

```text
Target preflight: ... matchedPaths=1 keptPaths=1
PowerEvent native mode is active
ConsoleDisplayState=0
removedPaths=1 keptPaths=1
Remaining display DDC/CI power-off is disabled
```

Wait for the power plan to trigger naturally; do not add `TriggerDpmsAfterSeconds`. After mouse or keyboard input, Windows reports display-on and the listener restores the original topology. With no input, restoration occurs 180 seconds after target removal.

## IdlePreempt Fallback

Test `IdlePreempt` only when natural `PowerEvent` behavior does not fix the target monitor:

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

This mode prevents Windows automatic display DPMS and removes the target first. Remaining displays therefore stay lit with `Disabled`. Change to the following only after every remaining display has passed a DDC/CI test:

```powershell
-RemainingDisplayPowerMode DdcciAllRemaining
```

If a remaining display does not support DDC/CI and must sleep natively, use `PowerEvent`, not `IdlePreempt`.

## Normal Installation

After the multi-display `PowerEvent` test passes, install from an elevated PowerShell window:

```powershell
.\install-topology-ddcci-workaround-task.ps1 `
  -StartNow `
  -TaskName "Topology DDC Sleep Workaround" `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -ProfileName "C340" `
  -TriggerMode PowerEvent `
  -RemainingDisplayPowerMode Disabled
```

The Windows power plan fully controls sleep timing in `PowerEvent`. `RemainingDisplayPowerMode Disabled` means the script sends no DDC/CI command; it does not prevent healthy monitors from using native Windows display sleep.

Enable runtime logs during installation:

```powershell
.\install-topology-ddcci-workaround-task.ps1 `
  -StartNow `
  -EnableLog `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -ProfileName "C340" `
  -TriggerMode PowerEvent `
  -RemainingDisplayPowerMode Disabled
```

Logs are written under:

```text
.\log\display-topology-ddcci-YYYYMMDD-HHMMSS.log
```

## Experimental Single-Display Test

The normal runtime refuses to remove the last active display path. Single-display support must first prove whether the local Windows/GPU stack accepts a supplied configuration with zero active paths.

Disconnect or deactivate every secondary display, verify that `-ListDisplays` reports exactly one active path, then run:

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

Safety behavior:

- The script first asks `SetDisplayConfig` to validate the zero-active-path request.
- The experiment is rejected unless it is an `IdlePreempt` `TestOnce` run with an explicit idle timeout and at least 60 seconds of automatic recovery.
- Before applying the zero-path configuration, an independent hidden PowerShell watchdog is started.
- A current-user `RunOnce` fallback is also registered so a reboot during the experiment can invoke `DisplaySwitch.exe /extend` after the next sign-in.
- Normal recovery restores the exact captured topology and cancels the watchdog.
- If the listener crashes or cannot restore, the watchdog runs `DisplaySwitch.exe /extend` after 240 seconds.
- The scheduled-task installer deliberately does not expose this experimental switch.

The validated C340 single-display stack returned Win32 error `87 (ERROR_INVALID_PARAMETER)` while `SetDisplayConfig` validated zero paths. No zero-active-path configuration was applied and the C340 path remained active. Do not repeat this experiment or enable production zero-path mode on that machine.

That failure log also exposed repeated timer ticks after a failed `TestOnce`; the current version stops all test timers immediately after success or failure and attempts only once. For a single physical display, no existing inactive DisplayConfig target is available on the tested machine. The only vendor-neutral automated topology design identified so far is an optional Indirect Display Driver target used temporarily as an anchor; it remains experimental and is not part of the runtime.

## Forced-DPMS Diagnostics

`TriggerDpmsAfterSeconds` sends scripted test DPMS through `SC_MONITORPOWER` and is intended only for diagnostics. Its path and timing are not equivalent to natural Windows power-plan sleep. The forced C340 test retained black backlight, while natural `PowerEvent` sleep has now succeeded for both displays.

```powershell
.\topology-ddcci-workaround.ps1 `
  -TargetNeedles "DISPLAY#HKCB34C" `
  -TriggerMode PowerEvent `
  -TestOnce `
  -TriggerDpmsAfterSeconds 5 `
  -AutoRestoreAfterSeconds 180
```

Do not use this forced test alone to conclude that an installed `PowerEvent` configuration will fail or succeed. Production validation must wait for the power plan to sleep the displays naturally.

## Root-Cause Capture

NVIDIA custom resolution is used only as an A/B probe that changes the failing state machine, not as a production dependency. The read-only capture script waits for natural Windows display sleep and compares current-driver native-bad and NVIDIA-CustomDisplay-good states:

```powershell
.\diagnostics\capture-natural-display-sleep.ps1 -Label "current-native-bad"
.\diagnostics\capture-natural-display-sleep.ps1 -Label "current-custom-good"
```

The completed 120-second A/B pair on 2026-07-10 showed `ConsoleDisplayState=0` in both modes. NVIDIA nevertheless remained `Display Active: Enabled` in the native bad state, while CustomDisplay changed to `Display Active: Disabled` and returned to `Enabled` after wake. This proves that the two states enter different output-power paths, but it does not assign the defect solely to NVIDIA. The custom mode may also change link training, AUX/DPCD sequencing, mode caches, or how the C340 scaler responds to signal removal.

The synchronized 25-second A/B later isolated the failing branch more precisely. Native and CustomDisplay modes both received the same kernel display interrupt/status-change notification and both rebuilt the target VidPN. Native mode then entered `WakeUpAdapter`, requested adapter D0, and restored VidMm segments; CustomDisplay completed the same connection invalidation without that recovery chain and remained physically off. The unwanted D0 is therefore selected after the common status event, inside an adapter/miniport recovery decision whose mode criterion is not exposed by public ETW. Additional timing tests, repeated DPMS, and suppressing the common status event are not planned.

The user has also confirmed that retaining the saved custom-resolution record is not enough: switching the active mode to any native resolution or refresh rate immediately restores the fault. This rules out a persistent one-time reset effect and makes delete/restart transition tests redundant.

Both public Windows CCD mode-resubmission strategies were tested and failed: the API calls succeeded, but NVIDIA remained `Display Active: Enabled` after natural sleep. They are not integrated into the production runtime.

The subsequent NVIDIA `NvAPI_DISP_SetDisplayConfig + NV_FORCE_COMMIT_VIDPN` experiment was also rejected. NVAPI validation and apply both returned success, the NVAPI and Windows CCD configurations remained unchanged, and the image recovered normally. Nevertheless, NVIDIA still reported `Display Active: Enabled` at the 120-second natural-off marker, with `DevicePoweredOn` appearing about 90.34 seconds after display-off. Force-committing the current native VidPN therefore does not repair the failing power transition. This project will not pursue deeper NVIDIA-specific mode-submission APIs as a generic fix; the diagnostic remains only as reproducible evidence in [diagnostics/README.md](diagnostics/README.md).

The single-active-path `SC_MONITORPOWER LowPower`, adapter-matched D3D11 keep-alive, and ordinary enumerated-mode transition branches are closed. None provided evidence of entering the known-good CustomDisplay state, and no more variants of those mechanisms are planned.

There is no documented general-purpose user-mode API that lets a script replace the display driver's physical output power transition while keeping the normal desktop path active. `GUID_CONSOLE_DISPLAY_STATE` and `GUID_MONITOR_POWER_ON` are notifications; `DisplaySource.Status` is read-only and intended for specialized-display compositors; the old video power IOCTL is unsupported; and the actual display-child power setter is a miniport-driver callback. At the user-mode topology layer, a vendor-neutral single-monitor workaround therefore needs another valid target such as a physical display, dummy target, or optional IDD anchor. The kernel diagnostic investigation exposed the failed D3-to-D0 recovery branch but cannot control the NVIDIA-private decision that selects it.

The offline native-versus-CustomDisplay evidence matrix and API audit are documented in [diagnostics/NATIVE-CUSTOMDISPLAY-DIFF.md](diagnostics/NATIVE-CUSTOMDISPLAY-DIFF.md). No additional user-mode collector is planned because the decisive DP link and AUX/DPCD fields are available only behind kernel display interfaces or external protocol diagnostics. The new [DP link diagnostic probe](dp-link-probe/README.md) uses the public WDDM 2.7 `DXGK_DP_INTERFACE` for that evidence stage. Its default capture path is read-only; protocol v4 adds only an explicitly confirmed standard `0x600` idempotent-D0 capability gate, with D3 disabled and no runtime integration.

The subsequent `QDC_ALL_PATHS` inspection found `172` possible paths and no usable inactive target. This rules out reusing an existing disconnected target through DisplayConfig alone. The experimental single-anchor IDD now has deterministic packaging, explicit certificate trust, install/removal helpers, and a reversible one-command target-lifecycle gate under [anchor-driver](anchor-driver/README.md). It must pass that Windows gate before any runtime integration.

## Status And Removal

Check the scheduled task:

```powershell
Get-ScheduledTask -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
Get-ScheduledTaskInfo -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
```

Check the listener process:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like "*topology-ddcci-workaround.ps1*" -or $_.CommandLine -like "*start-topology-ddcci-hidden.vbs*" } |
  Select-Object ProcessId,ParentProcessId,Name,CommandLine
```

Remove the task and stop the listener:

```powershell
.\uninstall-topology-ddcci-workaround-task.ps1 -TaskName "Topology DDC Sleep Workaround"
```

## Safety Notes

- Target matching is validated before the listener can issue display-power actions.
- A normal run refuses to remove every active display path.
- The original active topology is captured in-process before each removal and restored on input, automatic recovery, or listener shutdown.
- `DisplaySwitch.exe /extend` remains the fallback after normal DisplayConfig restore retries fail.
- Do not run old C340-specific and generic listeners at the same time. The installer disables the two known legacy C340 task names, and direct startup rejects another detected listener process.
- Validate every hardware setup with `TestOnce` before installing it.
