[CmdletBinding()]
param(
  [string]$OutputPath = "",

  [switch]$IncludeAllPaths
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$logRoot = Join-Path $projectRoot "log\diagnostics"
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $logRoot ("displayconfig-anchor-candidates-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

$outputParent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputParent)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

function Write-InspectionLog {
  param([string]$Message)

  $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
  Write-Host $line
  Add-Content -LiteralPath $OutputPath -Value $line -Encoding UTF8
}

if (-not ("TopologyDdcciAnchorInspectionV3.PathInspector" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace TopologyDdcciAnchorInspectionV3 {
  public static class PathInspector {
    private const uint QDC_ALL_PATHS = 0x00000001;
    private const int ERROR_SUCCESS = 0;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;
    private const uint DISPLAYCONFIG_PATH_ACTIVE = 0x00000001;
    private const uint DISPLAYCONFIG_SOURCE_IN_USE = 0x00000001;
    private const uint DISPLAYCONFIG_TARGET_IN_USE = 0x00000001;
    private const uint DISPLAYCONFIG_TARGET_FORCIBLE = 0x00000002;
    private const uint DISPLAYCONFIG_TARGET_FORCED_AVAILABILITY_BOOT = 0x00000004;
    private const uint DISPLAYCONFIG_TARGET_FORCED_AVAILABILITY_PATH = 0x00000008;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_PREFERRED_MODE = 3;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME = 4;
    private const uint DISPLAYCONFIG_PATH_MODE_IDX_INVALID = 0xFFFFFFFF;
    private const uint DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE = 1;
    private const uint DISPLAYCONFIG_MODE_INFO_TYPE_TARGET = 2;

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
    public struct DISPLAYCONFIG_SOURCE_DEVICE_NAME {
      public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
      public string viewGdiDeviceName;
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_ADAPTER_NAME {
      public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
      public string adapterDevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_TARGET_PREFERRED_MODE {
      public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
      public uint width;
      public uint height;
      public DISPLAYCONFIG_TARGET_MODE targetMode;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray, ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_ADAPTER_NAME requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_PREFERRED_MODE requestPacket);

    private static void ThrowIfWin32Error(int error, string operation) {
      if (error != ERROR_SUCCESS) {
        throw new Win32Exception(error, operation + " failed with Win32 error " + error);
      }
    }

    private static void QueryAll(out DISPLAYCONFIG_PATH_INFO[] paths, out DISPLAYCONFIG_MODE_INFO[] modes) {
      for (int attempt = 1; attempt <= 5; attempt++) {
        uint pathCount;
        uint modeCount;
        int sizeError = GetDisplayConfigBufferSizes(QDC_ALL_PATHS, out pathCount, out modeCount);
        ThrowIfWin32Error(sizeError, "GetDisplayConfigBufferSizes(QDC_ALL_PATHS)");

        DISPLAYCONFIG_PATH_INFO[] pathBuffer = new DISPLAYCONFIG_PATH_INFO[pathCount];
        DISPLAYCONFIG_MODE_INFO[] modeBuffer = new DISPLAYCONFIG_MODE_INFO[modeCount];
        int queryError = QueryDisplayConfig(QDC_ALL_PATHS, ref pathCount, pathBuffer, ref modeCount, modeBuffer, IntPtr.Zero);
        if (queryError == ERROR_INSUFFICIENT_BUFFER && attempt < 5) {
          continue;
        }
        ThrowIfWin32Error(queryError, "QueryDisplayConfig(QDC_ALL_PATHS)");

        paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
        Array.Copy(pathBuffer, paths, pathCount);
        Array.Copy(modeBuffer, modes, modeCount);
        return;
      }
      throw new InvalidOperationException("QueryDisplayConfig(QDC_ALL_PATHS) retry limit was reached.");
    }

    private static string GetAdapterName(LUID adapterId) {
      DISPLAYCONFIG_ADAPTER_NAME request = new DISPLAYCONFIG_ADAPTER_NAME();
      request.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME;
      request.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_ADAPTER_NAME));
      request.header.adapterId = adapterId;
      int error = DisplayConfigGetDeviceInfo(ref request);
      return error == ERROR_SUCCESS ? (request.adapterDevicePath ?? "") : "<adapter-name-error:" + error + ">";
    }

    private static string GetSourceName(DISPLAYCONFIG_PATH_INFO path) {
      DISPLAYCONFIG_SOURCE_DEVICE_NAME request = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
      request.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
      request.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME));
      request.header.adapterId = path.sourceInfo.adapterId;
      request.header.id = path.sourceInfo.id;
      int error = DisplayConfigGetDeviceInfo(ref request);
      return error == ERROR_SUCCESS ? (request.viewGdiDeviceName ?? "") : "<source-name-error:" + error + ">";
    }

    private static DISPLAYCONFIG_TARGET_DEVICE_NAME GetTargetName(DISPLAYCONFIG_PATH_INFO path, out int error) {
      DISPLAYCONFIG_TARGET_DEVICE_NAME request = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
      request.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
      request.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
      request.header.adapterId = path.targetInfo.adapterId;
      request.header.id = path.targetInfo.id;
      error = DisplayConfigGetDeviceInfo(ref request);
      return request;
    }

    private static string GetPreferredMode(DISPLAYCONFIG_PATH_INFO path) {
      DISPLAYCONFIG_TARGET_PREFERRED_MODE request = new DISPLAYCONFIG_TARGET_PREFERRED_MODE();
      request.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_PREFERRED_MODE;
      request.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_PREFERRED_MODE));
      request.header.adapterId = path.targetInfo.adapterId;
      request.header.id = path.targetInfo.id;
      int error = DisplayConfigGetDeviceInfo(ref request);
      if (error != ERROR_SUCCESS) {
        return "<preferred-mode-error:" + error + ">";
      }
      DISPLAYCONFIG_VIDEO_SIGNAL_INFO signal = request.targetMode.targetVideoSignalInfo;
      return request.width + "x" + request.height + " signal=" + signal.activeSize.cx + "x" + signal.activeSize.cy + " v=" + signal.vSyncFreq;
    }

    private static string TargetKey(DISPLAYCONFIG_PATH_INFO path) {
      return path.targetInfo.adapterId + ":" + path.targetInfo.id;
    }

    public static string Inspect(bool includeAllPaths) {
      DISPLAYCONFIG_PATH_INFO[] paths;
      DISPLAYCONFIG_MODE_INFO[] modes;
      QueryAll(out paths, out modes);

      HashSet<string> activeTargets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      for (int i = 0; i < paths.Length; i++) {
        if ((paths[i].flags & DISPLAYCONFIG_PATH_ACTIVE) != 0) {
          activeTargets.Add(TargetKey(paths[i]));
        }
      }

      HashSet<string> emittedCandidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      HashSet<string> emittedAnchors = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      List<string> candidates = new List<string>();
      List<string> anchors = new List<string>();
      StringBuilder result = new StringBuilder();
      int suppressedPaths = 0;
      result.AppendLine("allPaths=" + paths.Length + " modes=" + modes.Length + " activeTargets=" + activeTargets.Count);

      for (int i = 0; i < paths.Length; i++) {
        DISPLAYCONFIG_PATH_INFO path = paths[i];
        bool active = (path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0;
        bool sourceInUse = (path.sourceInfo.statusFlags & DISPLAYCONFIG_SOURCE_IN_USE) != 0;
        bool targetInUse = (path.targetInfo.statusFlags & DISPLAYCONFIG_TARGET_IN_USE) != 0;
        bool forcible = (path.targetInfo.statusFlags & DISPLAYCONFIG_TARGET_FORCIBLE) != 0;
        bool forcedBoot = (path.targetInfo.statusFlags & DISPLAYCONFIG_TARGET_FORCED_AVAILABILITY_BOOT) != 0;
        bool forcedPath = (path.targetInfo.statusFlags & DISPLAYCONFIG_TARGET_FORCED_AVAILABILITY_PATH) != 0;
        string targetKey = TargetKey(path);
        int targetNameError;
        DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = GetTargetName(path, out targetNameError);
        string friendlyName = targetNameError == ERROR_SUCCESS ? (targetName.monitorFriendlyDeviceName ?? "") : "<target-name-error:" + targetNameError + ">";
        string monitorPath = targetNameError == ERROR_SUCCESS ? (targetName.monitorDevicePath ?? "") : "";
        string adapterPath = GetAdapterName(path.targetInfo.adapterId);

        if (includeAllPaths || active) {
          result.Append("PATH ").Append(i)
            .Append(" active=").Append(active)
            .Append(" targetAvailable=").Append(path.targetInfo.targetAvailable)
            .Append(" sourceInUse=").Append(sourceInUse)
            .Append(" targetInUse=").Append(targetInUse)
            .Append(" forcible=").Append(forcible)
            .Append(" forcedBoot=").Append(forcedBoot)
            .Append(" forcedPath=").Append(forcedPath)
            .Append(" srcAdapter=").Append(path.sourceInfo.adapterId)
            .Append(" srcId=").Append(path.sourceInfo.id)
            .Append(" sourceName=").Append(GetSourceName(path))
            .Append(" targetAdapter=").Append(path.targetInfo.adapterId)
            .Append(" targetId=").Append(path.targetInfo.id)
            .Append(" outputTech=").Append(path.targetInfo.outputTechnology)
            .Append(" targetKey=").Append(targetKey)
            .Append(" friendly=").Append(friendlyName)
            .Append(" monitorPath=").Append(monitorPath)
            .Append(" adapterPath=").Append(adapterPath)
            .Append(" preferredMode=").Append(GetPreferredMode(path))
            .AppendLine();
        } else {
          suppressedPaths++;
        }

        bool candidate = !activeTargets.Contains(targetKey) && !active && (path.targetInfo.targetAvailable || forcible);
        if (candidate && emittedCandidates.Add(targetKey)) {
          string reason = path.targetInfo.targetAvailable ? "targetAvailable" : "forcible";
          candidates.Add("CANDIDATE targetKey=" + targetKey + " reason=" + reason + " srcAdapter=" + path.sourceInfo.adapterId + " srcId=" + path.sourceInfo.id + " targetId=" + path.targetInfo.id + " outputTech=" + path.targetInfo.outputTechnology + " friendly=" + friendlyName + " monitorPath=" + monitorPath + " adapterPath=" + adapterPath);
        }

        bool topologyAnchor = adapterPath.IndexOf("TopologyDdcciAnchor", StringComparison.OrdinalIgnoreCase) >= 0;
        if (topologyAnchor && emittedAnchors.Add(targetKey)) {
          anchors.Add("ANCHOR targetKey=" + targetKey + " active=" + active + " targetAvailable=" + path.targetInfo.targetAvailable + " forcible=" + forcible + " srcAdapter=" + path.sourceInfo.adapterId + " srcId=" + path.sourceInfo.id + " targetId=" + path.targetInfo.id + " outputTech=" + path.targetInfo.outputTechnology + " friendly=" + friendlyName + " monitorPath=" + monitorPath + " adapterPath=" + adapterPath);
        }
      }

      if (suppressedPaths > 0) {
        result.AppendLine("suppressedInactivePaths=" + suppressedPaths + " (use -IncludeAllPaths for full path output)");
      }
      result.AppendLine("topologyAnchorTargets=" + anchors.Count);
      foreach (string anchor in anchors) {
        result.AppendLine(anchor);
      }
      result.AppendLine("candidateTargets=" + candidates.Count);
      foreach (string candidate in candidates) {
        result.AppendLine(candidate);
      }
      if (candidates.Count == 0) {
        result.AppendLine("NO_CANDIDATE No inactive target is currently available or forceable. A virtual-display driver or physical dummy target would be required for an anchor.");
      }
      return result.ToString();
    }
  }
}
"@
}

Write-InspectionLog "DisplayConfig anchor-candidate inspection started. This command is read-only."
Write-InspectionLog "QDC_ALL_PATHS can take several seconds on systems with many adapters."
try {
  foreach ($line in (([TopologyDdcciAnchorInspectionV3.PathInspector]::Inspect([bool]$IncludeAllPaths) -split "`r?`n") | Where-Object { $_ -ne "" })) {
    Write-InspectionLog $line
  }

  Write-InspectionLog "PnP display and monitor devices"
  Get-PnpDevice -Class Display, Monitor |
    Sort-Object Class, FriendlyName |
    ForEach-Object {
      Write-InspectionLog ("PNP status={0} class={1} friendly={2} instance={3}" -f $_.Status, $_.Class, $_.FriendlyName, $_.InstanceId)
    }
} catch {
  Write-InspectionLog "Inspection failed: $($_.Exception.Message)"
  throw
} finally {
  Write-InspectionLog "Inspection finished. Log=$OutputPath"
}
