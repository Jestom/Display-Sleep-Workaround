// Derived from NVIDIA NVAPI R610 public headers and DisplayConfiguration sample.
// SPDX-FileCopyrightText: Copyright (c) 2019-2026 NVIDIA CORPORATION & AFFILIATES.
// SPDX-License-Identifier: MIT

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace TopologyDdcci.NvApiDiagnosticV1
{
    public static class NvApiDisplayCommit
    {
        private const uint NvApiInitializeId = 0x0150E828;
        private const uint NvApiUnloadId = 0xD22BDD7E;
        private const uint NvApiGetErrorMessageId = 0x6C2D048C;
        private const uint NvApiGetDisplayConfigId = 0x11ABCCF8;
        private const uint NvApiSetDisplayConfigId = 0x5D8CF8DE;

        private const int NvApiOk = 0;
        private const int NvApiDeviceBusy = -108;
        private const int NvApiInsufficientBuffer = -174;
        private const uint NvDisplayConfigValidateOnly = 0x00000001;
        private const uint NvForceCommitVidPn = 0x00000010;

        // Sizes are from the R610 x64 ABI with #pragma pack(push, 8).
        private const int PathInfoV2Size = 48;
        private const int TargetInfoV2Size = 24;
        private const int SourceModeInfoV1Size = 32;
        private const int AdvancedTargetInfoV1Size = 128;
        private const uint AdvancedTargetInfoV1Version = 0x00010080;
        private const int QueryRetryCount = 5;
        private const int QueryRetryDelayMilliseconds = 200;

        private static InitializeDelegate initialize;
        private static UnloadDelegate unload;
        private static GetErrorMessageDelegate getErrorMessage;
        private static GetDisplayConfigDelegate getDisplayConfig;
        private static SetDisplayConfigDelegate setDisplayConfig;
        private static bool initialized;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int InitializeDelegate();

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int UnloadDelegate();

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int GetErrorMessageDelegate(int status, IntPtr description);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int GetDisplayConfigDelegate(ref uint pathInfoCount, IntPtr pathInfo);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int SetDisplayConfigDelegate(uint pathInfoCount, IntPtr pathInfo, uint flags);

        [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr QueryInterface(uint interfaceId);

        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        private struct PathInfoV2
        {
            public uint Version;
            public uint SourceId;
            public uint TargetInfoCount;
            public IntPtr TargetInfo;
            public IntPtr SourceModeInfo;
            public uint Flags;
            public IntPtr OsAdapterId;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        private struct TargetInfoV2
        {
            public uint DisplayId;
            public IntPtr Details;
            public uint TargetId;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        private struct Resolution
        {
            public uint Width;
            public uint Height;
            public uint ColorDepth;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        private struct Position
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 8)]
        private struct SourceModeInfoV1
        {
            public Resolution Resolution;
            public int ColorFormat;
            public Position Position;
            public int SpanningOrientation;
            public uint Flags;
        }

        private sealed class DisplayConfig : IDisposable
        {
            private readonly List<IntPtr> allocations = new List<IntPtr>();
            private bool disposed;

            public DisplayConfig(uint pathCapacity)
            {
                PathCapacity = pathCapacity;
                Paths = Allocate(checked((int)pathCapacity * PathInfoV2Size));
            }

            public uint PathCapacity { get; private set; }
            public uint PathCount { get; set; }
            public IntPtr Paths { get; private set; }

            public IntPtr Allocate(int size)
            {
                if (size <= 0)
                {
                    return IntPtr.Zero;
                }

                IntPtr pointer = Marshal.AllocHGlobal(size);
                Zero(pointer, size);
                allocations.Add(pointer);
                return pointer;
            }

            public PathInfoV2 GetPath(int index)
            {
                return Read<PathInfoV2>(Offset(Paths, index, PathInfoV2Size));
            }

            public void SetPath(int index, PathInfoV2 value)
            {
                Write(Offset(Paths, index, PathInfoV2Size), value);
            }

            public void Dispose()
            {
                if (disposed)
                {
                    return;
                }

                for (int index = allocations.Count - 1; index >= 0; index--)
                {
                    Marshal.FreeHGlobal(allocations[index]);
                }
                allocations.Clear();
                Paths = IntPtr.Zero;
                disposed = true;
            }
        }

        public static string Initialize()
        {
            if (initialized)
            {
                return "NVAPI is already initialized.";
            }
            if (IntPtr.Size != 8)
            {
                throw new PlatformNotSupportedException("This diagnostic requires a 64-bit PowerShell process.");
            }

            AssertStructureSize(typeof(PathInfoV2), PathInfoV2Size);
            AssertStructureSize(typeof(TargetInfoV2), TargetInfoV2Size);
            AssertStructureSize(typeof(SourceModeInfoV1), SourceModeInfoV1Size);

            initialize = GetFunction<InitializeDelegate>(NvApiInitializeId, "NvAPI_Initialize");
            unload = GetFunction<UnloadDelegate>(NvApiUnloadId, "NvAPI_Unload");
            getErrorMessage = GetFunction<GetErrorMessageDelegate>(NvApiGetErrorMessageId, "NvAPI_GetErrorMessage");
            getDisplayConfig = GetFunction<GetDisplayConfigDelegate>(NvApiGetDisplayConfigId, "NvAPI_DISP_GetDisplayConfig");
            setDisplayConfig = GetFunction<SetDisplayConfigDelegate>(NvApiSetDisplayConfigId, "NvAPI_DISP_SetDisplayConfig");

            int status = initialize();
            ThrowIfFailed(status, "NvAPI_Initialize");
            initialized = true;
            return "NVAPI initialized. ABI=R610-x64 ForceCommitVidPn=0x" + NvForceCommitVidPn.ToString("X8");
        }

        public static string DumpCurrent()
        {
            RequireInitialized();
            using (DisplayConfig config = QueryCurrentConfig())
            {
                return Describe(config);
            }
        }

        public static string ValidateAndForceCommitSingleDisplay()
        {
            RequireInitialized();
            using (DisplayConfig before = QueryCurrentConfig())
            {
                RequireSingleNvidiaDisplay(before);
                string beforeSignature = GetSignature(before);

                int validationStatus = setDisplayConfig(before.PathCount, before.Paths, NvDisplayConfigValidateOnly);
                ThrowIfFailed(validationStatus, "NvAPI_DISP_SetDisplayConfig(validate current config)");

                int applyStatus = setDisplayConfig(before.PathCount, before.Paths, NvForceCommitVidPn);
                ThrowIfFailed(applyStatus, "NvAPI_DISP_SetDisplayConfig(NV_FORCE_COMMIT_VIDPN)");

                using (DisplayConfig after = QueryCurrentConfig())
                {
                    string afterSignature = GetSignature(after);
                    if (!String.Equals(beforeSignature, afterSignature, StringComparison.Ordinal))
                    {
                        throw new InvalidOperationException(
                            "NVAPI returned success but changed the active display configuration. Before=" +
                            beforeSignature + " After=" + afterSignature);
                    }

                    return "validationStatus=0 applyStatus=0 applyFlags=0x" +
                        NvForceCommitVidPn.ToString("X8") + " configUnchanged=True signature=" + afterSignature;
                }
            }
        }

        public static string Shutdown()
        {
            if (!initialized)
            {
                return "NVAPI was not initialized.";
            }

            int status = unload();
            initialized = false;
            initialize = null;
            unload = null;
            getErrorMessage = null;
            getDisplayConfig = null;
            setDisplayConfig = null;
            if (status != NvApiOk)
            {
                return "NvAPI_Unload returned " + status + ".";
            }
            return "NVAPI unloaded.";
        }

        private static DisplayConfig QueryCurrentConfig()
        {
            for (int outerAttempt = 1; outerAttempt <= QueryRetryCount; outerAttempt++)
            {
                DisplayConfig config = null;
                try
                {
                    uint pathCount = 0;
                    int status = CallGetDisplayConfig(ref pathCount, IntPtr.Zero);
                    ThrowIfFailed(status, "NvAPI_DISP_GetDisplayConfig(count)");
                    if (pathCount == 0)
                    {
                        throw new InvalidOperationException("NVAPI returned zero active display paths.");
                    }

                    config = new DisplayConfig(pathCount);
                    for (int pathIndex = 0; pathIndex < pathCount; pathIndex++)
                    {
                        PathInfoV2 path = new PathInfoV2();
                        path.Version = MakeVersion(PathInfoV2Size, 2);
                        config.SetPath(pathIndex, path);
                    }

                    uint secondPassCount = pathCount;
                    status = CallGetDisplayConfig(ref secondPassCount, config.Paths);
                    if ((status == NvApiInsufficientBuffer || secondPassCount > pathCount) && outerAttempt < QueryRetryCount)
                    {
                        config.Dispose();
                        Thread.Sleep(QueryRetryDelayMilliseconds);
                        continue;
                    }
                    ThrowIfFailed(status, "NvAPI_DISP_GetDisplayConfig(path counts)");
                    config.PathCount = secondPassCount;

                    for (int pathIndex = 0; pathIndex < config.PathCount; pathIndex++)
                    {
                        PathInfoV2 path = config.GetPath(pathIndex);
                        path.SourceModeInfo = config.Allocate(SourceModeInfoV1Size);

                        if (path.TargetInfoCount > 0)
                        {
                            path.TargetInfo = config.Allocate(checked((int)path.TargetInfoCount * TargetInfoV2Size));
                            for (int targetIndex = 0; targetIndex < path.TargetInfoCount; targetIndex++)
                            {
                                IntPtr details = config.Allocate(AdvancedTargetInfoV1Size);
                                Marshal.WriteInt32(details, unchecked((int)AdvancedTargetInfoV1Version));
                                TargetInfoV2 target = new TargetInfoV2();
                                target.Details = details;
                                Write(Offset(path.TargetInfo, targetIndex, TargetInfoV2Size), target);
                            }
                        }
                        config.SetPath(pathIndex, path);
                    }

                    uint finalPassCount = config.PathCount;
                    status = CallGetDisplayConfig(ref finalPassCount, config.Paths);
                    if ((status == NvApiInsufficientBuffer || finalPassCount > config.PathCapacity) && outerAttempt < QueryRetryCount)
                    {
                        config.Dispose();
                        Thread.Sleep(QueryRetryDelayMilliseconds);
                        continue;
                    }
                    ThrowIfFailed(status, "NvAPI_DISP_GetDisplayConfig(full config)");
                    config.PathCount = finalPassCount;
                    return config;
                }
                catch
                {
                    if (config != null)
                    {
                        config.Dispose();
                    }
                    throw;
                }
            }

            throw new InvalidOperationException("NVAPI display-config query retry limit was reached.");
        }

        private static int CallGetDisplayConfig(ref uint pathCount, IntPtr paths)
        {
            int status = NvApiDeviceBusy;
            for (int attempt = 1; attempt <= QueryRetryCount; attempt++)
            {
                status = getDisplayConfig(ref pathCount, paths);
                if (status != NvApiDeviceBusy)
                {
                    return status;
                }
                Thread.Sleep(QueryRetryDelayMilliseconds);
            }
            return status;
        }

        private static void RequireSingleNvidiaDisplay(DisplayConfig config)
        {
            if (config.PathCount != 1)
            {
                throw new InvalidOperationException(
                    "This experiment requires exactly one NVAPI display path; found " + config.PathCount + ".");
            }

            PathInfoV2 path = config.GetPath(0);
            bool nonNvidiaAdapter = (path.Flags & 0x1) != 0;
            if (nonNvidiaAdapter)
            {
                throw new InvalidOperationException("The only active NVAPI path is marked as a non-NVIDIA adapter.");
            }
            if (path.TargetInfoCount != 1 || path.TargetInfo == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "This experiment requires exactly one NVIDIA target; found " + path.TargetInfoCount + ".");
            }

            TargetInfoV2 target = Read<TargetInfoV2>(path.TargetInfo);
            if (target.DisplayId == 0)
            {
                throw new InvalidOperationException("NVAPI returned displayId=0 for the active target.");
            }
            if (path.SourceModeInfo == IntPtr.Zero)
            {
                throw new InvalidOperationException("NVAPI did not return source-mode information for the active path.");
            }
        }

        private static string Describe(DisplayConfig config)
        {
            StringBuilder result = new StringBuilder();
            result.AppendLine("nvapiPaths=" + config.PathCount + " pathStructVersion=2 pathStructSize=" + PathInfoV2Size);
            for (int pathIndex = 0; pathIndex < config.PathCount; pathIndex++)
            {
                PathInfoV2 path = config.GetPath(pathIndex);
                result.Append("PATH ").Append(pathIndex)
                    .Append(" sourceId=").Append(path.SourceId)
                    .Append(" nonNvidiaAdapter=").Append((path.Flags & 0x1) != 0)
                    .Append(" targetCount=").Append(path.TargetInfoCount);

                if (path.SourceModeInfo != IntPtr.Zero)
                {
                    SourceModeInfoV1 source = Read<SourceModeInfoV1>(path.SourceModeInfo);
                    result.Append(" sourceMode=").Append(source.Resolution.Width).Append("x").Append(source.Resolution.Height)
                        .Append(" depth=").Append(source.Resolution.ColorDepth)
                        .Append(" position=").Append(source.Position.X).Append(",").Append(source.Position.Y)
                        .Append(" gdiPrimary=").Append((source.Flags & 0x1) != 0);
                }
                result.AppendLine();

                for (int targetIndex = 0; targetIndex < path.TargetInfoCount; targetIndex++)
                {
                    TargetInfoV2 target = Read<TargetInfoV2>(Offset(path.TargetInfo, targetIndex, TargetInfoV2Size));
                    result.Append("  TARGET ").Append(targetIndex)
                        .Append(" displayId=0x").Append(target.DisplayId.ToString("X8"))
                        .Append(" ccdTargetId=").Append(target.TargetId);
                    if (target.Details != IntPtr.Zero)
                    {
                        result.Append(" detailVersion=0x").Append(unchecked((uint)Marshal.ReadInt32(target.Details, 0)).ToString("X8"))
                            .Append(" rotation=").Append(Marshal.ReadInt32(target.Details, 4))
                            .Append(" scaling=").Append(Marshal.ReadInt32(target.Details, 8))
                            .Append(" refreshRate1K=").Append(unchecked((uint)Marshal.ReadInt32(target.Details, 12)));
                    }
                    result.AppendLine();
                }
            }
            result.Append("signature=").Append(GetSignature(config));
            return result.ToString();
        }

        private static string GetSignature(DisplayConfig config)
        {
            StringBuilder signature = new StringBuilder();
            signature.Append("paths=").Append(config.PathCount);
            for (int pathIndex = 0; pathIndex < config.PathCount; pathIndex++)
            {
                PathInfoV2 path = config.GetPath(pathIndex);
                signature.Append("|p").Append(pathIndex)
                    .Append(":src=").Append(path.SourceId)
                    .Append(",flags=").Append(path.Flags)
                    .Append(",targets=").Append(path.TargetInfoCount);
                if (path.SourceModeInfo != IntPtr.Zero)
                {
                    SourceModeInfoV1 source = Read<SourceModeInfoV1>(path.SourceModeInfo);
                    signature.Append(",mode=").Append(source.Resolution.Width).Append("x").Append(source.Resolution.Height)
                        .Append("x").Append(source.Resolution.ColorDepth)
                        .Append("@").Append(source.Position.X).Append(",").Append(source.Position.Y)
                        .Append(",sourceFlags=").Append(source.Flags);
                }
                for (int targetIndex = 0; targetIndex < path.TargetInfoCount; targetIndex++)
                {
                    TargetInfoV2 target = Read<TargetInfoV2>(Offset(path.TargetInfo, targetIndex, TargetInfoV2Size));
                    signature.Append(",t").Append(targetIndex).Append("=").Append(target.DisplayId.ToString("X8"))
                        .Append("/").Append(target.TargetId);
                    if (target.Details != IntPtr.Zero)
                    {
                        signature.Append("/r").Append(unchecked((uint)Marshal.ReadInt32(target.Details, 12)));
                    }
                }
            }
            return signature.ToString();
        }

        private static T GetFunction<T>(uint id, string name) where T : class
        {
            IntPtr pointer;
            try
            {
                pointer = QueryInterface(id);
            }
            catch (DllNotFoundException exception)
            {
                throw new InvalidOperationException(
                    "nvapi64.dll was not found. Run this diagnostic on a 64-bit Windows process with an NVIDIA display driver installed.",
                    exception);
            }
            if (pointer == IntPtr.Zero)
            {
                throw new MissingMethodException("NVAPI interface is unavailable: " + name + " (0x" + id.ToString("X8") + ").");
            }
            return Marshal.GetDelegateForFunctionPointer(pointer, typeof(T)) as T;
        }

        private static void RequireInitialized()
        {
            if (!initialized)
            {
                throw new InvalidOperationException("Call NvApiDisplayCommit.Initialize() first.");
            }
        }

        private static void ThrowIfFailed(int status, string operation)
        {
            if (status == NvApiOk)
            {
                return;
            }
            throw new InvalidOperationException(operation + " failed: " + FormatStatus(status));
        }

        private static string FormatStatus(int status)
        {
            if (getErrorMessage == null)
            {
                return "status=" + status;
            }

            IntPtr buffer = Marshal.AllocHGlobal(64);
            try
            {
                Zero(buffer, 64);
                int messageStatus = getErrorMessage(status, buffer);
                string message = messageStatus == NvApiOk ? Marshal.PtrToStringAnsi(buffer) : null;
                return String.IsNullOrWhiteSpace(message)
                    ? "status=" + status
                    : "status=" + status + " message=" + message;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static uint MakeVersion(int size, int version)
        {
            return unchecked((uint)(size | (version << 16)));
        }

        private static void AssertStructureSize(Type type, int expectedSize)
        {
            int actualSize = Marshal.SizeOf(type);
            if (actualSize != expectedSize)
            {
                throw new InvalidOperationException(
                    type.Name + " ABI size mismatch. Expected=" + expectedSize + " Actual=" + actualSize);
            }
        }

        private static IntPtr Offset(IntPtr pointer, int index, int elementSize)
        {
            return IntPtr.Add(pointer, checked(index * elementSize));
        }

        private static T Read<T>(IntPtr pointer) where T : struct
        {
            return (T)Marshal.PtrToStructure(pointer, typeof(T));
        }

        private static void Write<T>(IntPtr pointer, T value) where T : struct
        {
            Marshal.StructureToPtr(value, pointer, false);
        }

        private static void Zero(IntPtr pointer, int size)
        {
            for (int index = 0; index < size; index++)
            {
                Marshal.WriteByte(pointer, index, 0);
            }
        }
    }
}
