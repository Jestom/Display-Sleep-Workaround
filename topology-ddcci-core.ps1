param(
  [int]$ObserveSeconds = 90,
  [int]$DpmsAfterRemoveDelaySeconds = 5,
  [switch]$NoDpms,
  [switch]$KeepRemoved,
  [switch]$SaveToDatabase,
  [switch]$DdcciRemainingOff,
  [switch]$Listen,
  [switch]$TestOnce,
  [ValidateSet("IdlePreempt", "PowerEvent")]
  [string]$TriggerMode = "PowerEvent",
  [ValidateRange(0, 2147483)]
  [int]$IdleTimeoutSeconds = 0,
  [ValidateRange(100, 60000)]
  [int]$IdlePollMilliseconds = 500,
  [switch]$ExperimentalAllowZeroActivePaths,
  [ValidateRange(30, 86400)]
  [int]$EmergencyRestoreSeconds = 240,
  [int]$TriggerDpmsAfterSeconds = 0,
  [int]$AutoRestoreAfterSeconds = 0,
  [int]$ApplyDelayMilliseconds = 0,
  [int]$WakeDebounceSeconds = 8,
  [int]$RestoreWakeDelayMilliseconds = 1200,
  [int]$DisplayRestoreRetryCount = 3,
  [int]$DisplayRestoreRetryDelayMilliseconds = 1000,
  [int]$DdcPowerOnRetryCount = 8,
  [int]$DdcPowerOnRetryDelayMilliseconds = 750,
  [ValidateSet("DdcciAllRemaining", "Disabled")]
  [string]$RemainingDisplayPowerMode = "Disabled",
  [switch]$CompileOnly,
  [switch]$ListDisplays,
  [switch]$NoLog,
  [Alias("TargetNeedle")]
  [string[]]$TargetNeedles = @(),
  [int]$TargetId = -1,
  [int]$TargetOutputTechnology = -1,
  [string]$ProfileName = "Display",
  [string]$LogFilePrefix = "display-topology-ddcci",
  [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LoggingEnabled = -not $NoLog

function ConvertTo-SafeFileNameToken($Value, $Fallback) {
  $token = [string]$Value
  if ([string]::IsNullOrWhiteSpace($token)) {
    $token = $Fallback
  }
  $token = ($token -replace "[^A-Za-z0-9._-]+", "-").Trim("-")
  if ([string]::IsNullOrWhiteSpace($token)) {
    return $Fallback
  }
  return $token
}

function Initialize-LogPath {
  if (-not $script:LoggingEnabled) {
    return
  }

  if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $effectiveLogPrefix = ConvertTo-SafeFileNameToken $LogFilePrefix "display-topology-ddcci"
    $logDirectory = Join-Path $root "log"
    $script:LogPath = Join-Path $logDirectory ("{0}-{1}.log" -f $effectiveLogPrefix, (Get-Date -Format "yyyyMMdd-HHmmss"))
  } else {
    $script:LogPath = $LogPath
  }

  $parent = Split-Path -Parent $script:LogPath
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

$TargetNeedles = @($TargetNeedles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if (-not $CompileOnly -and -not $ListDisplays -and $TargetNeedles.Count -eq 0 -and $TargetId -lt 0 -and $TargetOutputTechnology -lt 0) {
  throw "A target display criterion is required. Run with -ListDisplays, then pass -TargetNeedles, -TargetId, or -TargetOutputTechnology."
}
if (-not $CompileOnly -and -not $ListDisplays -and @($TargetNeedles | Where-Object { $_ -match "YOUR_MONITOR_ID" }).Count -gt 0) {
  throw "TargetNeedles still contains the README placeholder YOUR_MONITOR_ID. Run with -ListDisplays and replace it with the actual monitor ID."
}
if ($TriggerMode -eq "IdlePreempt" -and $TriggerDpmsAfterSeconds -gt 0) {
  throw "TriggerDpmsAfterSeconds sends forced SC_MONITORPOWER and cannot be combined with IdlePreempt. Use -IdleTimeoutSeconds for an IdlePreempt test, or select -TriggerMode PowerEvent only for forced-DPMS diagnostics."
}
if ($ExperimentalAllowZeroActivePaths) {
  if (-not $Listen -or -not $TestOnce) {
    throw "ExperimentalAllowZeroActivePaths is restricted to listener TestOnce runs."
  }
  if ($TriggerMode -ne "IdlePreempt" -or $IdleTimeoutSeconds -le 0) {
    throw "ExperimentalAllowZeroActivePaths requires -TriggerMode IdlePreempt and an explicit positive -IdleTimeoutSeconds."
  }
  if ($AutoRestoreAfterSeconds -lt 60) {
    throw "ExperimentalAllowZeroActivePaths requires -AutoRestoreAfterSeconds of at least 60 seconds."
  }
  if ($EmergencyRestoreSeconds -le ($AutoRestoreAfterSeconds + 15)) {
    throw "EmergencyRestoreSeconds must be at least 15 seconds longer than AutoRestoreAfterSeconds."
  }
  if ($RemainingDisplayPowerMode -ne "Disabled" -or $DdcciRemainingOff) {
    throw "ExperimentalAllowZeroActivePaths requires -RemainingDisplayPowerMode Disabled because no remaining display should be addressed through DDC/CI."
  }
}

Initialize-LogPath

function Log($Message) {
  if (-not $script:LoggingEnabled) {
    return
  }
  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
  Write-Host $line
  Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Log-Block($Title, $Text) {
  Log $Title
  foreach ($line in (($Text -split "`r?`n") | Where-Object { $_ -ne "" })) {
    Log ("  " + $line)
  }
}

function Get-TargetCriteriaSummary {
  $parts = @()
  if ($TargetNeedles.Count -gt 0) {
    $parts += ("needles=[{0}]" -f ($TargetNeedles -join ", "))
  }
  if ($TargetId -ge 0) {
    $parts += "targetId=$TargetId"
  }
  if ($TargetOutputTechnology -ge 0) {
    $parts += "outputTechnology=$TargetOutputTechnology"
  }
  if ($parts.Count -eq 0) {
    return "<none>"
  }
  return ($parts -join "; ")
}

Add-Type -AssemblyName System.Windows.Forms

if (-not ("TopologyDdcciDisplayConfig.PowerSettingWindow" -as [type])) {
  Add-Type -ReferencedAssemblies "System.Windows.Forms" -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TopologyDdcciDisplayConfig {
  public sealed class PowerSettingWindow : NativeWindow, IDisposable {
    public Action<string, int> Callback { get; set; }
    private IntPtr consoleNotify = IntPtr.Zero;
    private IntPtr monitorNotify = IntPtr.Zero;

    private const int WM_POWERBROADCAST = 0x0218;
    private const int PBT_POWERSETTINGCHANGE = 0x8013;
    private const int DEVICE_NOTIFY_WINDOW_HANDLE = 0x00000000;

    public PowerSettingWindow() {
      CreateHandle(new CreateParams());
    }

    public void Register(Guid consoleDisplayStateGuid, Guid monitorPowerOnGuid) {
      consoleNotify = RegisterPowerSettingNotification(this.Handle, ref consoleDisplayStateGuid, DEVICE_NOTIFY_WINDOW_HANDLE);
      if (consoleNotify == IntPtr.Zero) {
        throw new InvalidOperationException("RegisterPowerSettingNotification failed for GUID_CONSOLE_DISPLAY_STATE.");
      }

      monitorNotify = RegisterPowerSettingNotification(this.Handle, ref monitorPowerOnGuid, DEVICE_NOTIFY_WINDOW_HANDLE);
      if (monitorNotify == IntPtr.Zero) {
        throw new InvalidOperationException("RegisterPowerSettingNotification failed for GUID_MONITOR_POWER_ON.");
      }
    }

    protected override void WndProc(ref Message m) {
      if (m.Msg == WM_POWERBROADCAST && m.WParam.ToInt32() == PBT_POWERSETTINGCHANGE) {
        POWERBROADCAST_SETTING setting = (POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(POWERBROADCAST_SETTING));
        int value = 0;
        if (setting.DataLength >= 4) {
          value = Marshal.ReadInt32(m.LParam, Marshal.SizeOf(typeof(Guid)) + sizeof(uint));
        }
        Action<string, int> callback = Callback;
        if (callback != null) {
          callback(setting.PowerSetting.ToString("D"), value);
        }
      }
      base.WndProc(ref m);
    }

    public void Dispose() {
      if (consoleNotify != IntPtr.Zero) {
        UnregisterPowerSettingNotification(consoleNotify);
        consoleNotify = IntPtr.Zero;
      }
      if (monitorNotify != IntPtr.Zero) {
        UnregisterPowerSettingNotification(monitorNotify);
        monitorNotify = IntPtr.Zero;
      }
      DestroyHandle();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POWERBROADCAST_SETTING {
      public Guid PowerSetting;
      public uint DataLength;
      public byte Data;
    }

    [DllImport("user32.dll", SetLastError=true)]
    private static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid PowerSettingGuid, int Flags);

    [DllImport("user32.dll", SetLastError=true)]
    private static extern bool UnregisterPowerSettingNotification(IntPtr Handle);
  }

  public static class NativeDpms {
    [DllImport("user32.dll", SetLastError=false)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);
  }
}
"@
}

if (-not ("TopologyDdcciIdleControlV1.IdleControl" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace TopologyDdcciIdleControlV1 {
  public sealed class InputSnapshot {
    public uint LastInputTick;
    public uint CurrentTick;
    public uint IdleMilliseconds;
  }

  public sealed class DisplayTimeoutInfo {
    public uint Seconds;
    public bool OnAcPower;
    public Guid SchemeGuid;
  }

  public static class IdleControl {
    private const uint ERROR_SUCCESS = 0;
    private const uint ES_CONTINUOUS = 0x80000000;
    private const uint ES_DISPLAY_REQUIRED = 0x00000002;

    private static readonly Guid VideoSubgroup = new Guid("7516b95f-f776-4464-8c53-06167f40cc99");
    private static readonly Guid VideoPowerdownTimeout = new Guid("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e");

    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO {
      public uint cbSize;
      public uint dwTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_POWER_STATUS {
      public byte ACLineStatus;
      public byte BatteryFlag;
      public byte BatteryLifePercent;
      public byte SystemStatusFlag;
      public uint BatteryLifeTime;
      public uint BatteryFullLifeTime;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SetThreadExecutionState(uint esFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("powrprof.dll")]
    private static extern uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);

    [DllImport("powrprof.dll")]
    private static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, out uint valueIndex);

    [DllImport("powrprof.dll")]
    private static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, out uint valueIndex);

    public static InputSnapshot GetInputSnapshot() {
      LASTINPUTINFO input = new LASTINPUTINFO();
      input.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
      if (!GetLastInputInfo(ref input)) {
        throw new Win32Exception(Marshal.GetLastWin32Error(), "GetLastInputInfo failed");
      }

      uint currentTick = unchecked((uint)Environment.TickCount);
      return new InputSnapshot {
        LastInputTick = input.dwTime,
        CurrentTick = currentTick,
        IdleMilliseconds = unchecked(currentTick - input.dwTime)
      };
    }

    public static DisplayTimeoutInfo GetDisplayTimeout() {
      IntPtr schemePointer = IntPtr.Zero;
      uint err = PowerGetActiveScheme(IntPtr.Zero, out schemePointer);
      if (err != ERROR_SUCCESS || schemePointer == IntPtr.Zero) {
        throw new Win32Exception((int)err, "PowerGetActiveScheme failed with Win32 error " + err);
      }

      try {
        Guid schemeGuid = (Guid)Marshal.PtrToStructure(schemePointer, typeof(Guid));
        SYSTEM_POWER_STATUS status;
        bool onAcPower = true;
        if (GetSystemPowerStatus(out status) && status.ACLineStatus == 0) {
          onAcPower = false;
        }

        Guid subgroup = VideoSubgroup;
        Guid setting = VideoPowerdownTimeout;
        uint seconds;
        err = onAcPower
          ? PowerReadACValueIndex(IntPtr.Zero, ref schemeGuid, ref subgroup, ref setting, out seconds)
          : PowerReadDCValueIndex(IntPtr.Zero, ref schemeGuid, ref subgroup, ref setting, out seconds);
        if (err != ERROR_SUCCESS) {
          throw new Win32Exception((int)err, "Reading the active display timeout failed with Win32 error " + err);
        }

        return new DisplayTimeoutInfo {
          Seconds = seconds,
          OnAcPower = onAcPower,
          SchemeGuid = schemeGuid
        };
      } finally {
        LocalFree(schemePointer);
      }
    }

    public static void SetDisplayRequired(bool required) {
      uint flags = ES_CONTINUOUS;
      if (required) flags |= ES_DISPLAY_REQUIRED;
      if (SetThreadExecutionState(flags) == 0) {
        throw new Win32Exception(Marshal.GetLastWin32Error(), "SetThreadExecutionState failed");
      }
    }
  }
}
"@
}

if (-not ("TopologyDdcciDisplayConfigV2.PathControl" -as [type])) {
  Add-Type -ReferencedAssemblies "System.Windows.Forms" -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace TopologyDdcciDisplayConfigV2 {
  public sealed class TargetMatchInfo {
    public int ActivePathCount;
    public int MatchedPathCount;
    public int KeptPathCount;
    public string Criteria;
  }

  public static class PathControl {
    private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    private const int ERROR_SUCCESS = 0;
    private const uint DISPLAYCONFIG_PATH_ACTIVE = 0x00000001;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;
    private const uint DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE = 1;
    private const uint DISPLAYCONFIG_MODE_INFO_TYPE_TARGET = 2;
    private const uint SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    private const uint SDC_VALIDATE = 0x00000040;
    private const uint SDC_APPLY = 0x00000080;
    private const uint SDC_SAVE_TO_DATABASE = 0x00000200;
    private const uint SDC_ALLOW_CHANGES = 0x00000400;
    private const uint SDC_ALLOW_PATH_ORDER_CHANGES = 0x00002000;
    private const uint SDC_TOPOLOGY_SUPPLIED = 0x00000010;
    private const uint DISPLAYCONFIG_PATH_MODE_IDX_INVALID = 0xFFFFFFFF;

    private const uint WM_SYSCOMMAND = 0x0112;
    private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xffff);
    private static readonly IntPtr SC_MONITORPOWER = new IntPtr(0xF170);
    private static readonly IntPtr MONITOR_OFF = new IntPtr(2);

    private static DISPLAYCONFIG_PATH_INFO[] originalPaths = null;
    private static DISPLAYCONFIG_MODE_INFO[] originalModes = null;

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

    [DllImport("user32.dll", EntryPoint = "QueryDisplayConfig")]
    private static extern int QueryDisplayConfigEmpty(uint flags, ref uint numPathArrayElements, IntPtr pathArray, ref uint numModeInfoArrayElements, IntPtr modeInfoArray, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    private static extern int SetDisplayConfig(uint numPathArrayElements, DISPLAYCONFIG_PATH_INFO[] pathArray, uint numModeInfoArrayElements, DISPLAYCONFIG_MODE_INFO[] modeInfoArray, uint flags);

    [DllImport("user32.dll", EntryPoint = "SetDisplayConfig")]
    private static extern int SetDisplayConfigEmpty(uint numPathArrayElements, IntPtr pathArray, uint numModeInfoArrayElements, IntPtr modeInfoArray, uint flags);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);

    [DllImport("user32.dll", SetLastError=false)]
    private static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    private static void ThrowIfWin32Error(int error, string operation) {
      if (error != ERROR_SUCCESS) {
        throw new Win32Exception(error, operation + " failed with Win32 error " + error);
      }
    }

    private static void QueryActive(out DISPLAYCONFIG_PATH_INFO[] paths, out DISPLAYCONFIG_MODE_INFO[] modes) {
      uint pathCount;
      uint modeCount;
      int err = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
      ThrowIfWin32Error(err, "GetDisplayConfigBufferSizes");

      DISPLAYCONFIG_PATH_INFO[] pathBuffer = new DISPLAYCONFIG_PATH_INFO[pathCount];
      DISPLAYCONFIG_MODE_INFO[] modeBuffer = new DISPLAYCONFIG_MODE_INFO[modeCount];
      if (pathCount == 0 && modeCount == 0) {
        err = QueryDisplayConfigEmpty(QDC_ONLY_ACTIVE_PATHS, ref pathCount, IntPtr.Zero, ref modeCount, IntPtr.Zero, IntPtr.Zero);
      } else {
        err = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, pathBuffer, ref modeCount, modeBuffer, IntPtr.Zero);
      }
      ThrowIfWin32Error(err, "QueryDisplayConfig");

      paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
      modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
      Array.Copy(pathBuffer, paths, pathCount);
      Array.Copy(modeBuffer, modes, modeCount);
    }

    private static DISPLAYCONFIG_TARGET_DEVICE_NAME GetTargetName(DISPLAYCONFIG_PATH_INFO path) {
      DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
      targetName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
      targetName.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
      targetName.header.adapterId = path.targetInfo.adapterId;
      targetName.header.id = path.targetInfo.id;
      int err = DisplayConfigGetDeviceInfo(ref targetName);
      ThrowIfWin32Error(err, "DisplayConfigGetDeviceInfo");
      return targetName;
    }

    private static DISPLAYCONFIG_MODE_INFO[] PackModesForPaths(DISPLAYCONFIG_PATH_INFO[] inputPaths, DISPLAYCONFIG_MODE_INFO[] inputModes, bool normalizeSingleDisplayPosition, out DISPLAYCONFIG_PATH_INFO[] outputPaths) {
      List<DISPLAYCONFIG_MODE_INFO> outputModes = new List<DISPLAYCONFIG_MODE_INFO>();
      outputPaths = new DISPLAYCONFIG_PATH_INFO[inputPaths.Length];

      for (int i = 0; i < inputPaths.Length; i++) {
        DISPLAYCONFIG_PATH_INFO path = inputPaths[i];

      if (path.sourceInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID && path.sourceInfo.modeInfoIdx < inputModes.Length) {
          DISPLAYCONFIG_MODE_INFO sourceMode = inputModes[path.sourceInfo.modeInfoIdx];
          if (normalizeSingleDisplayPosition && inputPaths.Length == 1 && sourceMode.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) {
            sourceMode.modeInfo.sourceMode.position.x = 0;
            sourceMode.modeInfo.sourceMode.position.y = 0;
          }
          path.sourceInfo.modeInfoIdx = (uint)outputModes.Count;
          outputModes.Add(sourceMode);
        }

      if (path.targetInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID && path.targetInfo.modeInfoIdx < inputModes.Length) {
          DISPLAYCONFIG_MODE_INFO targetMode = inputModes[path.targetInfo.modeInfoIdx];
          path.targetInfo.modeInfoIdx = (uint)outputModes.Count;
          outputModes.Add(targetMode);
        }

        outputPaths[i] = path;
      }

      return outputModes.ToArray();
    }

    private static string DescribePath(DISPLAYCONFIG_PATH_INFO path, int index, DISPLAYCONFIG_MODE_INFO[] modes) {
      DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = GetTargetName(path);
      StringBuilder sb = new StringBuilder();
      sb.Append("PATH ").Append(index)
        .Append(" active=").Append((path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0)
        .Append(" srcAdapter=").Append(path.sourceInfo.adapterId)
        .Append(" srcId=").Append(path.sourceInfo.id)
        .Append(" targetAdapter=").Append(path.targetInfo.adapterId)
        .Append(" targetId=").Append(path.targetInfo.id)
        .Append(" outputTech=").Append(path.targetInfo.outputTechnology)
        .Append(" refresh=").Append(path.targetInfo.refreshRate)
        .Append(" friendly=").Append(targetName.monitorFriendlyDeviceName)
        .Append(" path=").Append(targetName.monitorDevicePath);

      if (path.sourceInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID && path.sourceInfo.modeInfoIdx < modes.Length) {
        DISPLAYCONFIG_MODE_INFO sourceModeInfo = modes[path.sourceInfo.modeInfoIdx];
        if (sourceModeInfo.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) {
          DISPLAYCONFIG_SOURCE_MODE sourceMode = sourceModeInfo.modeInfo.sourceMode;
          sb.Append(" sourceMode=").Append(sourceMode.width).Append("x").Append(sourceMode.height)
            .Append("@").Append(sourceMode.position.x).Append(",").Append(sourceMode.position.y);
        }
      }

      if (path.targetInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID && path.targetInfo.modeInfoIdx < modes.Length) {
        DISPLAYCONFIG_MODE_INFO targetModeInfo = modes[path.targetInfo.modeInfoIdx];
        if (targetModeInfo.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_TARGET) {
          DISPLAYCONFIG_VIDEO_SIGNAL_INFO signal = targetModeInfo.modeInfo.targetMode.targetVideoSignalInfo;
          sb.Append(" targetMode=").Append(signal.activeSize.cx).Append("x").Append(signal.activeSize.cy)
            .Append(" v=").Append(signal.vSyncFreq);
        }
      }

      return sb.ToString();
    }

    private static DISPLAYCONFIG_PATH_INFO[] BuildTopologyOnlyPaths(DISPLAYCONFIG_PATH_INFO[] inputPaths) {
      DISPLAYCONFIG_PATH_INFO[] outputPaths = new DISPLAYCONFIG_PATH_INFO[inputPaths.Length];
      for (int i = 0; i < inputPaths.Length; i++) {
        DISPLAYCONFIG_PATH_INFO path = inputPaths[i];
        path.flags = path.flags | DISPLAYCONFIG_PATH_ACTIVE;
        path.sourceInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
        path.targetInfo.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
        outputPaths[i] = path;
      }
      return outputPaths;
    }

    private static int TryApplyTopologySupplied(DISPLAYCONFIG_PATH_INFO[] paths) {
      DISPLAYCONFIG_PATH_INFO[] topologyPaths = BuildTopologyOnlyPaths(paths);
      uint flags = SDC_APPLY | SDC_TOPOLOGY_SUPPLIED | SDC_ALLOW_PATH_ORDER_CHANGES | SDC_ALLOW_CHANGES;
      return SetDisplayConfig((uint)topologyPaths.Length, topologyPaths, 0, null, flags);
    }

    public static string DumpActive() {
      DISPLAYCONFIG_PATH_INFO[] paths;
      DISPLAYCONFIG_MODE_INFO[] modes;
      QueryActive(out paths, out modes);

      StringBuilder sb = new StringBuilder();
      sb.AppendLine("activePaths=" + paths.Length + " modes=" + modes.Length);
      for (int i = 0; i < paths.Length; i++) {
        sb.AppendLine(DescribePath(paths[i], i, modes));
      }
      return sb.ToString();
    }

    private static bool HasText(string value) {
      return !String.IsNullOrWhiteSpace(value);
    }

    private static string FormatTargetCriteria(string[] targetNeedles, int targetId, int outputTechnology) {
      List<string> parts = new List<string>();
      if (targetNeedles != null && targetNeedles.Length > 0) {
        List<string> needles = new List<string>();
        foreach (string needle in targetNeedles) {
          if (HasText(needle)) needles.Add(needle);
        }
        if (needles.Count > 0) parts.Add("needles=[" + String.Join(", ", needles.ToArray()) + "]");
      }
      if (targetId >= 0) parts.Add("targetId=" + targetId);
      if (outputTechnology >= 0) parts.Add("outputTechnology=" + outputTechnology);
      if (parts.Count == 0) return "<none>";
      return String.Join("; ", parts.ToArray());
    }

    private static bool MatchesTarget(DISPLAYCONFIG_PATH_INFO path, DISPLAYCONFIG_TARGET_DEVICE_NAME targetName, string[] targetNeedles, int targetId, int outputTechnology) {
      bool hasCriteria = false;
      StringComparison comparison = StringComparison.OrdinalIgnoreCase;

      if (targetNeedles != null && targetNeedles.Length > 0) {
        bool matchedNeedle = false;
        bool hasNeedleCriteria = false;
        string devicePath = targetName.monitorDevicePath ?? "";
        string friendlyName = targetName.monitorFriendlyDeviceName ?? "";

        foreach (string needle in targetNeedles) {
          if (!HasText(needle)) continue;
          hasCriteria = true;
          hasNeedleCriteria = true;
          if (devicePath.IndexOf(needle, comparison) >= 0 || friendlyName.IndexOf(needle, comparison) >= 0) {
            matchedNeedle = true;
            break;
          }
        }

        if (hasNeedleCriteria && !matchedNeedle) {
          return false;
        }
      }

      if (targetId >= 0) {
        hasCriteria = true;
        if (path.targetInfo.id != (uint)targetId) {
          return false;
        }
      }

      if (outputTechnology >= 0) {
        hasCriteria = true;
        if (path.targetInfo.outputTechnology != (uint)outputTechnology) {
          return false;
        }
      }

      if (!hasCriteria) {
        throw new InvalidOperationException("At least one target matching criterion is required.");
      }

      return true;
    }

    public static TargetMatchInfo AnalyzeTargetMatching(string[] targetNeedles, int targetId, int outputTechnology) {
      DISPLAYCONFIG_PATH_INFO[] paths;
      DISPLAYCONFIG_MODE_INFO[] modes;
      QueryActive(out paths, out modes);

      int matched = 0;
      for (int i = 0; i < paths.Length; i++) {
        DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = GetTargetName(paths[i]);
        if (MatchesTarget(paths[i], targetName, targetNeedles, targetId, outputTechnology)) {
          matched++;
        }
      }

      return new TargetMatchInfo {
        ActivePathCount = paths.Length,
        MatchedPathCount = matched,
        KeptPathCount = paths.Length - matched,
        Criteria = FormatTargetCriteria(targetNeedles, targetId, outputTechnology)
      };
    }

    public static string RemoveTargetMatching(string[] targetNeedles, int targetId, int outputTechnology, bool saveToDatabase, bool allowZeroActivePaths) {
      DISPLAYCONFIG_PATH_INFO[] paths;
      DISPLAYCONFIG_MODE_INFO[] modes;
      QueryActive(out paths, out modes);

      originalPaths = new DISPLAYCONFIG_PATH_INFO[paths.Length];
      originalModes = new DISPLAYCONFIG_MODE_INFO[modes.Length];
      Array.Copy(paths, originalPaths, paths.Length);
      Array.Copy(modes, originalModes, modes.Length);

      List<DISPLAYCONFIG_PATH_INFO> kept = new List<DISPLAYCONFIG_PATH_INFO>();
      List<string> removedDescriptions = new List<string>();

      for (int i = 0; i < paths.Length; i++) {
        DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = GetTargetName(paths[i]);
        bool isTarget = MatchesTarget(paths[i], targetName, targetNeedles, targetId, outputTechnology);

        if (isTarget) {
          DISPLAYCONFIG_PATH_INFO removed = paths[i];
          removed.flags = removed.flags & ~DISPLAYCONFIG_PATH_ACTIVE;
          removedDescriptions.Add(DescribePath(removed, i, modes));
        } else {
          DISPLAYCONFIG_PATH_INFO keep = paths[i];
          keep.flags = keep.flags | DISPLAYCONFIG_PATH_ACTIVE;
          kept.Add(keep);
        }
      }

      if (removedDescriptions.Count == 0) {
        throw new InvalidOperationException("No active path matched target criteria: " + FormatTargetCriteria(targetNeedles, targetId, outputTechnology));
      }
      if (kept.Count == 0 && !allowZeroActivePaths) {
        throw new InvalidOperationException("Refusing to remove the last active display path.");
      }

      if (kept.Count == 0) {
        uint validateFlags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_VALIDATE | SDC_ALLOW_CHANGES;
        int validationErr = SetDisplayConfigEmpty(0, IntPtr.Zero, 0, IntPtr.Zero, validateFlags);
        ThrowIfWin32Error(validationErr, "SetDisplayConfig(validate zero active paths)");

        uint applyFlags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_ALLOW_CHANGES;
        if (saveToDatabase) {
          applyFlags = applyFlags | SDC_SAVE_TO_DATABASE;
        }
        int emptyApplyErr = SetDisplayConfigEmpty(0, IntPtr.Zero, 0, IntPtr.Zero, applyFlags);
        ThrowIfWin32Error(emptyApplyErr, "SetDisplayConfig(remove last active target)");

        StringBuilder emptyResult = new StringBuilder();
        emptyResult.AppendLine("applyStrategy=experimental-zero-active-paths validationErr=" + validationErr + " suppliedErr=" + emptyApplyErr + " saveToDatabase=" + saveToDatabase);
        emptyResult.AppendLine("removedPaths=" + removedDescriptions.Count + " keptPaths=0");
        foreach (string description in removedDescriptions) {
          emptyResult.AppendLine("REMOVED " + description);
        }
        return emptyResult.ToString();
      }

      DISPLAYCONFIG_PATH_INFO[] keptPaths = kept.ToArray();
      int topologyErr = saveToDatabase ? -1 : TryApplyTopologySupplied(keptPaths);
      int suppliedErr = ERROR_SUCCESS;
      string applyStrategy = saveToDatabase ? "use-supplied-display-config-save-to-database" : "topology-supplied";
      if (topologyErr != ERROR_SUCCESS) {
        DISPLAYCONFIG_PATH_INFO[] applyPaths;
        DISPLAYCONFIG_MODE_INFO[] applyModes = PackModesForPaths(keptPaths, modes, true, out applyPaths);

        uint flags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_ALLOW_CHANGES;
        if (saveToDatabase) {
          flags = flags | SDC_SAVE_TO_DATABASE;
        }
        suppliedErr = SetDisplayConfig((uint)applyPaths.Length, applyPaths, (uint)applyModes.Length, applyModes, flags);
        applyStrategy = "use-supplied-display-config";
        if (saveToDatabase) {
          applyStrategy = "use-supplied-display-config-save-to-database";
        }
        ThrowIfWin32Error(suppliedErr, "SetDisplayConfig(remove target); topology-supplied error was " + topologyErr);
      }

      StringBuilder sb = new StringBuilder();
      sb.AppendLine("applyStrategy=" + applyStrategy + " topologyErr=" + topologyErr + " suppliedErr=" + suppliedErr);
      sb.AppendLine("removedPaths=" + removedDescriptions.Count + " keptPaths=" + kept.Count);
      foreach (string description in removedDescriptions) {
        sb.AppendLine("REMOVED " + description);
      }
      return sb.ToString();
    }

    public static string RemoveTargetMatching(string[] targetNeedles, int targetId, int outputTechnology, bool saveToDatabase) {
      return RemoveTargetMatching(targetNeedles, targetId, outputTechnology, saveToDatabase, false);
    }

    public static string RemoveTargetContaining(string targetNeedle, bool saveToDatabase) {
      return RemoveTargetMatching(new string[] { targetNeedle }, -1, -1, saveToDatabase);
    }

    public static string RestoreOriginal(bool saveToDatabase) {
      if (originalPaths == null || originalModes == null) {
        return "No original DisplayConfig captured in this process.";
      }

      int topologyErr = saveToDatabase ? -1 : TryApplyTopologySupplied(originalPaths);
      if (topologyErr != ERROR_SUCCESS) {
        DISPLAYCONFIG_PATH_INFO[] applyPaths;
        DISPLAYCONFIG_MODE_INFO[] applyModes = PackModesForPaths(originalPaths, originalModes, false, out applyPaths);

        uint flags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_APPLY | SDC_ALLOW_CHANGES;
        if (saveToDatabase) {
          flags = flags | SDC_SAVE_TO_DATABASE;
        }
        int err = SetDisplayConfig((uint)applyPaths.Length, applyPaths, (uint)applyModes.Length, applyModes, flags);
        ThrowIfWin32Error(err, "SetDisplayConfig(restore original); topology-supplied error was " + topologyErr);
      }
      return "Restored original active DisplayConfig paths=" + originalPaths.Length + " modes=" + originalModes.Length + " saveToDatabase=" + saveToDatabase;
    }

    public static void SendDpmsOff() {
      SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, MONITOR_OFF);
    }
  }
}
"@
}

if (-not ("TopologyDdcciDisplayConfig.DdcciPowerGeneric" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace TopologyDdcciDisplayConfig {
  public static class DdcciPowerGeneric {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PHYSICAL_MONITOR {
      public IntPtr hPhysicalMonitor;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
      public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX {
      public int cbSize;
      public RECT rcMonitor;
      public RECT rcWork;
      public uint dwFlags;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
      public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT {
      public int left;
      public int top;
      public int right;
      public int bottom;
    }

    public sealed class DdcciResult {
      public string DeviceName;
      public string Description;
      public uint Current;
      public uint Maximum;
      public string Message;
      public bool Success;
      public string Error;
    }

    delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);

    [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool DestroyPhysicalMonitors(uint count, PHYSICAL_MONITOR[] monitors);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, IntPtr type, out uint currentValue, out uint maximumValue);

    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool SetVCPFeature(IntPtr monitor, byte code, uint newValue);

    static string ErrorText() {
      return new Win32Exception(Marshal.GetLastWin32Error()).Message;
    }

    static DdcciResult ErrorResult(string deviceName, string description, string message, string error) {
      return new DdcciResult {
        DeviceName = deviceName,
        Description = description,
        Current = 0,
        Maximum = 0,
        Message = message,
        Success = false,
        Error = error
      };
    }

    static DdcciResult SetPhysicalPower(string deviceName, PHYSICAL_MONITOR physical, uint value) {
      uint current;
      uint maximum;
      if (!GetVCPFeatureAndVCPFeatureReply(physical.hPhysicalMonitor, 0xD6, IntPtr.Zero, out current, out maximum)) {
        return ErrorResult(deviceName, physical.szPhysicalMonitorDescription, "Read VCP D6 before DDC/CI power set", ErrorText());
      }

      if (!SetVCPFeature(physical.hPhysicalMonitor, 0xD6, value)) {
        return ErrorResult(deviceName, physical.szPhysicalMonitorDescription, "Set VCP D6=0x" + value.ToString("X2"), ErrorText());
      }

      return new DdcciResult {
        DeviceName = deviceName,
        Description = physical.szPhysicalMonitorDescription,
        Current = current,
        Maximum = maximum,
        Message = "Set VCP D6=0x" + value.ToString("X2"),
        Success = true,
        Error = null
      };
    }

    static DdcciResult[] SetLogicalMonitorPower(IntPtr logical, string deviceName, uint value) {
      uint count;
      if (!GetNumberOfPhysicalMonitorsFromHMONITOR(logical, out count)) {
        return new DdcciResult[] { ErrorResult(deviceName, "", "Get physical monitor count", ErrorText()) };
      }

      var physical = new PHYSICAL_MONITOR[count];
      if (!GetPhysicalMonitorsFromHMONITOR(logical, count, physical)) {
        return new DdcciResult[] { ErrorResult(deviceName, "", "Get physical monitor handle", ErrorText()) };
      }

      try {
        if (count == 0) {
          return new DdcciResult[] { ErrorResult(deviceName, "", "Get physical monitor handle", "physical monitor count is zero") };
        }

        List<DdcciResult> results = new List<DdcciResult>();
        for (int i = 0; i < physical.Length; i++) {
          results.Add(SetPhysicalPower(deviceName, physical[i], value));
        }
        return results.ToArray();
      } finally {
        DestroyPhysicalMonitors(count, physical);
      }
    }

    public static DdcciResult[] SetAllActivePower(uint value) {
      List<DdcciResult> results = new List<DdcciResult>();

      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data) {
        var info = new MONITORINFOEX();
        info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        if (!GetMonitorInfo(hMonitor, ref info)) {
          results.Add(ErrorResult("", "", "Get monitor info", ErrorText()));
          return true;
        }

        results.AddRange(SetLogicalMonitorPower(hMonitor, info.szDevice, value));
        return true;
      }, IntPtr.Zero);

      return results.ToArray();
    }

    public static DdcciResult[] SetLogicalPower(string targetDeviceName, uint value) {
      List<DdcciResult> results = new List<DdcciResult>();
      bool found = false;

      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data) {
        var info = new MONITORINFOEX();
        info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        if (!GetMonitorInfo(hMonitor, ref info)) return true;

        if (String.Equals(info.szDevice, targetDeviceName, StringComparison.OrdinalIgnoreCase)) {
          found = true;
          results.AddRange(SetLogicalMonitorPower(hMonitor, info.szDevice, value));
          return false;
        }
        return true;
      }, IntPtr.Zero);

      if (!found) {
        results.Add(ErrorResult(targetDeviceName, "", "Find logical monitor", "logical monitor was not found"));
      }

      return results.ToArray();
    }

  }
}
"@
}

function Get-TargetMatchPreview {
  return [TopologyDdcciDisplayConfigV2.PathControl]::AnalyzeTargetMatching([string[]]$TargetNeedles, [int]$TargetId, [int]$TargetOutputTechnology)
}

if ($CompileOnly) {
  [TopologyDdcciDisplayConfigV2.PathControl]::DumpActive() | Out-Null
  $testWindow = New-Object TopologyDdcciDisplayConfig.PowerSettingWindow
  $testWindow.Dispose()
  if ($TargetNeedles.Count -gt 0 -or $TargetId -ge 0 -or $TargetOutputTechnology -ge 0) {
    $compilePreview = Get-TargetMatchPreview
    if ($compilePreview.MatchedPathCount -eq 0) {
      throw "No active path matched target criteria during preflight: $($compilePreview.Criteria)"
    }
    Write-Output ("Target preflight succeeded. activePaths={0} matchedPaths={1} keptPaths={2} criteria={3}" -f $compilePreview.ActivePathCount, $compilePreview.MatchedPathCount, $compilePreview.KeptPathCount, $compilePreview.Criteria)
  }
  Write-Output "$ProfileName DisplayConfig path-control code compiled successfully."
  exit 0
}

if ($ListDisplays) {
  Write-Output ([TopologyDdcciDisplayConfigV2.PathControl]::DumpActive())
  exit 0
}

$script:TargetMatchPreview = Get-TargetMatchPreview
if ($script:TargetMatchPreview.MatchedPathCount -eq 0) {
  throw "No active path matched target criteria during preflight: $($script:TargetMatchPreview.Criteria)"
}
if ($script:TargetMatchPreview.KeptPathCount -eq 0 -and -not $ExperimentalAllowZeroActivePaths) {
  throw "The selected target includes every active display path. Single-display removal requires the explicit experimental mode and is not enabled by default."
}

function Log-AdapterState {
  Log "Display adapters"
  Get-PnpDevice -Class Display | ForEach-Object {
    Log ("  {0} | {1} | {2}" -f $_.Status, $_.FriendlyName, $_.InstanceId)
  }

  Log "Active WMI monitor connections"
  Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams |
    Where-Object { $_.Active } |
    ForEach-Object {
      Log ("  {0} | outputTech={1}" -f $_.InstanceName, $_.VideoOutputTechnology)
    }

  try {
    $smi = (& nvidia-smi.exe --query-gpu=name,utilization.gpu,pstate --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if ($smi) {
      Log ("nvidia-smi: " + ([string]$smi).Trim())
    } else {
      Log "nvidia-smi: no output"
    }
  } catch {
    Log ("nvidia-smi failed: {0}" -f $_.Exception.Message)
  }
}

$script:DdcPowerOffSent = $false
$script:DdcPowerOffAttempted = $false
$script:DdcPowerDeviceNames = @()

function Format-DdcResult($Result) {
  if ($Result.Success) {
    return ("OK device={0} desc={1} previousD6=0x{2:X2} max=0x{3:X2} message={4}" -f $Result.DeviceName, $Result.Description, $Result.Current, $Result.Maximum, $Result.Message)
  }
  return ("FAIL device={0} desc={1} message={2} error={3}" -f $Result.DeviceName, $Result.Description, $Result.Message, $Result.Error)
}

function Invoke-RemainingDisplayDdcPowerOff {
  $mode = $RemainingDisplayPowerMode
  if ($DdcciRemainingOff) {
    $mode = "DdcciAllRemaining"
  }

  if ($mode -eq "Disabled") {
    Log "Remaining display DDC/CI power-off is disabled."
    return
  }

  $script:DdcPowerOffAttempted = $true
  $results = @()
  try {
    Log "Sending DDC/CI VCP D6=0x04 power off to all remaining active displays."
    $results = @([TopologyDdcciDisplayConfig.DdcciPowerGeneric]::SetAllActivePower(0x04))
  } catch {
    Log ("Remaining display DDC/CI power-off failed before result collection: {0}" -f $_.Exception.Message)
    return
  }

  foreach ($result in $results) {
    Log ("Remaining display DDC/CI off result: " + (Format-DdcResult $result))
  }

  $successful = @($results | Where-Object { $_.Success -and -not [string]::IsNullOrWhiteSpace($_.DeviceName) })
  if ($successful.Count -gt 0) {
    $script:DdcPowerOffSent = $true
    $script:DdcPowerDeviceNames = @($successful | Select-Object -ExpandProperty DeviceName -Unique)
    Log ("DDC/CI power-off succeeded for logical display(s): {0}" -f ($script:DdcPowerDeviceNames -join ", "))
  } else {
    Log "No remaining display accepted DDC/CI power-off; keeping topology workaround active without companion display power-off."
  }
}

function Send-DpmsOff {
  [TopologyDdcciDisplayConfig.NativeDpms]::SendMessage([IntPtr]0xffff, 0x0112, [IntPtr]0xF170, [IntPtr]2) | Out-Null
}

function Update-EffectiveIdleTimeout {
  if ($IdleTimeoutSeconds -gt 0) {
    $effectiveSeconds = $IdleTimeoutSeconds
    $source = "explicit"
  } else {
    $timeoutInfo = [TopologyDdcciIdleControlV1.IdleControl]::GetDisplayTimeout()
    $effectiveSeconds = [int]$timeoutInfo.Seconds
    $powerSource = if ($timeoutInfo.OnAcPower) { "AC" } else { "DC" }
    $source = "power-plan:$powerSource scheme=$($timeoutInfo.SchemeGuid)"
  }

  $changed = $script:EffectiveIdleTimeoutSeconds -ne $effectiveSeconds -or $script:EffectiveIdleTimeoutSource -ne $source
  $script:EffectiveIdleTimeoutSeconds = $effectiveSeconds
  $script:EffectiveIdleTimeoutSource = $source
  $script:IdleTimeoutLastRefresh = Get-Date

  if ($changed) {
    if ($effectiveSeconds -gt 0) {
      Log "Idle-preempt timeout is ${effectiveSeconds}s. Source=$source Poll=${IdlePollMilliseconds}ms"
    } else {
      Log "Idle-preempt timeout is disabled by the active power plan. Source=$source"
    }
  }
}

function Invoke-IdlePreemptPoll {
  try {
    if ($script:TestOnceCompleted) {
      return
    }

    if ($IdleTimeoutSeconds -eq 0 -and ((Get-Date) - $script:IdleTimeoutLastRefresh).TotalSeconds -ge 60) {
      Update-EffectiveIdleTimeout
    }

    $snapshot = [TopologyDdcciIdleControlV1.IdleControl]::GetInputSnapshot()
    if ($script:State -eq "Idle") {
      if ($script:EffectiveIdleTimeoutSeconds -le 0) {
        return
      }

      $thresholdMilliseconds = [uint64]$script:EffectiveIdleTimeoutSeconds * 1000
      if ([uint64]$snapshot.IdleMilliseconds -ge $thresholdMilliseconds) {
        $script:IdleCycleLastInputTick = [uint32]$snapshot.LastInputTick
        Log ("Idle timeout reached before Windows DPMS. IdleMilliseconds={0} LastInputTick={1}" -f $snapshot.IdleMilliseconds, $snapshot.LastInputTick)
        Schedule-TopologyDdcciSleep -Reason "idle timeout"
      }
      return
    }

    if ($script:State -in @("PendingApply", "Applying", "Active") -and $script:SleepCycleStarted -and $null -ne $script:IdleCycleLastInputTick) {
      if ([uint32]$snapshot.LastInputTick -ne [uint32]$script:IdleCycleLastInputTick) {
        Log ("New user input detected by idle-preempt monitor. PreviousTick={0} CurrentTick={1} State={2}" -f $script:IdleCycleLastInputTick, $snapshot.LastInputTick, $script:State)
        Restore-TopologyDdcciSleep -Reason "user input detected" -Force -SkipWakeDebounce
      }
    }
  } catch {
    Log ("Idle-preempt poll failed: {0}" -f $_.Exception.Message)
  }
}

function Complete-TestOnce {
  param([string]$Message)

  if (-not $TestOnce -or $script:TestOnceCompleted) {
    return
  }

  $script:TestOnceCompleted = $true
  if ($script:ApplyTimer) {
    $script:ApplyTimer.Stop()
  }
  if ($script:AutoRestoreTimer) {
    $script:AutoRestoreTimer.Stop()
  }
  if ($script:DebouncedRestoreTimer) {
    $script:DebouncedRestoreTimer.Stop()
  }
  if ($script:IdlePreemptTimer) {
    $script:IdlePreemptTimer.Stop()
  }

  Log $Message
  [System.Windows.Forms.Application]::ExitThread()
}

function Start-EmergencyRestoreWatchdog {
  if ($script:EmergencyRestoreProcess) {
    return
  }

  $displaySwitchPath = Join-Path $env:windir "System32\DisplaySwitch.exe"
  $escapedDisplaySwitchPath = $displaySwitchPath.Replace("'", "''")
  $script:EmergencyRunOncePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
  $script:EmergencyRunOnceName = "TopologyDdcciEmergencyRestore"
  New-Item -Path $script:EmergencyRunOncePath -Force | Out-Null
  New-ItemProperty `
    -Path $script:EmergencyRunOncePath `
    -Name $script:EmergencyRunOnceName `
    -Value ('"{0}" /extend' -f $displaySwitchPath) `
    -PropertyType String `
    -Force `
    -ErrorAction Stop | Out-Null

  $escapedRunOncePath = $script:EmergencyRunOncePath.Replace("'", "''")
  $escapedRunOnceName = $script:EmergencyRunOnceName.Replace("'", "''")
  $watchdogCommand = "Start-Sleep -Seconds $EmergencyRestoreSeconds; Remove-ItemProperty -LiteralPath '$escapedRunOncePath' -Name '$escapedRunOnceName' -ErrorAction SilentlyContinue; Start-Process -FilePath '$escapedDisplaySwitchPath' -ArgumentList '/extend' -WindowStyle Hidden"
  $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($watchdogCommand))
  $powershellPath = $null
  try {
    $powershellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  } catch {
    $powershellPath = $null
  }
  if ([string]::IsNullOrWhiteSpace($powershellPath) -or -not (Test-Path -LiteralPath $powershellPath)) {
    $powershellPath = Join-Path $PSHOME "powershell.exe"
  }
  $watchdogArguments = "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedCommand"

  try {
    $script:EmergencyRestoreProcess = Start-Process `
      -FilePath $powershellPath `
      -ArgumentList $watchdogArguments `
      -WindowStyle Hidden `
      -PassThru `
      -ErrorAction Stop
  } catch {
    Remove-ItemProperty -Path $script:EmergencyRunOncePath -Name $script:EmergencyRunOnceName -ErrorAction SilentlyContinue
    throw
  }
  Log "Emergency DisplaySwitch watchdog armed. ProcessId=$($script:EmergencyRestoreProcess.Id) DelaySeconds=$EmergencyRestoreSeconds"
}

function Stop-EmergencyRestoreWatchdog {
  if (-not $script:EmergencyRestoreProcess) {
    return
  }

  try {
    if (-not $script:EmergencyRestoreProcess.HasExited) {
      Stop-Process -Id $script:EmergencyRestoreProcess.Id -Force -ErrorAction Stop
      Log "Emergency DisplaySwitch watchdog cancelled. ProcessId=$($script:EmergencyRestoreProcess.Id)"
    }
  } catch {
    Log ("Could not cancel emergency DisplaySwitch watchdog: {0}" -f $_.Exception.Message)
  } finally {
    if ($script:EmergencyRunOncePath -and $script:EmergencyRunOnceName) {
      Remove-ItemProperty -Path $script:EmergencyRunOncePath -Name $script:EmergencyRunOnceName -ErrorAction SilentlyContinue
    }
    $script:EmergencyRestoreProcess = $null
    $script:EmergencyRunOncePath = $null
    $script:EmergencyRunOnceName = $null
  }
}

function Apply-TopologyDdcciSleep {
  if ($script:State -notin @("Idle", "PendingApply")) {
    Log "Topology/DDC sleep workaround is not idle; skipping apply. State=$script:State"
    return
  }

  Log "Applying topology/DDC sleep workaround."
  $script:State = "Applying"
  try {
    $currentPreview = Get-TargetMatchPreview
    if ($currentPreview.MatchedPathCount -eq 0) {
      throw "No active path matched target criteria at apply time: $($currentPreview.Criteria)"
    }
    if ($currentPreview.KeptPathCount -eq 0 -and -not $ExperimentalAllowZeroActivePaths) {
      throw "Applying the configured target would remove every active display path."
    }
    $script:TargetMatchPreview = $currentPreview

    Log-AdapterState
    Log-Block "DisplayConfig before apply" ([TopologyDdcciDisplayConfigV2.PathControl]::DumpActive())

    $removingLastActivePath = $script:TargetMatchPreview.KeptPathCount -eq 0
    if ($removingLastActivePath) {
      Start-EmergencyRestoreWatchdog
      Log "EXPERIMENTAL: validating and applying a zero-active-path topology."
    }

    Log "Saving topology without target criteria '$(Get-TargetCriteriaSummary)' to CCD database."
    try {
      $removeResult = [TopologyDdcciDisplayConfigV2.PathControl]::RemoveTargetMatching([string[]]$TargetNeedles, [int]$TargetId, [int]$TargetOutputTechnology, $true, [bool]$ExperimentalAllowZeroActivePaths)
      $script:TopologyRemoved = $true
      Log-Block "Remove result" $removeResult
    } catch {
      if ($removingLastActivePath) {
        Stop-EmergencyRestoreWatchdog
      }
      throw
    }

    Start-Sleep -Milliseconds 800
    try {
      Log-Block "DisplayConfig after target removal" ([TopologyDdcciDisplayConfigV2.PathControl]::DumpActive())
    } catch {
      Log ("DisplayConfig dump after target removal failed: {0}" -f $_.Exception.Message)
    }

    Invoke-RemainingDisplayDdcPowerOff

    $script:State = "Active"
    if ($script:AutoRestoreTimer -and $AutoRestoreAfterSeconds -gt 0) {
      Log "Auto restore armed in $AutoRestoreAfterSeconds seconds."
      $script:AutoRestoreTimer.Start()
    }

    if ($script:PendingWake) {
      Log "Wake was received while applying; restoring immediately after apply."
      Restore-TopologyDdcciSleep -Reason "pending wake after apply"
    }
  } catch {
    Log ("Apply failed: {0}" -f $_.Exception.Message)
    Restore-TopologyDdcciSleep -Reason "apply failure cleanup" -Force -SkipWakeDebounce
  }
}

function Restore-OriginalDisplayConfigWithRetry {
  $attempts = [Math]::Max(1, $DisplayRestoreRetryCount)
  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    try {
      Log "Restoring original DisplayConfig paths and saving to database. Attempt=$attempt/$attempts"
      Log ([TopologyDdcciDisplayConfigV2.PathControl]::RestoreOriginal($true))
      return $true
    } catch {
      Log ("SetDisplayConfig restore failed. Attempt={0}/{1} Error={2}" -f $attempt, $attempts, $_.Exception.Message)
      if ($attempt -lt $attempts) {
        Start-Sleep -Milliseconds ([Math]::Max(1, $DisplayRestoreRetryDelayMilliseconds))
      }
    }
  }

  try {
    Log "Fallback: running DisplaySwitch.exe /extend"
    Start-Process -FilePath "$env:windir\System32\DisplaySwitch.exe" -ArgumentList "/extend" -WindowStyle Hidden
  } catch {
    Log ("DisplaySwitch fallback failed: {0}" -f $_.Exception.Message)
  }
  return $false
}

function Restore-DdcPowerWithRetry {
  if (-not $script:DdcPowerDeviceNames -or $script:DdcPowerDeviceNames.Count -eq 0) {
    Log "No successful DDC/CI power-off device names were recorded; skipping DDC/CI power-on restore."
    return $true
  }

  $attempts = [Math]::Max(1, $DdcPowerOnRetryCount)
  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    try {
      Log "Restoring DDC/CI VCP D6=0x01 power on for recorded remaining display(s). Attempt=$attempt/$attempts"
      $allOk = $true
      foreach ($deviceName in $script:DdcPowerDeviceNames) {
        $results = @([TopologyDdcciDisplayConfig.DdcciPowerGeneric]::SetLogicalPower($deviceName, 0x01))
        foreach ($result in $results) {
          Log ("Remaining display DDC/CI on result: " + (Format-DdcResult $result))
          if (-not $result.Success) {
            $allOk = $false
          }
        }
      }
      if ($allOk) {
        return $true
      }
    } catch {
      Log ("DDC/CI power-on restore failed. Attempt={0}/{1} Error={2}" -f $attempt, $attempts, $_.Exception.Message)
    }

    if ($attempt -lt $attempts) {
      Start-Sleep -Milliseconds ([Math]::Max(1, $DdcPowerOnRetryDelayMilliseconds))
    }
  }
  return $false
}

function Schedule-RestoreAfterWakeDebounce {
  param([string]$Reason = "unspecified")

  if ($script:State -eq "PendingApply") {
    Log "Debounced wake cancels pending apply immediately. Reason=$Reason"
    Restore-TopologyDdcciSleep -Reason "$Reason pending apply cancel" -Force -SkipWakeDebounce
    return
  }

  if ($script:State -eq "Applying") {
    Log "Debounced wake received while apply is running; restore will run after apply finishes. Reason=$Reason"
    $script:PendingWake = $true
    return
  }

  if (-not $script:SleepCycleStarted -and -not $script:TopologyRemoved -and -not $script:DdcPowerOffSent -and -not $script:DdcPowerOffAttempted) {
    Log "Debounced wake has no active sleep-cycle state; ignoring. Reason=$Reason State=$script:State"
    return
  }

  $delayMs = 1
  if ($script:WakeIgnoreUntil) {
    $remaining = [int][Math]::Ceiling(($script:WakeIgnoreUntil - (Get-Date)).TotalMilliseconds)
    $delayMs = [Math]::Max(1, $remaining + 100)
  }

  if ($script:DebouncedRestoreTimer) {
    $script:DebouncedRestoreTimer.Stop()
    $script:DebouncedRestoreTimer.Interval = $delayMs
    $script:DebouncedRestoreReason = $Reason
    $script:DebouncedRestoreTimer.Start()
    Log "Debounced wake scheduled restore in ${delayMs}ms. Reason=$Reason State=$script:State"
  } else {
    Log "Debounced wake fallback wait ${delayMs}ms before restore. Reason=$Reason State=$script:State"
    Start-Sleep -Milliseconds $delayMs
    Restore-TopologyDdcciSleep -Reason "$Reason debounced wake elapsed" -Force -SkipWakeDebounce
  }
}

function Restore-TopologyDdcciSleep {
  param(
    [string]$Reason = "unspecified",
    [switch]$Force,
    [switch]$SkipWakeDebounce
  )

  $isPowerWake = $Reason -eq "ConsoleDisplayState=1" -or $Reason -eq "MonitorPowerOn=1"
  if (-not $SkipWakeDebounce -and $isPowerWake -and $script:WakeIgnoreUntil -and (Get-Date) -lt $script:WakeIgnoreUntil) {
    Log "Wake arrived inside debounce window; scheduling recovery instead of ignoring. Reason=$Reason IgnoreUntil=$($script:WakeIgnoreUntil.ToString('HH:mm:ss.fff')) State=$script:State"
    Schedule-RestoreAfterWakeDebounce -Reason $Reason
    return
  }

  if ($script:ApplyTimer) {
    $script:ApplyTimer.Stop()
  }
  if ($script:AutoRestoreTimer) {
    $script:AutoRestoreTimer.Stop()
  }
  if ($script:DebouncedRestoreTimer) {
    $script:DebouncedRestoreTimer.Stop()
  }

  if ($script:State -eq "PendingApply") {
    Log "Restore requested while apply was pending; cancelling pending apply. Reason=$Reason"
    $script:State = "Idle"
    $script:SleepCycleStarted = $false
    $script:IdleCycleLastInputTick = $null
    $script:PendingWake = $false
    if ($TestOnce) {
      Complete-TestOnce "TestOnce complete before workaround apply; exiting listener."
    }
    return
  }

  if ($script:State -eq "Applying" -and -not $Force) {
    Log "Restore requested while apply is running; deferring restore. Reason=$Reason"
    $script:PendingWake = $true
    return
  }
  if ($script:State -eq "Applying" -and $Force) {
    Log "Force restore requested while apply is running; continuing cleanup. Reason=$Reason"
  }

  if ($script:State -eq "Restoring") {
    Log "Restore requested while restore is already running; ignoring duplicate. Reason=$Reason"
    return
  }

  if ($script:State -eq "Idle" -and -not $script:SleepCycleStarted -and -not $script:TopologyRemoved -and -not $script:DdcPowerOffSent -and -not $script:DdcPowerOffAttempted) {
    Log "Restore requested before any sleep cycle; ignoring. Reason=$Reason"
    return
  }

  Log "Restoring topology/DDC sleep workaround. Reason=$Reason"
  $script:State = "Restoring"

  if ($isPowerWake -and $RestoreWakeDelayMilliseconds -gt 0) {
    Log "Waiting ${RestoreWakeDelayMilliseconds}ms before restore so display handles can settle."
    Start-Sleep -Milliseconds $RestoreWakeDelayMilliseconds
  }

  if ($script:TopologyRemoved) {
    if (Restore-OriginalDisplayConfigWithRetry) {
      $script:TopologyRemoved = $false
      Stop-EmergencyRestoreWatchdog
    }
  }

  if ($script:DdcPowerOffSent -or $script:DdcPowerOffAttempted) {
    if (Restore-DdcPowerWithRetry) {
      $script:DdcPowerOffSent = $false
      $script:DdcPowerOffAttempted = $false
      $script:DdcPowerDeviceNames = @()
    } else {
      Log "DDC/CI power-on did not succeed after retries; keeping pending flag for the next wake/restore event."
    }
  }

  Start-Sleep -Seconds 4
  try {
    Log-AdapterState
    Log-Block "DisplayConfig after restore" ([TopologyDdcciDisplayConfigV2.PathControl]::DumpActive())
  } catch {
    Log ("Post-restore state dump failed: {0}" -f $_.Exception.Message)
  }

  $script:SleepCycleStarted = $false
  $script:IdleCycleLastInputTick = $null
  $script:PendingWake = $false
  $script:WakeIgnoreUntil = $null
  $script:DebouncedRestoreReason = $null
  $script:State = "Idle"

  if ($TestOnce) {
    Complete-TestOnce "TestOnce complete after restore; exiting listener."
  }
}

function Schedule-TopologyDdcciSleep {
  param([string]$Reason = "display off")

  $script:SleepCycleStarted = $true
  if ($TriggerMode -eq "PowerEvent") {
    $script:WakeIgnoreUntil = (Get-Date).AddSeconds([Math]::Max(0, $WakeDebounceSeconds))
  } else {
    $script:WakeIgnoreUntil = $null
  }
  if ($script:DebouncedRestoreTimer) {
    $script:DebouncedRestoreTimer.Stop()
  }
  $script:DebouncedRestoreReason = $null
  if ($script:State -ne "Idle") {
    Log "Sleep trigger ignored because workaround state is $script:State. Reason=$Reason"
    return
  }

  if ($script:ApplyTimer.Enabled) {
    Log "Sleep trigger ignored because apply timer is already running. Reason=$Reason"
    return
  }

  if ($ApplyDelayMilliseconds -le 0) {
    Apply-TopologyDdcciSleep
  } else {
    $script:State = "PendingApply"
    Log "Sleep trigger received; applying topology/DDC sleep workaround in ${ApplyDelayMilliseconds}ms. Reason=$Reason"
    $script:ApplyTimer.Start()
  }
}

function Handle-PowerSetting {
  param(
    [string]$SettingGuid,
    [int]$Value
  )

  $guid = $SettingGuid.ToLowerInvariant()
  switch ($guid) {
    "6fe69556-704a-47a0-8f24-c28d936fda47" {
      Log "ConsoleDisplayState=$Value"
      if ($TriggerMode -eq "PowerEvent") {
        if ($Value -eq 0) { Schedule-TopologyDdcciSleep -Reason "ConsoleDisplayState=0" }
        elseif ($Value -eq 1) { Restore-TopologyDdcciSleep -Reason "ConsoleDisplayState=1" }
      }
    }
    "02731015-4510-4526-99e6-e517ebd1aea4" {
      Log "MonitorPowerOn=$Value"
      if ($TriggerMode -eq "PowerEvent") {
        if ($Value -eq 0) { Schedule-TopologyDdcciSleep -Reason "MonitorPowerOn=0" }
        elseif ($Value -eq 1) { Restore-TopologyDdcciSleep -Reason "MonitorPowerOn=1" }
      }
    }
    default {
      Log "PowerSetting $SettingGuid=$Value"
    }
  }
}

if ($Listen) {
  $script:State = "Idle"
  $script:SleepCycleStarted = $false
  $script:TopologyRemoved = $false
  $script:DdcPowerOffSent = $false
  $script:DdcPowerOffAttempted = $false
  $script:DdcPowerDeviceNames = @()
  $script:PendingWake = $false
  $script:WakeIgnoreUntil = $null
  $script:DebouncedRestoreReason = $null
  $script:IdleCycleLastInputTick = $null
  $script:EffectiveIdleTimeoutSeconds = $null
  $script:EffectiveIdleTimeoutSource = $null
  $script:IdleTimeoutLastRefresh = $null
  $script:DisplayRequiredSet = $false
  $script:EmergencyRestoreProcess = $null
  $script:EmergencyRunOncePath = $null
  $script:EmergencyRunOnceName = $null
  $script:TestOnceCompleted = $false

  $script:ApplyTimer = New-Object System.Windows.Forms.Timer
  $script:ApplyTimer.Interval = [Math]::Max(1, $ApplyDelayMilliseconds)
  $script:ApplyTimer.add_Tick({
    $script:ApplyTimer.Stop()
    Apply-TopologyDdcciSleep
  })

  $script:AutoRestoreTimer = $null
  if ($AutoRestoreAfterSeconds -gt 0) {
    $script:AutoRestoreTimer = New-Object System.Windows.Forms.Timer
    $script:AutoRestoreTimer.Interval = [Math]::Max(1, $AutoRestoreAfterSeconds) * 1000
    $script:AutoRestoreTimer.add_Tick({
      Restore-TopologyDdcciSleep -Reason "AutoRestoreAfterSeconds elapsed"
    })
  }

  $script:DebouncedRestoreTimer = New-Object System.Windows.Forms.Timer
  $script:DebouncedRestoreTimer.Interval = 1
  $script:DebouncedRestoreTimer.add_Tick({
    $script:DebouncedRestoreTimer.Stop()
    $reason = $script:DebouncedRestoreReason
    if ([string]::IsNullOrWhiteSpace($reason)) {
      $reason = "debounced wake"
    }
    Restore-TopologyDdcciSleep -Reason "$reason debounced wake elapsed" -Force -SkipWakeDebounce
  })

  $script:IdlePreemptTimer = $null
  if ($TriggerMode -eq "IdlePreempt") {
    Update-EffectiveIdleTimeout
    $script:IdlePreemptTimer = New-Object System.Windows.Forms.Timer
    $script:IdlePreemptTimer.Interval = $IdlePollMilliseconds
    $script:IdlePreemptTimer.add_Tick({
      Invoke-IdlePreemptPoll
    })
  }

  $triggerTimer = $null
  if ($TriggerMode -eq "PowerEvent" -and $TriggerDpmsAfterSeconds -gt 0) {
    $triggerTimer = New-Object System.Windows.Forms.Timer
    $triggerTimer.Interval = [Math]::Max(1, $TriggerDpmsAfterSeconds) * 1000
    $triggerTimer.add_Tick({
      $triggerTimer.Stop()
      Log "TriggerDpmsAfterSeconds elapsed; sending Windows DPMS off for listener test."
      Send-DpmsOff
    })
  }

  $window = New-Object TopologyDdcciDisplayConfig.PowerSettingWindow
  $window.Callback = [System.Action[string,int]]{
    param($settingGuid, $value)
    Handle-PowerSetting -SettingGuid $settingGuid -Value $value
  }

  try {
    $consoleGuid = [Guid]"6fe69556-704a-47a0-8f24-c28d936fda47"
    $monitorGuid = [Guid]"02731015-4510-4526-99e6-e517ebd1aea4"
    $window.Register($consoleGuid, $monitorGuid)

    if ($TriggerMode -eq "IdlePreempt") {
      [TopologyDdcciIdleControlV1.IdleControl]::SetDisplayRequired($true)
      $script:DisplayRequiredSet = $true
    }

    Log "$ProfileName topology/DDC listener started. Log: $script:LogPath"
    Log "ProfileName=$ProfileName TargetCriteria=$(Get-TargetCriteriaSummary) TriggerMode=$TriggerMode IdleTimeoutSeconds=$IdleTimeoutSeconds EffectiveIdleTimeoutSeconds=$script:EffectiveIdleTimeoutSeconds IdlePollMilliseconds=$IdlePollMilliseconds ExperimentalAllowZeroActivePaths=$ExperimentalAllowZeroActivePaths EmergencyRestoreSeconds=$EmergencyRestoreSeconds RemainingDisplayPowerMode=$RemainingDisplayPowerMode ApplyDelayMilliseconds=$ApplyDelayMilliseconds WakeDebounceSeconds=$WakeDebounceSeconds RestoreWakeDelayMilliseconds=$RestoreWakeDelayMilliseconds DisplayRestoreRetryCount=$DisplayRestoreRetryCount DdcPowerOnRetryCount=$DdcPowerOnRetryCount TestOnce=$TestOnce TriggerDpmsAfterSeconds=$TriggerDpmsAfterSeconds AutoRestoreAfterSeconds=$AutoRestoreAfterSeconds"
    Log ("Target preflight: activePaths={0} matchedPaths={1} keptPaths={2}" -f $script:TargetMatchPreview.ActivePathCount, $script:TargetMatchPreview.MatchedPathCount, $script:TargetMatchPreview.KeptPathCount)

    if ($script:IdlePreemptTimer) {
      Log "IdlePreempt is active; Windows global display timeout is being held off while this listener manages display sleep."
      $script:IdlePreemptTimer.Start()
    } else {
      Log "PowerEvent native mode is active; listening for Windows ConsoleDisplayState and MonitorPowerOn changes."
    }

    if ($triggerTimer) {
      Log "Test trigger armed: DPMS off in $TriggerDpmsAfterSeconds seconds."
      $triggerTimer.Start()
    }

    [System.Windows.Forms.Application]::Run()
  }
  finally {
    if ($triggerTimer) {
      $triggerTimer.Stop()
    }
    if ($script:ApplyTimer) {
      $script:ApplyTimer.Stop()
    }
    if ($script:AutoRestoreTimer) {
      $script:AutoRestoreTimer.Stop()
    }
    if ($script:DebouncedRestoreTimer) {
      $script:DebouncedRestoreTimer.Stop()
    }
    if ($script:IdlePreemptTimer) {
      $script:IdlePreemptTimer.Stop()
    }
    if ($script:State -ne "Idle" -or $script:TopologyRemoved -or $script:DdcPowerOffSent -or $script:DdcPowerOffAttempted) {
      Restore-TopologyDdcciSleep -Reason "listener exiting" -Force -SkipWakeDebounce
    }
    if (-not $script:TopologyRemoved) {
      Stop-EmergencyRestoreWatchdog
    }
    if ($script:DisplayRequiredSet) {
      try {
        [TopologyDdcciIdleControlV1.IdleControl]::SetDisplayRequired($false)
        $script:DisplayRequiredSet = $false
      } catch {
        Log ("Could not clear the display-required execution state: {0}" -f $_.Exception.Message)
      }
    }
    if ($triggerTimer) {
      $triggerTimer.Dispose()
    }
    if ($script:ApplyTimer) {
      $script:ApplyTimer.Dispose()
    }
    if ($script:AutoRestoreTimer) {
      $script:AutoRestoreTimer.Dispose()
    }
    if ($script:DebouncedRestoreTimer) {
      $script:DebouncedRestoreTimer.Dispose()
    }
    if ($script:IdlePreemptTimer) {
      $script:IdlePreemptTimer.Dispose()
    }
    if ($window) {
      $window.Dispose()
    }
    Log "$ProfileName topology/DDC listener stopped."
  }
  exit 0
}

$restored = $false
try {
  Log "Starting DisplayConfig remove-output test. ProfileName=$ProfileName TargetCriteria=$(Get-TargetCriteriaSummary) ObserveSeconds=$ObserveSeconds NoDpms=$NoDpms KeepRemoved=$KeepRemoved SaveToDatabase=$SaveToDatabase RemainingDisplayPowerMode=$RemainingDisplayPowerMode DdcciRemainingOff=$DdcciRemainingOff"
  Log-AdapterState
  Log-Block "DisplayConfig before remove" ([TopologyDdcciDisplayConfigV2.PathControl]::DumpActive())

  Log "Removing target active display path via SetDisplayConfig. Display adapters should remain enabled."
  Log-Block "Remove result" ([TopologyDdcciDisplayConfigV2.PathControl]::RemoveTargetMatching([string[]]$TargetNeedles, [int]$TargetId, [int]$TargetOutputTechnology, [bool]$SaveToDatabase))
  $script:TopologyRemoved = $true

  Start-Sleep -Seconds 3
  Log-AdapterState
  Log-Block "DisplayConfig after remove" ([TopologyDdcciDisplayConfigV2.PathControl]::DumpActive())

  if ($DdcciRemainingOff -or $RemainingDisplayPowerMode -ne "Disabled") {
    Invoke-RemainingDisplayDdcPowerOff
  }

  if (-not $NoDpms) {
    Start-Sleep -Seconds ([Math]::Max(0, $DpmsAfterRemoveDelaySeconds))
    Log "Sending DPMS off after $ProfileName target path removal."
    [TopologyDdcciDisplayConfigV2.PathControl]::SendDpmsOff()
  }

  $elapsed = 0
  while ($elapsed -lt $ObserveSeconds) {
    Start-Sleep -Seconds ([Math]::Min(15, $ObserveSeconds - $elapsed))
    $elapsed += [Math]::Min(15, $ObserveSeconds - $elapsed)
    Log "Observation marker +${elapsed}s"
    try {
      Log-Block "DisplayConfig marker +${elapsed}s" ([TopologyDdcciDisplayConfigV2.PathControl]::DumpActive())
    } catch {
      Log ("DisplayConfig marker dump failed: {0}" -f $_.Exception.Message)
    }
  }
}
finally {
  if ($script:DdcPowerOffSent -or $script:DdcPowerOffAttempted) {
    try {
      Restore-DdcPowerWithRetry | Out-Null
    } catch {
      Log ("DDC/CI power-on restore failed: {0}" -f $_.Exception.Message)
      Log "Moving mouse by 1 pixel as fallback wake signal."
      [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(([System.Windows.Forms.Cursor]::Position.X + 1), [System.Windows.Forms.Cursor]::Position.Y)
    }
  }

  if (-not $KeepRemoved) {
    try {
      Log "Restoring original DisplayConfig paths."
      Log ([TopologyDdcciDisplayConfigV2.PathControl]::RestoreOriginal([bool]$SaveToDatabase))
      $restored = $true
    } catch {
      Log ("SetDisplayConfig restore failed: {0}" -f $_.Exception.Message)
      Log "Fallback: running DisplaySwitch.exe /extend"
      Start-Process -FilePath "$env:windir\System32\DisplaySwitch.exe" -ArgumentList "/extend" -WindowStyle Hidden
    }

    Start-Sleep -Seconds 5
    Log-AdapterState
    try {
      Log-Block "DisplayConfig after restore" ([TopologyDdcciDisplayConfigV2.PathControl]::DumpActive())
    } catch {
      Log ("DisplayConfig dump after restore failed: {0}" -f $_.Exception.Message)
    }
  } else {
    Log "KeepRemoved was specified; original DisplayConfig was not restored by this script."
  }

  Log "Done. Log: $script:LogPath"
}
