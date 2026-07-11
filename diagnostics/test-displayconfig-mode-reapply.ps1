[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$TargetNeedle,
  [ValidateSet("NoOptimization", "ForceModeEnumeration")]
  [string]$Strategy = "NoOptimization",
  [string]$Label = "",
  [ValidateRange(20, 180)]
  [int]$ObserveAfterDisplayOffSeconds = 120,
  [ValidateRange(60, 3600)]
  [int]$MaxWaitForDisplayOffSeconds = 900,
  [ValidateRange(15, 120)]
  [int]$VisibilityConfirmationSeconds = 45,
  [switch]$SkipEtl,
  [switch]$KeepExpandedTrace,
  [switch]$NoArchive
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$captureScriptPath = Join-Path $scriptRoot "capture-natural-display-sleep.ps1"
$logRoot = Join-Path $projectRoot "log\diagnostics"
$runToken = "{0}-mode-reapply-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $Strategy.ToLowerInvariant()
$experimentLog = Join-Path $logRoot "$runToken.log"
$watchdogMarker = Join-Path $logRoot "$runToken-watchdog.txt"
$script:WatchdogProcess = $null
$script:OriginalCaptured = $false

New-Item -ItemType Directory -Path $logRoot -Force | Out-Null

function Write-ExperimentLog {
  param([string]$Message)

  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
  Write-Host $line
  Add-Content -LiteralPath $experimentLog -Value $line -Encoding UTF8
}

function Write-ExperimentBlock {
  param(
    [string]$Title,
    [string]$Value
  )

  Write-ExperimentLog $Title
  foreach ($line in (($Value -split "`r?`n") | Where-Object { $_ -ne "" })) {
    Write-ExperimentLog ("  " + $line)
  }
}

function Test-IsAdministrator {
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentPowerShellPath {
  try {
    $path = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
      return $path
    }
  } catch {
  }
  return (Join-Path $PSHOME "powershell.exe")
}

function Assert-NoConflictingListener {
  $listenerNames = @("topology-ddcci-workaround.ps1", "c340-topology-ddcci-workaround.ps1")
  $listeners = @(Get-CimInstance Win32_Process | Where-Object {
    $process = $_
    $process.ProcessId -ne $PID -and
    $process.CommandLine -and
    ($listenerNames | Where-Object { $process.CommandLine -like "*$_*" })
  })
  if ($listeners.Count -gt 0) {
    $summary = ($listeners | ForEach-Object { "PID=$($_.ProcessId) Name=$($_.Name)" }) -join "; "
    throw "A topology/DDC listener is still running. Stop it before this experiment. $summary"
  }
}

function Get-NvidiaDisplayState {
  try {
    $result = & nvidia-smi.exe `
      --query-gpu=name,driver_version,pstate,display_active,display_mode,power.draw `
      --format=csv,noheader 2>&1
    if ($LASTEXITCODE -ne 0) {
      return "nvidia-smi query failed: $result"
    }
    return ([string]($result | Select-Object -First 1)).Trim()
  } catch {
    return "nvidia-smi query failed: $($_.Exception.Message)"
  }
}

function Start-RecoveryWatchdog {
  $powershellPath = Get-CurrentPowerShellPath
  $displaySwitchPath = Join-Path $env:windir "System32\DisplaySwitch.exe"
  $watchdogDelaySeconds = $VisibilityConfirmationSeconds + 15
  $escapedMarker = $watchdogMarker.Replace("'", "''")
  $escapedDisplaySwitch = $displaySwitchPath.Replace("'", "''")
  $command = "Start-Sleep -Seconds $watchdogDelaySeconds; Add-Content -LiteralPath '$escapedMarker' -Value ('Watchdog fired at ' + (Get-Date -Format o)); Start-Process -FilePath '$escapedDisplaySwitch' -ArgumentList '/extend' -WindowStyle Hidden"
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

  $script:WatchdogProcess = Start-Process `
    -FilePath $powershellPath `
    -ArgumentList @("-NoLogo", "-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encodedCommand) `
    -WindowStyle Hidden `
    -PassThru
  Write-ExperimentLog "Recovery watchdog armed. ProcessId=$($script:WatchdogProcess.Id) DelaySeconds=$watchdogDelaySeconds"
}

function Stop-RecoveryWatchdog {
  if (-not $script:WatchdogProcess) {
    return
  }

  try {
    if (-not $script:WatchdogProcess.HasExited) {
      Stop-Process -Id $script:WatchdogProcess.Id -Force -ErrorAction Stop
      Write-ExperimentLog "Recovery watchdog cancelled. ProcessId=$($script:WatchdogProcess.Id)"
    }
  } catch {
    Write-ExperimentLog "Recovery watchdog cancellation failed: $($_.Exception.Message)"
  } finally {
    $script:WatchdogProcess = $null
  }
}

function Wait-ForVisibleDisplayConfirmation {
  Write-Host ""
  Write-Host "The display mode was re-applied and the screen may blink."
  Write-Host "After the image is fully visible, press ENTER within $VisibilityConfirmationSeconds seconds."
  Write-Host "If the display remains blank, do not press anything; automatic recovery will run."
  Write-Host ""

  $deadline = (Get-Date).AddSeconds($VisibilityConfirmationSeconds)
  try {
    while ((Get-Date) -lt $deadline) {
      if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
          Write-ExperimentLog "User confirmed that the display image is visible after mode reapply."
          return $true
        }
      }
      Start-Sleep -Milliseconds 100
    }
  } catch {
    throw "Timed visibility confirmation requires an interactive ConsoleHost: $($_.Exception.Message)"
  }

  Write-ExperimentLog "Visibility confirmation timed out; recovery watchdog is being allowed to fire."
  return $false
}

if (-not (Test-Path -LiteralPath $captureScriptPath)) {
  throw "Natural-sleep capture script not found: $captureScriptPath"
}
if (-not $SkipEtl -and -not (Test-IsAdministrator)) {
  throw "Run this experiment from an elevated PowerShell window so ETW capture can start, or use -SkipEtl."
}
if ($Host.Name -ne "ConsoleHost") {
  throw "Run this experiment from an interactive PowerShell ConsoleHost. Host=$($Host.Name)"
}

Assert-NoConflictingListener

if (-not ("TopologyDdcciModeReapplyV1.ModeControl" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace TopologyDdcciModeReapplyV1 {
  public static class ModeControl {
    private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    private const int ERROR_SUCCESS = 0;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;
    private const uint DISPLAYCONFIG_PATH_ACTIVE = 0x00000001;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;
    private const uint DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE = 1;
    private const uint DISPLAYCONFIG_MODE_INFO_TYPE_TARGET = 2;
    private const uint DISPLAYCONFIG_PATH_MODE_IDX_INVALID = 0xFFFFFFFF;
    private const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    private const uint SDC_VALIDATE = 0x00000040;
    private const uint SDC_APPLY = 0x00000080;
    private const uint SDC_NO_OPTIMIZATION = 0x00000100;
    private const uint SDC_FORCE_MODE_ENUMERATION = 0x00001000;

    private static DISPLAYCONFIG_PATH_INFO[] originalPaths;
    private static DISPLAYCONFIG_MODE_INFO[] originalModes;

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID {
      public uint LowPart;
      public int HighPart;
      public override string ToString() {
        return HighPart.ToString("X8") + ":" + LowPart.ToString("X8");
      }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL {
      public uint Numerator;
      public uint Denominator;
      public double Value {
        get { return Denominator == 0 ? 0 : (double)Numerator / Denominator; }
      }
      public override string ToString() {
        return Numerator + "/" + Denominator + "=" + Value.ToString("F6");
      }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_2DREGION {
      public uint cx;
      public uint cy;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL {
      public int x;
      public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO {
      public LUID adapterId;
      public uint id;
      public uint modeInfoIdx;
      public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO {
      public LUID adapterId;
      public uint id;
      public uint modeInfoIdx;
      public uint outputTechnology;
      public uint rotation;
      public uint scaling;
      public DISPLAYCONFIG_RATIONAL refreshRate;
      public uint scanLineOrdering;
      [MarshalAs(UnmanagedType.Bool)]
      public bool targetAvailable;
      public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO {
      public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
      public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
      public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO {
      public ulong pixelRate;
      public DISPLAYCONFIG_RATIONAL hSyncFreq;
      public DISPLAYCONFIG_RATIONAL vSyncFreq;
      public DISPLAYCONFIG_2DREGION activeSize;
      public DISPLAYCONFIG_2DREGION totalSize;
      public uint videoStandard;
      public uint scanLineOrdering;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_TARGET_MODE {
      public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_MODE {
      public uint width;
      public uint height;
      public uint pixelFormat;
      public POINTL position;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct DISPLAYCONFIG_MODE_INFO_UNION {
      [FieldOffset(0)]
      public DISPLAYCONFIG_TARGET_MODE targetMode;
      [FieldOffset(0)]
      public DISPLAYCONFIG_SOURCE_MODE sourceMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_MODE_INFO {
      public uint infoType;
      public uint id;
      public LUID adapterId;
      public DISPLAYCONFIG_MODE_INFO_UNION modeInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER {
      public uint type;
      public uint size;
      public LUID adapterId;
      public uint id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_TARGET_DEVICE_NAME {
      public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
      public uint flags;
      public uint outputTechnology;
      public ushort edidManufactureId;
      public ushort edidProductCodeId;
      public uint connectorInstance;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
      public string monitorFriendlyDeviceName;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
      public string monitorDevicePath;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray, ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    private static extern int SetDisplayConfig(uint numPathArrayElements, DISPLAYCONFIG_PATH_INFO[] pathArray, uint numModeInfoArrayElements, DISPLAYCONFIG_MODE_INFO[] modeInfoArray, uint flags);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);

    private static void ThrowIfWin32Error(int error, string operation) {
      if (error != ERROR_SUCCESS) {
        throw new Win32Exception(error, operation + " failed with Win32 error " + error);
      }
    }

    private static void QueryActive(out DISPLAYCONFIG_PATH_INFO[] paths, out DISPLAYCONFIG_MODE_INFO[] modes) {
      for (int attempt = 1; attempt <= 5; attempt++) {
        uint pathCount;
        uint modeCount;
        int sizeError = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
        ThrowIfWin32Error(sizeError, "GetDisplayConfigBufferSizes");

        DISPLAYCONFIG_PATH_INFO[] pathBuffer = new DISPLAYCONFIG_PATH_INFO[pathCount];
        DISPLAYCONFIG_MODE_INFO[] modeBuffer = new DISPLAYCONFIG_MODE_INFO[modeCount];
        int queryError = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, pathBuffer, ref modeCount, modeBuffer, IntPtr.Zero);
        if (queryError == ERROR_INSUFFICIENT_BUFFER && attempt < 5) {
          continue;
        }
        ThrowIfWin32Error(queryError, "QueryDisplayConfig");

        paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
        Array.Copy(pathBuffer, paths, pathCount);
        Array.Copy(modeBuffer, modes, modeCount);
        return;
      }
      throw new InvalidOperationException("QueryDisplayConfig retry limit was reached.");
    }

    private static DISPLAYCONFIG_TARGET_DEVICE_NAME GetTargetName(DISPLAYCONFIG_PATH_INFO path) {
      DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
      targetName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
      targetName.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
      targetName.header.adapterId = path.targetInfo.adapterId;
      targetName.header.id = path.targetInfo.id;
      int error = DisplayConfigGetDeviceInfo(ref targetName);
      ThrowIfWin32Error(error, "DisplayConfigGetDeviceInfo");
      return targetName;
    }

    private static string Describe(DISPLAYCONFIG_PATH_INFO path, DISPLAYCONFIG_MODE_INFO[] modes) {
      DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = GetTargetName(path);
      StringBuilder result = new StringBuilder();
      result.Append("active=").Append((path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0)
        .Append(" srcAdapter=").Append(path.sourceInfo.adapterId)
        .Append(" srcId=").Append(path.sourceInfo.id)
        .Append(" targetAdapter=").Append(path.targetInfo.adapterId)
        .Append(" targetId=").Append(path.targetInfo.id)
        .Append(" outputTech=").Append(path.targetInfo.outputTechnology)
        .Append(" refresh=").Append(path.targetInfo.refreshRate)
        .Append(" friendly=").Append(targetName.monitorFriendlyDeviceName)
        .Append(" path=").Append(targetName.monitorDevicePath);

      if (path.sourceInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID && path.sourceInfo.modeInfoIdx < modes.Length) {
        DISPLAYCONFIG_MODE_INFO sourceInfo = modes[path.sourceInfo.modeInfoIdx];
        if (sourceInfo.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) {
          DISPLAYCONFIG_SOURCE_MODE source = sourceInfo.modeInfo.sourceMode;
          result.Append(" sourceMode=").Append(source.width).Append("x").Append(source.height)
            .Append("@").Append(source.position.x).Append(",").Append(source.position.y);
        }
      }
      if (path.targetInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID && path.targetInfo.modeInfoIdx < modes.Length) {
        DISPLAYCONFIG_MODE_INFO targetInfo = modes[path.targetInfo.modeInfoIdx];
        if (targetInfo.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_TARGET) {
          DISPLAYCONFIG_VIDEO_SIGNAL_INFO signal = targetInfo.modeInfo.targetMode.targetVideoSignalInfo;
          result.Append(" targetMode=").Append(signal.activeSize.cx).Append("x").Append(signal.activeSize.cy)
            .Append(" total=").Append(signal.totalSize.cx).Append("x").Append(signal.totalSize.cy)
            .Append(" pixelRate=").Append(signal.pixelRate)
            .Append(" v=").Append(signal.vSyncFreq);
        }
      }
      return result.ToString();
    }

    private static void RequireSingleMatchingTarget(DISPLAYCONFIG_PATH_INFO[] paths, string targetNeedle) {
      if (paths.Length != 1) {
        throw new InvalidOperationException("This experiment requires exactly one active display path; found " + paths.Length + ".");
      }
      if (String.IsNullOrWhiteSpace(targetNeedle)) {
        throw new InvalidOperationException("TargetNeedle is required.");
      }

      DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = GetTargetName(paths[0]);
      string friendlyName = targetName.monitorFriendlyDeviceName ?? "";
      string devicePath = targetName.monitorDevicePath ?? "";
      if (friendlyName.IndexOf(targetNeedle, StringComparison.OrdinalIgnoreCase) < 0 &&
          devicePath.IndexOf(targetNeedle, StringComparison.OrdinalIgnoreCase) < 0) {
        throw new InvalidOperationException("The single active path does not match TargetNeedle='" + targetNeedle + "'. Actual friendly='" + friendlyName + "' path='" + devicePath + "'.");
      }
    }

    public static string DumpActive() {
      DISPLAYCONFIG_PATH_INFO[] paths;
      DISPLAYCONFIG_MODE_INFO[] modes;
      QueryActive(out paths, out modes);
      StringBuilder result = new StringBuilder();
      result.AppendLine("activePaths=" + paths.Length + " modes=" + modes.Length);
      for (int i = 0; i < paths.Length; i++) {
        result.AppendLine("PATH " + i + " " + Describe(paths[i], modes));
      }
      return result.ToString();
    }

    public static string ReapplyCurrent(string targetNeedle, bool forceModeEnumeration) {
      DISPLAYCONFIG_PATH_INFO[] paths;
      DISPLAYCONFIG_MODE_INFO[] modes;
      QueryActive(out paths, out modes);
      RequireSingleMatchingTarget(paths, targetNeedle);

      originalPaths = new DISPLAYCONFIG_PATH_INFO[paths.Length];
      originalModes = new DISPLAYCONFIG_MODE_INFO[modes.Length];
      Array.Copy(paths, originalPaths, paths.Length);
      Array.Copy(modes, originalModes, modes.Length);

      uint validateFlags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_VALIDATE;
      int validationError = SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, validateFlags);
      ThrowIfWin32Error(validationError, "SetDisplayConfig(validate exact current mode)");

      uint applyFlags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_NO_OPTIMIZATION;
      if (forceModeEnumeration) {
        applyFlags |= SDC_FORCE_MODE_ENUMERATION;
      }
      int applyError = SetDisplayConfig((uint)paths.Length, paths, (uint)modes.Length, modes, applyFlags);
      ThrowIfWin32Error(applyError, "SetDisplayConfig(reapply exact current mode)");

      return "validationErr=" + validationError + " applyErr=" + applyError + " applyFlags=0x" + applyFlags.ToString("X8") + " forceModeEnumeration=" + forceModeEnumeration;
    }

    public static string RestoreOriginal() {
      if (originalPaths == null || originalModes == null) {
        return "No original DisplayConfig was captured in this process.";
      }

      uint flags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_NO_OPTIMIZATION;
      int error = SetDisplayConfig((uint)originalPaths.Length, originalPaths, (uint)originalModes.Length, originalModes, flags);
      ThrowIfWin32Error(error, "SetDisplayConfig(restore original exact mode)");
      originalPaths = null;
      originalModes = null;
      return "Restored original exact DisplayConfig. applyErr=" + error + " applyFlags=0x" + flags.ToString("X8");
    }
  }
}
"@
}

$forceModeEnumeration = $Strategy -eq "ForceModeEnumeration"
if ([string]::IsNullOrWhiteSpace($Label)) {
  $Label = if ($forceModeEnumeration) { "native-reapply-force-mode-enumeration" } else { "native-reapply-no-optimization" }
}

$captureArguments = @(
  "-NoLogo",
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $captureScriptPath,
  "-Label", $Label,
  "-ObserveAfterDisplayOffSeconds", "$ObserveAfterDisplayOffSeconds",
  "-MaxWaitForDisplayOffSeconds", "$MaxWaitForDisplayOffSeconds"
)
if ($SkipEtl) { $captureArguments += "-SkipEtl" }
if ($KeepExpandedTrace) { $captureArguments += "-KeepExpandedTrace" }
if ($NoArchive) { $captureArguments += "-NoArchive" }

try {
  Write-ExperimentLog "DisplayConfig exact-mode reapply experiment started. Strategy=$Strategy TargetNeedle=$TargetNeedle"
  Write-ExperimentLog "This experiment does not create a custom resolution and does not save DisplayConfig to the persistence database."
  Write-ExperimentBlock "DisplayConfig before reapply" ([TopologyDdcciModeReapplyV1.ModeControl]::DumpActive())
  Write-ExperimentLog "NVIDIA before reapply: $(Get-NvidiaDisplayState)"

  Start-RecoveryWatchdog
  $script:OriginalCaptured = $true
  $result = [TopologyDdcciModeReapplyV1.ModeControl]::ReapplyCurrent($TargetNeedle, $forceModeEnumeration)
  Write-ExperimentLog "Reapply result: $result"
  Start-Sleep -Seconds 3
  Write-ExperimentBlock "DisplayConfig after reapply" ([TopologyDdcciModeReapplyV1.ModeControl]::DumpActive())
  Write-ExperimentLog "NVIDIA after reapply: $(Get-NvidiaDisplayState)"

  if (-not (Wait-ForVisibleDisplayConfirmation)) {
    Write-ExperimentLog "Immediate fallback: running DisplaySwitch.exe /extend"
    Start-Process -FilePath (Join-Path $env:windir "System32\DisplaySwitch.exe") -ArgumentList "/extend" -WindowStyle Hidden
    Start-Sleep -Seconds 3
    throw "Display visibility was not confirmed. The natural-sleep capture was not started."
  }
  Stop-RecoveryWatchdog

  Write-ExperimentLog "Starting natural-sleep capture. Label=$Label ObserveAfterDisplayOffSeconds=$ObserveAfterDisplayOffSeconds"
  $powershellPath = Get-CurrentPowerShellPath
  & $powershellPath @captureArguments
  if ($LASTEXITCODE -ne 0) {
    throw "Natural-sleep capture failed with exit code $LASTEXITCODE."
  }
  Write-ExperimentLog "Natural-sleep capture completed. Label=$Label"
} catch {
  Write-ExperimentLog "Experiment failed: $($_.Exception.Message)"
  throw
} finally {
  Stop-RecoveryWatchdog
  if ($script:OriginalCaptured) {
    try {
      Write-ExperimentLog ([TopologyDdcciModeReapplyV1.ModeControl]::RestoreOriginal())
      Start-Sleep -Seconds 3
      Write-ExperimentBlock "DisplayConfig after original restore" ([TopologyDdcciModeReapplyV1.ModeControl]::DumpActive())
      Write-ExperimentLog "NVIDIA after original restore: $(Get-NvidiaDisplayState)"
    } catch {
      Write-ExperimentLog "Exact DisplayConfig restore failed: $($_.Exception.Message)"
      Write-ExperimentLog "Fallback: running DisplaySwitch.exe /extend"
      Start-Process -FilePath (Join-Path $env:windir "System32\DisplaySwitch.exe") -ArgumentList "/extend" -WindowStyle Hidden
    }
  }
  Write-ExperimentLog "Experiment finished. Log=$experimentLog"
}
