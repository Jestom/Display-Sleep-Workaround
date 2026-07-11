using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace TopologyDdcci.ActivePathExperimentV1
{
    internal static class NativeDisplay
    {
        private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
        private const int ERROR_SUCCESS = 0;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;
        private const uint DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME = 1;
        private const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;

        [StructLayout(LayoutKind.Sequential)]
        internal struct Luid
        {
            internal uint LowPart;
            internal int HighPart;

            internal long ToInt64()
            {
                return ((long)HighPart << 32) | LowPart;
            }

            public override string ToString()
            {
                return HighPart.ToString("X8") + ":" + LowPart.ToString("X8");
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Rational
        {
            internal uint Numerator;
            internal uint Denominator;

            public override string ToString()
            {
                double value = Denominator == 0 ? 0 : (double)Numerator / Denominator;
                return Numerator + "/" + Denominator + "=" + value.ToString("F6");
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PathSourceInfo
        {
            internal Luid AdapterId;
            internal uint Id;
            internal uint ModeInfoIdx;
            internal uint StatusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PathTargetInfo
        {
            internal Luid AdapterId;
            internal uint Id;
            internal uint ModeInfoIdx;
            internal uint OutputTechnology;
            internal uint Rotation;
            internal uint Scaling;
            internal Rational RefreshRate;
            internal uint ScanLineOrdering;
            [MarshalAs(UnmanagedType.Bool)]
            internal bool TargetAvailable;
            internal uint StatusFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PathInfo
        {
            internal PathSourceInfo SourceInfo;
            internal PathTargetInfo TargetInfo;
            internal uint Flags;
        }

        [StructLayout(LayoutKind.Explicit, Size = 48)]
        private struct ModeData
        {
            [FieldOffset(0)]
            internal ulong Alignment;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ModeInfo
        {
            internal uint InfoType;
            internal uint Id;
            internal Luid AdapterId;
            internal ModeData Data;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DeviceInfoHeader
        {
            internal uint Type;
            internal uint Size;
            internal Luid AdapterId;
            internal uint Id;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SourceDeviceName
        {
            internal DeviceInfoHeader Header;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            internal string ViewGdiDeviceName;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct TargetDeviceName
        {
            internal DeviceInfoHeader Header;
            internal uint Flags;
            internal uint OutputTechnology;
            internal ushort EdidManufactureId;
            internal ushort EdidProductCodeId;
            internal uint ConnectorInstance;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
            internal string MonitorFriendlyDeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            internal string MonitorDevicePath;
        }

        internal sealed class ActiveTarget
        {
            internal Luid AdapterId;
            internal uint SourceId;
            internal uint TargetId;
            internal uint OutputTechnology;
            internal string GdiDeviceName;
            internal string FriendlyName;
            internal string MonitorDevicePath;
            internal string RefreshRate;

            internal string Describe()
            {
                return "adapter=" + AdapterId +
                    " sourceId=" + SourceId +
                    " targetId=" + TargetId +
                    " outputTech=" + OutputTechnology +
                    " refresh=" + RefreshRate +
                    " gdi=" + GdiDeviceName +
                    " friendly=" + FriendlyName +
                    " path=" + MonitorDevicePath;
            }
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
            [Out] PathInfo[] pathArray,
            ref uint numModeInfoArrayElements,
            [Out] ModeInfo[] modeInfoArray,
            IntPtr currentTopologyId);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref SourceDeviceName requestPacket);

        [DllImport("user32.dll")]
        private static extern int DisplayConfigGetDeviceInfo(ref TargetDeviceName requestPacket);

        private static void ThrowIfError(int error, string operation)
        {
            if (error != ERROR_SUCCESS)
            {
                throw new Win32Exception(error, operation + " failed with Win32 error " + error + ".");
            }
        }

        private static void QueryActive(out PathInfo[] paths, out ModeInfo[] modes)
        {
            for (int attempt = 1; attempt <= 5; attempt++)
            {
                uint pathCount;
                uint modeCount;
                ThrowIfError(
                    GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount),
                    "GetDisplayConfigBufferSizes");

                PathInfo[] pathBuffer = new PathInfo[pathCount];
                ModeInfo[] modeBuffer = new ModeInfo[modeCount];
                int error = QueryDisplayConfig(
                    QDC_ONLY_ACTIVE_PATHS,
                    ref pathCount,
                    pathBuffer,
                    ref modeCount,
                    modeBuffer,
                    IntPtr.Zero);
                if (error == ERROR_INSUFFICIENT_BUFFER && attempt < 5)
                {
                    continue;
                }
                ThrowIfError(error, "QueryDisplayConfig");

                paths = new PathInfo[pathCount];
                modes = new ModeInfo[modeCount];
                Array.Copy(pathBuffer, paths, pathCount);
                Array.Copy(modeBuffer, modes, modeCount);
                return;
            }
            throw new InvalidOperationException("QueryDisplayConfig retry limit was reached.");
        }

        private static SourceDeviceName GetSourceName(PathInfo path)
        {
            SourceDeviceName packet = new SourceDeviceName();
            packet.Header.Type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            packet.Header.Size = (uint)Marshal.SizeOf(typeof(SourceDeviceName));
            packet.Header.AdapterId = path.SourceInfo.AdapterId;
            packet.Header.Id = path.SourceInfo.Id;
            ThrowIfError(DisplayConfigGetDeviceInfo(ref packet), "DisplayConfigGetDeviceInfo(source name)");
            return packet;
        }

        private static TargetDeviceName GetTargetName(PathInfo path)
        {
            TargetDeviceName packet = new TargetDeviceName();
            packet.Header.Type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            packet.Header.Size = (uint)Marshal.SizeOf(typeof(TargetDeviceName));
            packet.Header.AdapterId = path.TargetInfo.AdapterId;
            packet.Header.Id = path.TargetInfo.Id;
            ThrowIfError(DisplayConfigGetDeviceInfo(ref packet), "DisplayConfigGetDeviceInfo(target name)");
            return packet;
        }

        internal static ActiveTarget RequireSingleTarget(string targetNeedle)
        {
            PathInfo[] paths;
            ModeInfo[] modes;
            QueryActive(out paths, out modes);
            if (paths.Length != 1)
            {
                throw new InvalidOperationException(
                    "This experiment requires exactly one active display path; found " + paths.Length + ".");
            }

            SourceDeviceName source = GetSourceName(paths[0]);
            TargetDeviceName target = GetTargetName(paths[0]);
            string friendly = target.MonitorFriendlyDeviceName ?? String.Empty;
            string devicePath = target.MonitorDevicePath ?? String.Empty;
            if (String.IsNullOrWhiteSpace(targetNeedle) ||
                (friendly.IndexOf(targetNeedle, StringComparison.OrdinalIgnoreCase) < 0 &&
                 devicePath.IndexOf(targetNeedle, StringComparison.OrdinalIgnoreCase) < 0))
            {
                throw new InvalidOperationException(
                    "The active target does not match TargetNeedle='" + targetNeedle +
                    "'. Actual friendly='" + friendly + "' path='" + devicePath + "'.");
            }

            ActiveTarget result = new ActiveTarget();
            result.AdapterId = paths[0].TargetInfo.AdapterId;
            result.SourceId = paths[0].SourceInfo.Id;
            result.TargetId = paths[0].TargetInfo.Id;
            result.OutputTechnology = paths[0].TargetInfo.OutputTechnology;
            result.GdiDeviceName = source.ViewGdiDeviceName;
            result.FriendlyName = friendly;
            result.MonitorDevicePath = devicePath;
            result.RefreshRate = paths[0].TargetInfo.RefreshRate.ToString();
            return result;
        }

        internal static string GetAbiSummary()
        {
            return "pathInfo=" + Marshal.SizeOf(typeof(PathInfo)) +
                " modeInfo=" + Marshal.SizeOf(typeof(ModeInfo)) +
                " sourceName=" + Marshal.SizeOf(typeof(SourceDeviceName)) +
                " targetName=" + Marshal.SizeOf(typeof(TargetDeviceName));
        }
    }

    public static class ActivePathInspector
    {
        public static string DescribeSingleTarget(string targetNeedle)
        {
            return NativeDisplay.RequireSingleTarget(targetNeedle).Describe();
        }

        public static string ListModes(string targetNeedle)
        {
            NativeDisplay.ActiveTarget target = NativeDisplay.RequireSingleTarget(targetNeedle);
            return TemporaryDisplayMode.ListModes(target.GdiDeviceName, target.Describe());
        }

        public static string GetAbiSummary()
        {
            return NativeDisplay.GetAbiSummary() +
                " devMode=" + TemporaryDisplayMode.GetDevModeSize();
        }
    }

    public sealed class TemporaryDisplayMode : IDisposable
    {
        private const int ENUM_CURRENT_SETTINGS = -1;
        private const uint CDS_TEST = 0x00000002;
        private const int DISP_CHANGE_SUCCESSFUL = 0;
        private const uint DM_BITSPERPEL = 0x00040000;
        private const uint DM_PELSWIDTH = 0x00080000;
        private const uint DM_PELSHEIGHT = 0x00100000;
        private const uint DM_DISPLAYFREQUENCY = 0x00400000;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DevMode
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            internal string DeviceName;
            internal ushort SpecVersion;
            internal ushort DriverVersion;
            internal ushort Size;
            internal ushort DriverExtra;
            internal uint Fields;
            internal int PositionX;
            internal int PositionY;
            internal uint DisplayOrientation;
            internal uint DisplayFixedOutput;
            internal short Color;
            internal short Duplex;
            internal short YResolution;
            internal short TTOption;
            internal short Collate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            internal string FormName;
            internal ushort LogPixels;
            internal uint BitsPerPel;
            internal uint PelsWidth;
            internal uint PelsHeight;
            internal uint DisplayFlags;
            internal uint DisplayFrequency;
            internal uint ICMMethod;
            internal uint ICMIntent;
            internal uint MediaType;
            internal uint DitherType;
            internal uint Reserved1;
            internal uint Reserved2;
            internal uint PanningWidth;
            internal uint PanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumDisplaySettingsEx(
            string deviceName,
            int modeNum,
            ref DevMode devMode,
            uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int ChangeDisplaySettingsEx(
            string deviceName,
            ref DevMode devMode,
            IntPtr hwnd,
            uint flags,
            IntPtr lParam);

        private readonly string deviceName;
        private DevMode originalMode;
        private uint requestedWidth;
        private uint requestedHeight;
        private uint requestedRefreshRate;
        private bool applied;
        private bool disposed;

        private TemporaryDisplayMode(string deviceName)
        {
            this.deviceName = deviceName;
        }

        private static DevMode NewDevMode()
        {
            DevMode mode = new DevMode();
            mode.Size = (ushort)Marshal.SizeOf(typeof(DevMode));
            return mode;
        }

        internal static int GetDevModeSize()
        {
            return Marshal.SizeOf(typeof(DevMode));
        }

        private static DevMode GetCurrent(string deviceName)
        {
            DevMode mode = NewDevMode();
            if (!EnumDisplaySettingsEx(deviceName, ENUM_CURRENT_SETTINGS, ref mode, 0))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "EnumDisplaySettingsEx(current) failed.");
            }
            return mode;
        }

        private static string DescribeMode(DevMode mode)
        {
            return mode.PelsWidth + "x" + mode.PelsHeight +
                " @ " + mode.DisplayFrequency + "Hz" +
                " " + mode.BitsPerPel + "bpp" +
                " flags=0x" + mode.DisplayFlags.ToString("X8") +
                " orientation=" + mode.DisplayOrientation +
                " fixedOutput=" + mode.DisplayFixedOutput;
        }

        internal static string ListModes(string deviceName, string targetDescription)
        {
            DevMode current = GetCurrent(deviceName);
            SortedDictionary<string, string> unique = new SortedDictionary<string, string>(StringComparer.Ordinal);
            for (int index = 0; ; index++)
            {
                DevMode mode = NewDevMode();
                if (!EnumDisplaySettingsEx(deviceName, index, ref mode, 0))
                {
                    break;
                }
                string key = mode.PelsWidth.ToString("D5") + "x" + mode.PelsHeight.ToString("D5") +
                    "-" + mode.DisplayFrequency.ToString("D4") + "-" + mode.BitsPerPel.ToString("D3") +
                    "-" + mode.DisplayFlags.ToString("X8") +
                    "-" + mode.DisplayOrientation.ToString("D2") + "-" + mode.DisplayFixedOutput.ToString("D2");
                unique[key] = DescribeMode(mode);
            }

            StringBuilder result = new StringBuilder();
            result.AppendLine("TARGET " + targetDescription);
            result.AppendLine("CURRENT " + DescribeMode(current));
            foreach (KeyValuePair<string, string> pair in unique)
            {
                result.AppendLine("MODE " + pair.Value);
            }
            return result.ToString();
        }

        public static TemporaryDisplayMode Apply(
            string targetNeedle,
            uint width,
            uint height,
            uint refreshRate)
        {
            NativeDisplay.ActiveTarget target = NativeDisplay.RequireSingleTarget(targetNeedle);
            TemporaryDisplayMode transition = new TemporaryDisplayMode(target.GdiDeviceName);
            transition.originalMode = GetCurrent(target.GdiDeviceName);
            transition.requestedWidth = width;
            transition.requestedHeight = height;
            transition.requestedRefreshRate = refreshRate;

            if (transition.originalMode.PelsWidth == width &&
                transition.originalMode.PelsHeight == height &&
                transition.originalMode.DisplayFrequency == refreshRate)
            {
                throw new InvalidOperationException(
                    "The requested temporary mode equals the current mode. A real mode transition is required.");
            }

            DevMode selected = NewDevMode();
            bool found = false;
            for (int index = 0; ; index++)
            {
                DevMode candidate = NewDevMode();
                if (!EnumDisplaySettingsEx(target.GdiDeviceName, index, ref candidate, 0))
                {
                    break;
                }
                if (candidate.PelsWidth == width &&
                    candidate.PelsHeight == height &&
                    candidate.DisplayFrequency == refreshRate &&
                    candidate.BitsPerPel == transition.originalMode.BitsPerPel)
                {
                    if (!found || candidate.DisplayFlags == 0)
                    {
                        selected = candidate;
                        found = true;
                    }
                    if (candidate.DisplayFlags == 0)
                    {
                        break;
                    }
                }
            }
            if (!found)
            {
                throw new InvalidOperationException(
                    "The requested temporary mode is not enumerated on " + target.GdiDeviceName +
                    ": " + width + "x" + height + " @ " + refreshRate + "Hz.");
            }

            selected.Fields |= DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
            int testResult = ChangeDisplaySettingsEx(
                target.GdiDeviceName,
                ref selected,
                IntPtr.Zero,
                CDS_TEST,
                IntPtr.Zero);
            if (testResult != DISP_CHANGE_SUCCESSFUL)
            {
                throw new InvalidOperationException("ChangeDisplaySettingsEx(test) failed. Result=" + testResult + ".");
            }

            int result = ChangeDisplaySettingsEx(
                target.GdiDeviceName,
                ref selected,
                IntPtr.Zero,
                0,
                IntPtr.Zero);
            if (result != DISP_CHANGE_SUCCESSFUL)
            {
                throw new InvalidOperationException("ChangeDisplaySettingsEx(apply) failed. Result=" + result + ".");
            }

            transition.applied = true;
            try
            {
                DevMode actual = new DevMode();
                for (int sample = 1; sample <= 10; sample++)
                {
                    Thread.Sleep(500);
                    actual = GetCurrent(target.GdiDeviceName);
                    if (actual.PelsWidth != width ||
                        actual.PelsHeight != height ||
                        actual.DisplayFrequency != refreshRate)
                    {
                        throw new InvalidOperationException(
                            "The dynamic mode did not remain stable for 5 seconds. Sample=" + sample +
                            "/10 Actual=" + DescribeMode(actual) + ".");
                    }
                }
                return transition;
            }
            catch
            {
                try
                {
                    transition.Restore();
                }
                catch
                {
                }
                throw;
            }
        }

        public string GetStatus()
        {
            DevMode current = GetCurrent(deviceName);
            if (applied &&
                (current.PelsWidth != requestedWidth ||
                 current.PelsHeight != requestedHeight ||
                 current.DisplayFrequency != requestedRefreshRate))
            {
                throw new InvalidOperationException(
                    "The temporary mode reverted before capture. Actual=" + DescribeMode(current) + ".");
            }
            return "device=" + deviceName +
                " original=" + DescribeMode(originalMode) +
                " current=" + DescribeMode(current) +
                " applied=" + applied;
        }

        public string Restore()
        {
            if (!applied)
            {
                return "Temporary display mode was not active.";
            }
            int result = ChangeDisplaySettingsEx(
                deviceName,
                ref originalMode,
                IntPtr.Zero,
                0,
                IntPtr.Zero);
            if (result != DISP_CHANGE_SUCCESSFUL)
            {
                throw new InvalidOperationException("ChangeDisplaySettingsEx(restore) failed. Result=" + result + ".");
            }
            applied = false;
            return "Restored " + deviceName + " to " + DescribeMode(GetCurrent(deviceName)) + ".";
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            Restore();
        }
    }

    public sealed class D3dKeepAlive : IDisposable
    {
        private const int DXGI_ERROR_NOT_FOUND = unchecked((int)0x887A0002);
        private const int D3D_DRIVER_TYPE_UNKNOWN = 0;
        private const uint D3D11_SDK_VERSION = 7;
        private const uint D3D11_BIND_CONSTANT_BUFFER = 0x00000004;

        // Vtable slots are fixed by the Windows SDK COM interface definitions.
        private const int IDXGIFactory1_EnumAdapters1 = 12;
        private const int IDXGIAdapter1_GetDesc1 = 10;
        private const int ID3D11Device_CreateBuffer = 3;
        private const int ID3D11Device_GetDeviceRemovedReason = 39;
        private const int ID3D11DeviceContext_UpdateSubresource = 48;
        private const int ID3D11DeviceContext_Flush = 111;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct AdapterDesc1
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            internal string Description;
            internal uint VendorId;
            internal uint DeviceId;
            internal uint SubSysId;
            internal uint Revision;
            internal UIntPtr DedicatedVideoMemory;
            internal UIntPtr DedicatedSystemMemory;
            internal UIntPtr SharedSystemMemory;
            internal NativeDisplay.Luid AdapterLuid;
            internal uint Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BufferDesc
        {
            internal uint ByteWidth;
            internal uint Usage;
            internal uint BindFlags;
            internal uint CpuAccessFlags;
            internal uint MiscFlags;
            internal uint StructureByteStride;
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int EnumAdapters1Delegate(IntPtr self, uint adapterIndex, out IntPtr adapter);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetDesc1Delegate(IntPtr self, out AdapterDesc1 description);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int CreateBufferDelegate(
            IntPtr self,
            ref BufferDesc description,
            IntPtr initialData,
            out IntPtr buffer);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate void UpdateSubresourceDelegate(
            IntPtr self,
            IntPtr destinationResource,
            uint destinationSubresource,
            IntPtr destinationBox,
            IntPtr sourceData,
            uint sourceRowPitch,
            uint sourceDepthPitch);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate void FlushDelegate(IntPtr self);

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        private delegate int GetDeviceRemovedReasonDelegate(IntPtr self);

        [DllImport("dxgi.dll")]
        private static extern int CreateDXGIFactory1(ref Guid interfaceId, out IntPtr factory);

        [DllImport("d3d11.dll")]
        private static extern int D3D11CreateDevice(
            IntPtr adapter,
            int driverType,
            IntPtr software,
            uint flags,
            IntPtr featureLevels,
            uint featureLevelCount,
            uint sdkVersion,
            out IntPtr device,
            out uint featureLevel,
            out IntPtr immediateContext);

        private readonly object gate = new object();
        private IntPtr device;
        private IntPtr context;
        private IntPtr buffer;
        private readonly byte[] pulseData = new byte[256];
        private Timer timer;
        private bool disposed;
        private long pulseCount;
        private string failure;
        private string adapterDescription;
        private uint featureLevel;
        private UpdateSubresourceDelegate updateSubresource;
        private FlushDelegate flush;
        private GetDeviceRemovedReasonDelegate getDeviceRemovedReason;

        private D3dKeepAlive()
        {
        }

        private static T GetVtableDelegate<T>(IntPtr instance, int index) where T : class
        {
            IntPtr vtable = Marshal.ReadIntPtr(instance);
            IntPtr method = Marshal.ReadIntPtr(vtable, index * IntPtr.Size);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(method, typeof(T));
        }

        private static IntPtr FindAdapter(long requestedLuid, out string description)
        {
            Guid factoryId = new Guid("770AAE78-F26F-4DBA-A829-253C83D1B387");
            IntPtr factory;
            int createResult = CreateDXGIFactory1(ref factoryId, out factory);
            if (createResult < 0)
            {
                Marshal.ThrowExceptionForHR(createResult);
            }

            try
            {
                EnumAdapters1Delegate enumerate = GetVtableDelegate<EnumAdapters1Delegate>(factory, IDXGIFactory1_EnumAdapters1);
                for (uint index = 0; ; index++)
                {
                    IntPtr adapter;
                    int result = enumerate(factory, index, out adapter);
                    if (result == DXGI_ERROR_NOT_FOUND)
                    {
                        break;
                    }
                    if (result < 0)
                    {
                        Marshal.ThrowExceptionForHR(result);
                    }

                    bool keep = false;
                    try
                    {
                        GetDesc1Delegate getDescription = GetVtableDelegate<GetDesc1Delegate>(adapter, IDXGIAdapter1_GetDesc1);
                        AdapterDesc1 value;
                        int descResult = getDescription(adapter, out value);
                        if (descResult < 0)
                        {
                            Marshal.ThrowExceptionForHR(descResult);
                        }
                        if (value.AdapterLuid.ToInt64() == requestedLuid)
                        {
                            description = value.Description +
                                " vendor=0x" + value.VendorId.ToString("X4") +
                                " device=0x" + value.DeviceId.ToString("X4") +
                                " luid=" + value.AdapterLuid;
                            keep = true;
                            return adapter;
                        }
                    }
                    finally
                    {
                        if (!keep && adapter != IntPtr.Zero)
                        {
                            Marshal.Release(adapter);
                        }
                    }
                }
            }
            finally
            {
                Marshal.Release(factory);
            }

            throw new InvalidOperationException(
                "No DXGI adapter matched target LUID 0x" + requestedLuid.ToString("X16") + ".");
        }

        public static D3dKeepAlive Create(string targetNeedle)
        {
            NativeDisplay.ActiveTarget target = NativeDisplay.RequireSingleTarget(targetNeedle);
            string description;
            IntPtr adapter = FindAdapter(target.AdapterId.ToInt64(), out description);
            D3dKeepAlive result = new D3dKeepAlive();
            try
            {
                int createResult = D3D11CreateDevice(
                    adapter,
                    D3D_DRIVER_TYPE_UNKNOWN,
                    IntPtr.Zero,
                    0,
                    IntPtr.Zero,
                    0,
                    D3D11_SDK_VERSION,
                    out result.device,
                    out result.featureLevel,
                    out result.context);
                if (createResult < 0)
                {
                    Marshal.ThrowExceptionForHR(createResult);
                }

                BufferDesc bufferDescription = new BufferDesc();
                bufferDescription.ByteWidth = (uint)result.pulseData.Length;
                bufferDescription.Usage = 0;
                bufferDescription.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
                CreateBufferDelegate createBuffer = GetVtableDelegate<CreateBufferDelegate>(result.device, ID3D11Device_CreateBuffer);
                int bufferResult = createBuffer(
                    result.device,
                    ref bufferDescription,
                    IntPtr.Zero,
                    out result.buffer);
                if (bufferResult < 0)
                {
                    Marshal.ThrowExceptionForHR(bufferResult);
                }

                result.updateSubresource = GetVtableDelegate<UpdateSubresourceDelegate>(result.context, ID3D11DeviceContext_UpdateSubresource);
                result.flush = GetVtableDelegate<FlushDelegate>(result.context, ID3D11DeviceContext_Flush);
                result.getDeviceRemovedReason = GetVtableDelegate<GetDeviceRemovedReasonDelegate>(result.device, ID3D11Device_GetDeviceRemovedReason);
                result.adapterDescription = description;
                return result;
            }
            catch
            {
                result.Dispose();
                throw;
            }
            finally
            {
                Marshal.Release(adapter);
            }
        }

        public void Start(int intervalMilliseconds)
        {
            if (intervalMilliseconds < 100 || intervalMilliseconds > 10000)
            {
                throw new ArgumentOutOfRangeException("intervalMilliseconds");
            }
            lock (gate)
            {
                if (disposed)
                {
                    throw new ObjectDisposedException("D3dKeepAlive");
                }
                if (timer != null)
                {
                    throw new InvalidOperationException("D3D keep-alive is already running.");
                }
                timer = new Timer(Pulse, null, 0, intervalMilliseconds);
            }
        }

        private void Pulse(object state)
        {
            lock (gate)
            {
                if (disposed || failure != null)
                {
                    return;
                }
                try
                {
                    long sequence = pulseCount + 1;
                    byte[] sequenceBytes = BitConverter.GetBytes(sequence);
                    Array.Copy(sequenceBytes, pulseData, sequenceBytes.Length);
                    GCHandle pin = GCHandle.Alloc(pulseData, GCHandleType.Pinned);
                    try
                    {
                        updateSubresource(
                            context,
                            buffer,
                            0,
                            IntPtr.Zero,
                            pin.AddrOfPinnedObject(),
                            0,
                            0);
                        flush(context);
                    }
                    finally
                    {
                        pin.Free();
                    }

                    int removedReason = getDeviceRemovedReason(device);
                    if (removedReason < 0)
                    {
                        failure = "D3D device was removed. HRESULT=0x" + removedReason.ToString("X8");
                        return;
                    }
                    pulseCount = sequence;
                }
                catch (Exception exception)
                {
                    failure = exception.GetType().Name + ": " + exception.Message;
                }
            }
        }

        public string GetStatus()
        {
            lock (gate)
            {
                return "adapter=" + adapterDescription +
                    " featureLevel=0x" + featureLevel.ToString("X4") +
                    " pulses=" + pulseCount +
                    " failure=" + (failure ?? "none") +
                    " running=" + (timer != null && !disposed);
            }
        }

        public void ThrowIfFailed()
        {
            lock (gate)
            {
                if (failure != null)
                {
                    throw new InvalidOperationException(failure);
                }
                if (pulseCount == 0)
                {
                    throw new InvalidOperationException("No D3D keep-alive pulse has completed.");
                }
            }
        }

        public void Dispose()
        {
            Timer timerToDispose;
            lock (gate)
            {
                if (disposed)
                {
                    return;
                }
                timerToDispose = timer;
                timer = null;
            }

            if (timerToDispose != null)
            {
                using (ManualResetEvent completed = new ManualResetEvent(false))
                {
                    timerToDispose.Dispose(completed);
                    completed.WaitOne(5000);
                }
            }

            lock (gate)
            {
                disposed = true;
                if (buffer != IntPtr.Zero)
                {
                    Marshal.Release(buffer);
                    buffer = IntPtr.Zero;
                }
                if (context != IntPtr.Zero)
                {
                    Marshal.Release(context);
                    context = IntPtr.Zero;
                }
                if (device != IntPtr.Zero)
                {
                    Marshal.Release(device);
                    device = IntPtr.Zero;
                }
            }
        }
    }
}
