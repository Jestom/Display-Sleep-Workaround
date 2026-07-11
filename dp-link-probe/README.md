# Topology DP Link Diagnostic Probe

Language: English | [简体中文](README.zh-CN.md)

This is the first kernel-assisted evidence probe for the single-display investigation. It is not a replacement workaround. While the active DisplayConfig path remains intact, it uses the public WDDM 2.7 `DXGK_DP_INTERFACE` to compare DisplayPort address and DPCD observations between the failing native mode and the known-good CustomDisplay mode.

## Safety Boundary

- Installs an independent `Root\TopologyDpProbe` KMDF device. It does not replace or filter the GPU, monitor, or ACPI driver stacks; registered monitor interfaces are opened only as temporary remote I/O targets.
- Does not handle or intercept power IRPs.
- Does not call `SetDisplayConfig`, alter active paths, or create a virtual display.
- The default evidence path exposes DP capability query, target-address resolution, and native AUX read.
- Protocol v4 adds one experimental capability gate: an idempotent one-byte D0 (`01`) write to standard `DPCD 0x600 SET_POWER`, only for a validated direct non-MST target. D3 is disabled in source. No arbitrary DPCD address, length, or data write exists.
- Releases the DXGK interface and remote I/O target after every request.

Read-only kernel and AUX access is still not risk-free. A display miniport can service or power hardware while satisfying a read, so the first post-sleep read is itself a possible observation side effect. The `set-power` command is more intrusive, remains an explicit D0 capability gate, and is never called by snapshots or the production topology runtime.

## Requirements

- x64 Windows 10 version 2004/build 19041 or newer.
- WDDM 2.7 or newer GPU driver with `GUID_DXGK_DP_INTERFACE` support.
- Visual Studio 2022 with Desktop development with C++.
- A matching Windows Driver Kit and a valid test-driver signing setup.

Prepare a recovery path before loading any experimental kernel driver. This project does not change test-signing, Secure Boot, or boot configuration automatically.

## Build And Install

From an elevated Windows PowerShell window:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\build-dp-link-probe.ps1 -Configuration Release
.\install-dp-link-probe.ps1
```

The package is written to `out\x64`. Linux can validate the source layout but cannot produce or load the Windows `.sys`; the first real build must run on Windows with the WDK.

## Interface Gate

Run only the interface query first:

```powershell
.\out\x64\TopologyDpProbeCtl.exe list
```

The `monitor` entry whose path identifies the target display must report:

```text
controllerRevision=3 probeProtocolVersion=4 monitorInterfaces=...
open=0x00000000 dpInterface=0x00000000 caps=0x00000000
interfaceGate=PASS safeToRunRead=true
```

It must also report a nonzero `rootPorts` value. If every `dpInterface` query fails, `list` exits with code 3 and the capture script stops before sending a DPCD read.

The early v1 probe incorrectly queried `GUID_DISPLAY_DEVICE_ARRIVAL` adapter interfaces and every adapter returned `0xC00000BB (STATUS_NOT_SUPPORTED)`. Version 2 enumerates `GUID_DEVINTERFACE_MONITOR` instead. Each monitor node is a child of its display adapter, so the query can travel down that child stack to `Dxgkrnl`, which invokes the miniport's `DxgkDdiQueryInterface` with the child identity. This remains a capability gate: the existence of the WDDM 2.7 DDI does not guarantee that every vendor driver exposes it to this caller.

## Capture

Get the current decimal DisplayConfig target ID from the `work` directory:

```powershell
.\topology-ddcci-workaround.ps1 -ListDisplays -NoLog
```

The previously observed C340 target ID was `4357`, but it must be checked again after driver, port, or topology changes.

Take an awake snapshot:

```powershell
.\out\x64\TopologyDpProbeCtl.exe snapshot --target 4357
```

## Protocol v4 Write Gate

Do not begin with D3. After confirming `controllerRevision=3 probeProtocolVersion=4`, perform one idempotent D0 write while the display is awake and DPCD `0x600` is already `01`:

```powershell
.\out\x64\TopologyDpProbeCtl.exe set-power `
  --monitor 0 `
  --target 4357 `
  --state d0 `
  --confirm-standard-dpcd-write
```

Only `write=0x00000000` with `bytesDone=1` proves that the miniport accepts the standard AUX write. Read `0x600` back afterward:

```powershell
.\out\x64\TopologyDpProbeCtl.exe read `
  --monitor 0 `
  --target 4357 `
  --address 0x600 `
  --length 1
```

Stop on any write error and do not try another address to bypass a miniport restriction. On the affected machine, the NVIDIA miniport returned `write=0xC000000D`, native error `0xC0000022`, and `bytesDone=0`; this route is closed and D3 is now rejected in source. A future protocol may reconsider D3 on different hardware only after D0 succeeds and an independent recovery watchdog exists.

Stop the installed topology listener so it cannot remove the target during capture:

```powershell
Stop-ScheduledTask -TaskName "Topology DDC Sleep Workaround" -ErrorAction SilentlyContinue
```

The capture script also rejects a remaining listener process. It then captures one baseline, requests an explicit `SC_MONITORPOWER` transition, waits 120 seconds without polling, and takes one post-off snapshot:

```powershell
.\capture-dp-link-sleep.ps1 `
  -TargetId 4357 `
  -ObserveAfterDisplayOffSeconds 120
```

Use `-MonitorIndex N` after `list` identifies the target monitor. Logs are written under `..\log\diagnostics`.

Run this once in the failing EDID-native mode and once in the known-good NVIDIA CustomDisplay mode, while keeping the cable, port, power plan, and other variables unchanged. The snapshot reads DPCD ranges `0x00000`, `0x00100`, `0x00200`, and `0x00600`. It deliberately refuses AUX reads when `GetDPAddress` reports an MST downstream target (`numLinks > 0`).

This is a controlled forced-DPMS A/B and is not equivalent to the power plan's complete natural-sleep timing. Stage one first validates DXGK interface and DPCD-read access. After that gate passes, the same one-shot snapshot can be added to the existing natural-sleep capture observation point; forced results must not replace the final natural-sleep conclusion.

A powered-off AUX error is useful evidence and should not be treated as a generic probe failure. Compare complete logs, not only DPCD `0x600`.

## Uninstall

```powershell
.\uninstall-dp-link-probe.ps1
```

This removes the root device. The staged package remains in the Driver Store until it is explicitly removed with `pnputil` after verifying the matching `oemXX.inf`.

## Public Interfaces

- [DXGK_DP_INTERFACE](https://learn.microsoft.com/windows-hardware/drivers/ddi/dispmprt/ns-dispmprt-dxgk_dp_interface)
- [DXGKDDI_GETDPADDRESS](https://learn.microsoft.com/windows-hardware/drivers/ddi/dispmprt/nc-dispmprt-dxgkddi_getdpaddress)
- [DXGKDDI_DPAUXIOTRANSMISSION](https://learn.microsoft.com/windows-hardware/drivers/ddi/dispmprt/nc-dispmprt-dxgkddi_dpauxiotransmission)
- [WdfIoTargetQueryForInterface](https://learn.microsoft.com/windows-hardware/drivers/ddi/wdfiotarget/nf-wdfiotarget-wdfiotargetqueryforinterface)
- [GUID_DEVINTERFACE_MONITOR](https://learn.microsoft.com/windows-hardware/drivers/install/guid-devinterface-monitor)
- [Supporting Video Capture and Other Child Devices](https://learn.microsoft.com/windows-hardware/drivers/display/supporting-video-capture-and-other-child-devices)
