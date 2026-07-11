#pragma once

#ifdef _KERNEL_MODE
#include <wdm.h>
#else
#include <Windows.h>
#include <winioctl.h>
#endif

// {D18E0D14-E35A-4948-8EE4-9F8550233074}
DEFINE_GUID(
    GUID_DEVINTERFACE_TOPOLOGY_DP_PROBE,
    0xd18e0d14, 0xe35a, 0x4948, 0x8e, 0xe4, 0x9f, 0x85, 0x50, 0x23, 0x30, 0x74);

#define TOPOLOGY_DP_PROBE_STRUCT_VERSION 4u
#define TOPOLOGY_DP_PROBE_MAX_MONITORS 16u
#define TOPOLOGY_DP_PROBE_MAX_DPCD_BYTES 16u
#define TOPOLOGY_DP_PROBE_MAX_DP_ADDRESS 15u
#define TOPOLOGY_DP_PROBE_PATH_CHARS 512u

#define IOCTL_TOPOLOGY_DP_PROBE_LIST \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_ACCESS)

#define IOCTL_TOPOLOGY_DP_PROBE_READ_DPCD \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_READ_ACCESS)

#define IOCTL_TOPOLOGY_DP_PROBE_SET_SINK_POWER \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_WRITE_ACCESS)

typedef struct _TOPOLOGY_DP_PROBE_MONITOR_INFO {
    ULONG MonitorIndex;
    LONG OpenStatus;
    LONG InterfaceStatus;
    LONG CapsStatus;
    ULONG NumRootPorts;
    UCHAR DPVersionMajor;
    UCHAR DPVersionMinor;
    UCHAR Reserved[2];
    WCHAR DeviceInterfacePath[TOPOLOGY_DP_PROBE_PATH_CHARS];
} TOPOLOGY_DP_PROBE_MONITOR_INFO;

typedef struct _TOPOLOGY_DP_PROBE_LIST_OUTPUT {
    ULONG StructVersion;
    ULONG MonitorCount;
    ULONG TotalMonitorInterfaces;
    ULONG Reserved;
    TOPOLOGY_DP_PROBE_MONITOR_INFO Monitors[TOPOLOGY_DP_PROBE_MAX_MONITORS];
} TOPOLOGY_DP_PROBE_LIST_OUTPUT;

typedef struct _TOPOLOGY_DP_PROBE_READ_INPUT {
    ULONG StructVersion;
    ULONG MonitorIndex;
    ULONG TargetId;
    ULONG DPCDAddress;
    ULONG NumBytesRequested;
    ULONG CanUseCachedData;
} TOPOLOGY_DP_PROBE_READ_INPUT;

typedef struct _TOPOLOGY_DP_PROBE_READ_OUTPUT {
    ULONG StructVersion;
    LONG OpenStatus;
    LONG InterfaceStatus;
    LONG CapsStatus;
    LONG AddressStatus;
    LONG AuxStatus;
    ULONG NumRootPorts;
    ULONG MonitorIndex;
    ULONG TargetId;
    ULONG RootPortIndex;
    ULONG DPCDAddress;
    ULONG DPNativeAddressError;
    ULONG DPNativeAuxError;
    ULONG NumLinks;
    ULONG NumBytesRequested;
    ULONG NumBytesDone;
    UCHAR DPVersionMajor;
    UCHAR DPVersionMinor;
    UCHAR Reserved[2];
    UCHAR RelAddress[TOPOLOGY_DP_PROBE_MAX_DP_ADDRESS];
    UCHAR Data[TOPOLOGY_DP_PROBE_MAX_DPCD_BYTES];
} TOPOLOGY_DP_PROBE_READ_OUTPUT;

typedef struct _TOPOLOGY_DP_PROBE_POWER_INPUT {
    ULONG StructVersion;
    ULONG MonitorIndex;
    ULONG TargetId;
    ULONG PowerState;
} TOPOLOGY_DP_PROBE_POWER_INPUT;

typedef struct _TOPOLOGY_DP_PROBE_POWER_OUTPUT {
    ULONG StructVersion;
    LONG OpenStatus;
    LONG InterfaceStatus;
    LONG CapsStatus;
    LONG AddressStatus;
    LONG WriteStatus;
    ULONG MonitorIndex;
    ULONG TargetId;
    ULONG PowerState;
    ULONG NumRootPorts;
    ULONG RootPortIndex;
    ULONG NumLinks;
    ULONG DPNativeAddressError;
    ULONG DPNativeWriteError;
    ULONG NumBytesDone;
} TOPOLOGY_DP_PROBE_POWER_OUTPUT;
