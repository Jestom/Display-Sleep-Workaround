# Topology DDC Sleep Anchor (Experimental)

Language: English | [简体中文](README.zh-CN.md)

This directory contains an experimental Windows Indirect Display Driver (IDD) and software-device controller. It creates one low-resolution virtual display target intended to act as a temporary DisplayConfig topology anchor when the problem monitor is the only physical display.

## Current Phase

The IDD is not integrated into the production workaround. Phase one validates only this device lifecycle:

1. No available anchor target exists at baseline.
2. While the controller runs, Windows reports exactly one `TopologyDdcciAnchor` target with `targetAvailable=True` and `outputTech=16`.
3. After the controller stops, that target is no longer available and the original active physical target set is restored.

This phase does not call `SetDisplayConfig`, remove the physical monitor, or request display sleep. Only after this gate passes will phase two implement: temporarily activate the anchor, remove the problem physical target, sleep, then restore the physical topology after wake.

Windows may automatically activate a newly arrived IDD monitor, so the desktop layout can change briefly during the first test. It must recover automatically when the controller withdraws the device.

## Design Boundaries

- One virtual monitor only; this is not a general virtual-display product.
- Stable monitor container ID.
- No fabricated physical-monitor EDID.
- Conservative 60 Hz modes only: `1024x768`, `800x600`, and `640x480`.
- `DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INDIRECT_WIRED` (`outputTech=16`).
- The controller owns the software-device lifetime.
- The production workaround, DP diagnostic probe, and IDD experiment remain isolated.

The implementation is derived from Microsoft's official `video/IndirectDisplay` sample. See `THIRD-PARTY-NOTICES.md` and `LICENSE-MS-PL.txt`.

References: [Indirect display driver model overview](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/indirect-display-driver-model-overview), [Building IddCx 1.4 drivers](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/building-iddcx1.4-drivers)

## 1. Build On The Build PC

Requirements:

- Windows 11 build 22000 or newer.
- Visual Studio, Desktop C++ tools, a matching Windows SDK, and the complete WDK.
- The MSVC Spectre-mitigated libraries selected by the driver project.

From the `work` directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\anchor-driver\build-anchor-driver.ps1 -Configuration Release -Platform x64
```

The build script prefers 64-bit MSBuild, checks for `iddcx.h`, uses local time for catalog generation, and consolidates the complete package under:

```text
anchor-driver\out\x64
```

Build logs are written to `log\anchor-driver`. Copy the entire `anchor-driver\out\x64` directory to the affected PC.

## 2. Install On The Affected PC

Driver test-signing, Secure Boot, and certificate trust are machine-wide security boundaries. This project does not enable Windows test-signing or disable Secure Boot.

From an elevated PowerShell window:

```powershell
cd "D:\path\to\Display-Sleep-Workaround\anchor-driver"
Set-ExecutionPolicy -Scope Process Bypass
.\install-anchor-driver.ps1 -TrustTestCertificate
```

`-TrustTestCertificate` explicitly adds the local WDK test certificate to `LocalMachine\Root` and `LocalMachine\TrustedPublisher`. Use it only for a controlled package you built yourself. Omit the switch on later installs if the certificate is already trusted.

The installer only stages the driver package. It does not connect a virtual display.

## 3. Run The Phase-One Gate

Keep the production workaround task stopped, then run:

```powershell
Stop-ScheduledTask `
  -TaskName "Topology DDC Sleep Workaround" `
  -ErrorAction SilentlyContinue

.\test-anchor-availability.ps1
```

The script records the baseline, starts the controller, validates one available indirect-wired anchor, stops the controller, and verifies withdrawal plus restoration of the active physical target set. Its success line is:

```text
PASS: one available indirect-wired anchor was observed and then withdrawn; active physical targets were restored.
```

Logs are written under `work\log\anchor-driver` and `work\log\diagnostics`.

Unavailable historical anchor paths may remain in `QDC_ALL_PATHS`; they are harmless when `targetAvailable=False` and inactive. Do not proceed if the script does not report `PASS`, Device Manager reports a display-driver problem, or the desktop layout does not recover.

## 4. Uninstall

From an elevated PowerShell window:

```powershell
.\uninstall-anchor-driver.ps1
```

This stops any controller process and removes the driver package from the Driver Store. It does not remove the explicitly trusted test certificate because the same WDK certificate may also sign the DP probe.

## Not Implemented Yet

- No persistent virtual second desktop.
- No display-sleep or black-backlight test in phase one.
- No automatic driver installation by the production task.
- No topology switching before the availability gate passes.
- No distribution of a local test-signed package to ordinary users.

A normal-user release ultimately requires a Microsoft-accepted driver signature. Local test signing is only for controlled development validation.
