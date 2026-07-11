using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace TopologyDdcci.SuppliedModeV2
{
    public static class ModeControl
    {
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
        private const uint SDC_ALLOW_CHANGES = 0x00000400;

        private static DISPLAYCONFIG_PATH_INFO[] originalPaths;
        private static DISPLAYCONFIG_MODE_INFO[] originalModes;
        private static bool abiChecked;

        [StructLayout(LayoutKind.Sequential)]
        public struct LUID
        {
            public uint LowPart;
            public int HighPart;

            public override string ToString()
            {
                return HighPart.ToString("X8") + ":" + LowPart.ToString("X8");
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_RATIONAL
        {
            public uint Numerator;
            public uint Denominator;

            public double Value
            {
                get { return Denominator == 0 ? 0 : (double)Numerator / Denominator; }
            }

            public override string ToString()
            {
                return Numerator + "/" + Denominator + "=" + Value.ToString("F6");
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_2DREGION
        {
            public uint cx;
            public uint cy;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINTL
        {
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_SOURCE_INFO
        {
            public LUID adapterId;
            public uint id;
            public uint modeInfoIdx;
            public uint statusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_PATH_TARGET_INFO
        {
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
        public struct DISPLAYCONFIG_PATH_INFO
        {
            public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
            public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
            public uint flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO
        {
            public ulong pixelRate;
            public DISPLAYCONFIG_RATIONAL hSyncFreq;
            public DISPLAYCONFIG_RATIONAL vSyncFreq;
            public DISPLAYCONFIG_2DREGION activeSize;
            public DISPLAYCONFIG_2DREGION totalSize;
            public uint videoStandard;
            public uint scanLineOrdering;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_TARGET_MODE
        {
            public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_SOURCE_MODE
        {
            public uint width;
            public uint height;
            public uint pixelFormat;
            public POINTL position;
        }

        [StructLayout(LayoutKind.Explicit)]
        public struct DISPLAYCONFIG_MODE_INFO_UNION
        {
            [FieldOffset(0)]
            public DISPLAYCONFIG_TARGET_MODE targetMode;
            [FieldOffset(0)]
            public DISPLAYCONFIG_SOURCE_MODE sourceMode;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_MODE_INFO
        {
            public uint infoType;
            public uint id;
            public LUID adapterId;
            public DISPLAYCONFIG_MODE_INFO_UNION modeInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct DISPLAYCONFIG_DEVICE_INFO_HEADER
        {
            public uint type;
            public uint size;
            public LUID adapterId;
            public uint id;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DISPLAYCONFIG_TARGET_DEVICE_NAME
        {
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
        private static extern int GetDisplayConfigBufferSizes(
            uint flags,
            out uint numPathArrayElements,
            out uint numModeInfoArrayElements);

        [DllImport("user32.dll")]
        private static extern int QueryDisplayConfig(
            uint flags,
            ref uint numPathArrayElements,
            [Out] DISPLAYCONFIG_PATH_INFO[] pathArray,
            ref uint numModeInfoArrayElements,
            [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
            IntPtr currentTopologyId);

        [DllImport("user32.dll")]
        private static extern int SetDisplayConfig(
            uint numPathArrayElements,
            DISPLAYCONFIG_PATH_INFO[] pathArray,
            uint numModeInfoArrayElements,
            DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
            uint flags);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(
            ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);

        private static void ThrowIfWin32Error(int error, string operation)
        {
            if (error != ERROR_SUCCESS)
            {
                throw new Win32Exception(error, operation + " failed with Win32 error " + error);
            }
        }

        private static void EnsureAbi()
        {
            if (abiChecked)
            {
                return;
            }

            int pathSize = Marshal.SizeOf(typeof(DISPLAYCONFIG_PATH_INFO));
            int modeSize = Marshal.SizeOf(typeof(DISPLAYCONFIG_MODE_INFO));
            int targetNameSize = Marshal.SizeOf(
                typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
            if (pathSize != 72 || modeSize != 64 || targetNameSize != 420)
            {
                throw new InvalidOperationException(
                    "Unexpected DisplayConfig ABI sizes. path=" + pathSize +
                    " mode=" + modeSize + " targetName=" + targetNameSize);
            }
            abiChecked = true;
        }

        private static void QueryActive(
            out DISPLAYCONFIG_PATH_INFO[] paths,
            out DISPLAYCONFIG_MODE_INFO[] modes)
        {
            EnsureAbi();
            for (int attempt = 1; attempt <= 5; attempt++)
            {
                uint pathCount;
                uint modeCount;
                int sizeError = GetDisplayConfigBufferSizes(
                    QDC_ONLY_ACTIVE_PATHS,
                    out pathCount,
                    out modeCount);
                ThrowIfWin32Error(sizeError, "GetDisplayConfigBufferSizes");

                DISPLAYCONFIG_PATH_INFO[] pathBuffer =
                    new DISPLAYCONFIG_PATH_INFO[pathCount];
                DISPLAYCONFIG_MODE_INFO[] modeBuffer =
                    new DISPLAYCONFIG_MODE_INFO[modeCount];
                int queryError = QueryDisplayConfig(
                    QDC_ONLY_ACTIVE_PATHS,
                    ref pathCount,
                    pathBuffer,
                    ref modeCount,
                    modeBuffer,
                    IntPtr.Zero);
                if (queryError == ERROR_INSUFFICIENT_BUFFER && attempt < 5)
                {
                    continue;
                }
                ThrowIfWin32Error(queryError, "QueryDisplayConfig");

                paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
                modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
                Array.Copy(pathBuffer, paths, pathCount);
                Array.Copy(modeBuffer, modes, modeCount);
                return;
            }
            throw new InvalidOperationException(
                "QueryDisplayConfig retry limit was reached.");
        }

        private static DISPLAYCONFIG_TARGET_DEVICE_NAME GetTargetName(
            DISPLAYCONFIG_PATH_INFO path)
        {
            DISPLAYCONFIG_TARGET_DEVICE_NAME targetName =
                new DISPLAYCONFIG_TARGET_DEVICE_NAME();
            targetName.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            targetName.header.size = (uint)Marshal.SizeOf(
                typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
            targetName.header.adapterId = path.targetInfo.adapterId;
            targetName.header.id = path.targetInfo.id;
            int error = DisplayConfigGetDeviceInfo(ref targetName);
            ThrowIfWin32Error(error, "DisplayConfigGetDeviceInfo");
            return targetName;
        }

        private static DISPLAYCONFIG_PATH_INFO RequireSingleMatchingTarget(
            DISPLAYCONFIG_PATH_INFO[] paths,
            string targetNeedle)
        {
            if (paths.Length != 1)
            {
                throw new InvalidOperationException(
                    "This experiment requires exactly one active display path; found " +
                    paths.Length + ".");
            }
            if (String.IsNullOrWhiteSpace(targetNeedle))
            {
                throw new InvalidOperationException("TargetNeedle is required.");
            }

            DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = GetTargetName(paths[0]);
            string friendlyName = targetName.monitorFriendlyDeviceName ?? "";
            string devicePath = targetName.monitorDevicePath ?? "";
            if (friendlyName.IndexOf(targetNeedle, StringComparison.OrdinalIgnoreCase) < 0 &&
                devicePath.IndexOf(targetNeedle, StringComparison.OrdinalIgnoreCase) < 0)
            {
                throw new InvalidOperationException(
                    "The single active path does not match TargetNeedle='" +
                    targetNeedle + "'. Actual friendly='" + friendlyName +
                    "' path='" + devicePath + "'.");
            }
            return paths[0];
        }

        private static uint GetTargetModeIndex(
            DISPLAYCONFIG_PATH_INFO path,
            DISPLAYCONFIG_MODE_INFO[] modes)
        {
            uint index = path.targetInfo.modeInfoIdx;
            if (index == DISPLAYCONFIG_PATH_MODE_IDX_INVALID || index >= modes.Length)
            {
                throw new InvalidOperationException(
                    "The active target has no usable target mode index.");
            }
            if (modes[index].infoType != DISPLAYCONFIG_MODE_INFO_TYPE_TARGET)
            {
                throw new InvalidOperationException(
                    "The active target mode index does not reference a target mode.");
            }
            return index;
        }

        private static void ValidateRequestedTiming(
            DISPLAYCONFIG_VIDEO_SIGNAL_INFO current,
            ulong pixelRate,
            uint hSyncNumerator,
            uint hSyncDenominator,
            uint vSyncNumerator,
            uint vSyncDenominator)
        {
            if (pixelRate == 0 || hSyncNumerator == 0 || hSyncDenominator == 0 ||
                vSyncNumerator == 0 || vSyncDenominator == 0)
            {
                throw new ArgumentOutOfRangeException(
                    "All requested timing values must be nonzero.");
            }
            if (current.activeSize.cx == 0 || current.activeSize.cy == 0 ||
                current.totalSize.cx == 0 || current.totalSize.cy == 0)
            {
                throw new InvalidOperationException(
                    "The current target mode has incomplete active or total dimensions.");
            }

            ulong horizontalLeft = checked(pixelRate * hSyncDenominator);
            ulong horizontalRight = checked(
                (ulong)hSyncNumerator * current.totalSize.cx);
            if (horizontalLeft != horizontalRight)
            {
                throw new InvalidOperationException(
                    "Requested pixel rate and horizontal sync are inconsistent with " +
                    "the current horizontal total.");
            }

            ulong verticalLeft = checked(
                (ulong)hSyncNumerator * vSyncDenominator);
            ulong verticalRight = checked(
                (ulong)vSyncNumerator * hSyncDenominator * current.totalSize.cy);
            if (verticalLeft != verticalRight)
            {
                throw new InvalidOperationException(
                    "Requested horizontal and vertical sync are inconsistent with " +
                    "the current vertical total.");
            }
        }

        private static void BuildRequestedConfiguration(
            string targetNeedle,
            ulong pixelRate,
            uint hSyncNumerator,
            uint hSyncDenominator,
            uint vSyncNumerator,
            uint vSyncDenominator,
            out DISPLAYCONFIG_PATH_INFO[] paths,
            out DISPLAYCONFIG_MODE_INFO[] modes)
        {
            QueryActive(out paths, out modes);
            DISPLAYCONFIG_PATH_INFO path = RequireSingleMatchingTarget(
                paths,
                targetNeedle);
            uint targetModeIndex = GetTargetModeIndex(path, modes);
            DISPLAYCONFIG_VIDEO_SIGNAL_INFO current =
                modes[targetModeIndex].modeInfo.targetMode.targetVideoSignalInfo;
            ValidateRequestedTiming(
                current,
                pixelRate,
                hSyncNumerator,
                hSyncDenominator,
                vSyncNumerator,
                vSyncDenominator);

            DISPLAYCONFIG_MODE_INFO targetMode = modes[targetModeIndex];
            targetMode.modeInfo.targetMode.targetVideoSignalInfo.pixelRate = pixelRate;
            targetMode.modeInfo.targetMode.targetVideoSignalInfo.hSyncFreq.Numerator =
                hSyncNumerator;
            targetMode.modeInfo.targetMode.targetVideoSignalInfo.hSyncFreq.Denominator =
                hSyncDenominator;
            targetMode.modeInfo.targetMode.targetVideoSignalInfo.vSyncFreq.Numerator =
                vSyncNumerator;
            targetMode.modeInfo.targetMode.targetVideoSignalInfo.vSyncFreq.Denominator =
                vSyncDenominator;
            modes[targetModeIndex] = targetMode;

            DISPLAYCONFIG_PATH_INFO requestedPath = paths[0];
            requestedPath.targetInfo.refreshRate.Numerator = vSyncNumerator;
            requestedPath.targetInfo.refreshRate.Denominator = vSyncDenominator;
            paths[0] = requestedPath;
        }

        private static string Describe(
            DISPLAYCONFIG_PATH_INFO path,
            DISPLAYCONFIG_MODE_INFO[] modes)
        {
            DISPLAYCONFIG_TARGET_DEVICE_NAME targetName = GetTargetName(path);
            StringBuilder result = new StringBuilder();
            result.Append("active=")
                .Append((path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0)
                .Append(" srcAdapter=").Append(path.sourceInfo.adapterId)
                .Append(" srcId=").Append(path.sourceInfo.id)
                .Append(" targetAdapter=").Append(path.targetInfo.adapterId)
                .Append(" targetId=").Append(path.targetInfo.id)
                .Append(" outputTech=").Append(path.targetInfo.outputTechnology)
                .Append(" refresh=").Append(path.targetInfo.refreshRate)
                .Append(" friendly=").Append(targetName.monitorFriendlyDeviceName)
                .Append(" path=").Append(targetName.monitorDevicePath);

            if (path.sourceInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID &&
                path.sourceInfo.modeInfoIdx < modes.Length)
            {
                DISPLAYCONFIG_MODE_INFO sourceInfo = modes[path.sourceInfo.modeInfoIdx];
                if (sourceInfo.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE)
                {
                    DISPLAYCONFIG_SOURCE_MODE source = sourceInfo.modeInfo.sourceMode;
                    result.Append(" sourceMode=").Append(source.width).Append("x")
                        .Append(source.height).Append("@").Append(source.position.x)
                        .Append(",").Append(source.position.y);
                }
            }
            if (path.targetInfo.modeInfoIdx != DISPLAYCONFIG_PATH_MODE_IDX_INVALID &&
                path.targetInfo.modeInfoIdx < modes.Length)
            {
                DISPLAYCONFIG_MODE_INFO targetInfo = modes[path.targetInfo.modeInfoIdx];
                if (targetInfo.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_TARGET)
                {
                    DISPLAYCONFIG_VIDEO_SIGNAL_INFO signal =
                        targetInfo.modeInfo.targetMode.targetVideoSignalInfo;
                    result.Append(" targetMode=").Append(signal.activeSize.cx)
                        .Append("x").Append(signal.activeSize.cy)
                        .Append(" total=").Append(signal.totalSize.cx)
                        .Append("x").Append(signal.totalSize.cy)
                        .Append(" pixelRate=").Append(signal.pixelRate)
                        .Append(" h=").Append(signal.hSyncFreq)
                        .Append(" v=").Append(signal.vSyncFreq);
                }
            }
            return result.ToString();
        }

        private static void VerifyAppliedTiming(
            string targetNeedle,
            ulong pixelRate,
            uint hSyncNumerator,
            uint hSyncDenominator,
            uint vSyncNumerator,
            uint vSyncDenominator)
        {
            DISPLAYCONFIG_PATH_INFO[] paths;
            DISPLAYCONFIG_MODE_INFO[] modes;
            QueryActive(out paths, out modes);
            DISPLAYCONFIG_PATH_INFO path = RequireSingleMatchingTarget(
                paths,
                targetNeedle);
            uint targetModeIndex = GetTargetModeIndex(path, modes);
            DISPLAYCONFIG_VIDEO_SIGNAL_INFO signal =
                modes[targetModeIndex].modeInfo.targetMode.targetVideoSignalInfo;

            bool exact = signal.pixelRate == pixelRate &&
                signal.hSyncFreq.Numerator == hSyncNumerator &&
                signal.hSyncFreq.Denominator == hSyncDenominator &&
                signal.vSyncFreq.Numerator == vSyncNumerator &&
                signal.vSyncFreq.Denominator == vSyncDenominator &&
                path.targetInfo.refreshRate.Numerator == vSyncNumerator &&
                path.targetInfo.refreshRate.Denominator == vSyncDenominator;
            if (!exact)
            {
                throw new InvalidOperationException(
                    "The display driver did not retain the exact supplied timing. " +
                    Describe(path, modes));
            }
        }

        public static string DumpActive()
        {
            DISPLAYCONFIG_PATH_INFO[] paths;
            DISPLAYCONFIG_MODE_INFO[] modes;
            QueryActive(out paths, out modes);
            StringBuilder result = new StringBuilder();
            result.AppendLine("activePaths=" + paths.Length + " modes=" + modes.Length);
            for (int i = 0; i < paths.Length; i++)
            {
                result.AppendLine("PATH " + i + " " + Describe(paths[i], modes));
            }
            return result.ToString();
        }

        public static uint GetSingleTargetId(string targetNeedle)
        {
            DISPLAYCONFIG_PATH_INFO[] paths;
            DISPLAYCONFIG_MODE_INFO[] modes;
            QueryActive(out paths, out modes);
            return RequireSingleMatchingTarget(paths, targetNeedle).targetInfo.id;
        }

        public static string ValidateSupplied(
            string targetNeedle,
            ulong pixelRate,
            uint hSyncNumerator,
            uint hSyncDenominator,
            uint vSyncNumerator,
            uint vSyncDenominator,
            bool allowChanges)
        {
            DISPLAYCONFIG_PATH_INFO[] paths;
            DISPLAYCONFIG_MODE_INFO[] modes;
            BuildRequestedConfiguration(
                targetNeedle,
                pixelRate,
                hSyncNumerator,
                hSyncDenominator,
                vSyncNumerator,
                vSyncDenominator,
                out paths,
                out modes);

            uint flags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_VALIDATE;
            if (allowChanges)
            {
                flags |= SDC_ALLOW_CHANGES;
            }
            int error = SetDisplayConfig(
                (uint)paths.Length,
                paths,
                (uint)modes.Length,
                modes,
                flags);
            ThrowIfWin32Error(error, "SetDisplayConfig(validate supplied timing)");
            return "validationErr=" + error + " validationFlags=0x" +
                flags.ToString("X8");
        }

        public static string ApplySupplied(
            string targetNeedle,
            ulong pixelRate,
            uint hSyncNumerator,
            uint hSyncDenominator,
            uint vSyncNumerator,
            uint vSyncDenominator,
            bool allowChanges)
        {
            DISPLAYCONFIG_PATH_INFO[] capturedPaths;
            DISPLAYCONFIG_MODE_INFO[] capturedModes;
            QueryActive(out capturedPaths, out capturedModes);
            RequireSingleMatchingTarget(capturedPaths, targetNeedle);

            originalPaths = new DISPLAYCONFIG_PATH_INFO[capturedPaths.Length];
            originalModes = new DISPLAYCONFIG_MODE_INFO[capturedModes.Length];
            Array.Copy(capturedPaths, originalPaths, capturedPaths.Length);
            Array.Copy(capturedModes, originalModes, capturedModes.Length);

            DISPLAYCONFIG_PATH_INFO[] paths;
            DISPLAYCONFIG_MODE_INFO[] modes;
            BuildRequestedConfiguration(
                targetNeedle,
                pixelRate,
                hSyncNumerator,
                hSyncDenominator,
                vSyncNumerator,
                vSyncDenominator,
                out paths,
                out modes);

            uint validateFlags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_VALIDATE;
            if (allowChanges)
            {
                validateFlags |= SDC_ALLOW_CHANGES;
            }
            int validationError = SetDisplayConfig(
                (uint)paths.Length,
                paths,
                (uint)modes.Length,
                modes,
                validateFlags);
            ThrowIfWin32Error(
                validationError,
                "SetDisplayConfig(validate supplied timing)");

            uint applyFlags = SDC_USE_SUPPLIED_DISPLAY_CONFIG |
                SDC_APPLY |
                SDC_NO_OPTIMIZATION;
            if (allowChanges)
            {
                applyFlags |= SDC_ALLOW_CHANGES;
            }
            int applyError = SetDisplayConfig(
                (uint)paths.Length,
                paths,
                (uint)modes.Length,
                modes,
                applyFlags);
            ThrowIfWin32Error(applyError, "SetDisplayConfig(apply supplied timing)");

            VerifyAppliedTiming(
                targetNeedle,
                pixelRate,
                hSyncNumerator,
                hSyncDenominator,
                vSyncNumerator,
                vSyncDenominator);
            return "validationErr=" + validationError +
                " applyErr=" + applyError +
                " applyFlags=0x" + applyFlags.ToString("X8") +
                " exactReadback=true";
        }

        public static string RestoreOriginal()
        {
            if (originalPaths == null || originalModes == null)
            {
                return "No original DisplayConfig was captured in this process.";
            }

            uint flags = SDC_USE_SUPPLIED_DISPLAY_CONFIG |
                SDC_APPLY |
                SDC_NO_OPTIMIZATION;
            int error = SetDisplayConfig(
                (uint)originalPaths.Length,
                originalPaths,
                (uint)originalModes.Length,
                originalModes,
                flags);
            ThrowIfWin32Error(error, "SetDisplayConfig(restore original timing)");
            originalPaths = null;
            originalModes = null;
            return "Restored original DisplayConfig. applyErr=" + error +
                " applyFlags=0x" + flags.ToString("X8");
        }
    }
}
