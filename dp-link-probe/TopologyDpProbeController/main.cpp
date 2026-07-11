#include <Windows.h>
#include <SetupAPI.h>

#include <initguid.h>

#include <cerrno>
#include <cwchar>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>

#include "..\shared\TopologyDpProbeIoctl.h"

#pragma comment(lib, "setupapi.lib")

namespace {

constexpr ULONG kControllerRevision = 3;

struct ScopedHandle {
    HANDLE Value = INVALID_HANDLE_VALUE;

    ~ScopedHandle()
    {
        if (Value != INVALID_HANDLE_VALUE) {
            CloseHandle(Value);
        }
    }

    ScopedHandle(const ScopedHandle&) = delete;
    ScopedHandle& operator=(const ScopedHandle&) = delete;
    ScopedHandle() = default;
};

bool NtSuccess(LONG status)
{
    return status >= 0;
}

void PrintStatus(LONG status)
{
    std::wcout << L"0x" << std::hex << std::uppercase
               << std::setw(8) << std::setfill(L'0')
               << static_cast<ULONG>(status)
               << std::dec << std::nouppercase << std::setfill(L' ');
}

bool ParseUnsigned(const wchar_t* text, ULONG* value)
{
    if (text == nullptr || *text == L'\0' || *text == L'-') {
        return false;
    }

    errno = 0;
    wchar_t* end = nullptr;
    unsigned long parsed = std::wcstoul(text, &end, 0);
    if (errno == ERANGE || end == text || *end != L'\0') {
        return false;
    }

    *value = static_cast<ULONG>(parsed);
    return true;
}

HANDLE OpenProbe()
{
    HDEVINFO deviceInfo = SetupDiGetClassDevsW(
        &GUID_DEVINTERFACE_TOPOLOGY_DP_PROBE,
        nullptr,
        nullptr,
        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);

    if (deviceInfo == INVALID_HANDLE_VALUE) {
        return INVALID_HANDLE_VALUE;
    }

    SP_DEVICE_INTERFACE_DATA interfaceData = {};
    interfaceData.cbSize = sizeof(interfaceData);

    if (!SetupDiEnumDeviceInterfaces(
            deviceInfo,
            nullptr,
            &GUID_DEVINTERFACE_TOPOLOGY_DP_PROBE,
            0,
            &interfaceData)) {
        const DWORD error = GetLastError();
        SetupDiDestroyDeviceInfoList(deviceInfo);
        SetLastError(error);
        return INVALID_HANDLE_VALUE;
    }

    DWORD requiredSize = 0;
    (void)SetupDiGetDeviceInterfaceDetailW(
        deviceInfo,
        &interfaceData,
        nullptr,
        0,
        &requiredSize,
        nullptr);

    if (requiredSize == 0) {
        const DWORD error = GetLastError();
        SetupDiDestroyDeviceInfoList(deviceInfo);
        SetLastError(error);
        return INVALID_HANDLE_VALUE;
    }

    std::vector<BYTE> detailBuffer(requiredSize);
    auto* detail = reinterpret_cast<PSP_DEVICE_INTERFACE_DETAIL_DATA_W>(
        detailBuffer.data());
    detail->cbSize = sizeof(*detail);

    if (!SetupDiGetDeviceInterfaceDetailW(
            deviceInfo,
            &interfaceData,
            detail,
            requiredSize,
            nullptr,
            nullptr)) {
        const DWORD error = GetLastError();
        SetupDiDestroyDeviceInfoList(deviceInfo);
        SetLastError(error);
        return INVALID_HANDLE_VALUE;
    }

    HANDLE handle = CreateFileW(
        detail->DevicePath,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        nullptr);

    const DWORD error = GetLastError();
    SetupDiDestroyDeviceInfoList(deviceInfo);
    SetLastError(error);
    return handle;
}

bool QueryMonitors(HANDLE device, TOPOLOGY_DP_PROBE_LIST_OUTPUT* output)
{
    DWORD bytesReturned = 0;
    ZeroMemory(output, sizeof(*output));

    if (!DeviceIoControl(
            device,
            IOCTL_TOPOLOGY_DP_PROBE_LIST,
            nullptr,
            0,
            output,
            sizeof(*output),
            &bytesReturned,
            nullptr)) {
        std::wcerr << L"IOCTL_TOPOLOGY_DP_PROBE_LIST failed. Win32Error="
                   << GetLastError() << L"\n";
        return false;
    }

    if (bytesReturned < sizeof(*output) ||
        output->StructVersion != TOPOLOGY_DP_PROBE_STRUCT_VERSION) {
        std::wcerr << L"Driver returned an incompatible monitor-list structure.\n";
        return false;
    }

    return true;
}

bool ReadDpcd(
    HANDLE device,
    ULONG monitorIndex,
    ULONG targetId,
    ULONG address,
    ULONG length,
    TOPOLOGY_DP_PROBE_READ_OUTPUT* output)
{
    TOPOLOGY_DP_PROBE_READ_INPUT input = {};
    input.StructVersion = TOPOLOGY_DP_PROBE_STRUCT_VERSION;
    input.MonitorIndex = monitorIndex;
    input.TargetId = targetId;
    input.DPCDAddress = address;
    input.NumBytesRequested = length;
    input.CanUseCachedData = 0;

    DWORD bytesReturned = 0;
    ZeroMemory(output, sizeof(*output));

    std::wcout << L"ioctlStage=before-read"
               << L" monitor=" << monitorIndex
               << L" target=" << targetId
               << L" address=0x" << std::hex << address << std::dec
               << L" length=" << length << std::endl;

    if (!DeviceIoControl(
            device,
            IOCTL_TOPOLOGY_DP_PROBE_READ_DPCD,
            &input,
            sizeof(input),
            output,
            sizeof(*output),
            &bytesReturned,
            nullptr)) {
        std::wcerr << L"IOCTL_TOPOLOGY_DP_PROBE_READ_DPCD failed. Win32Error="
                   << GetLastError() << L"\n";
        return false;
    }

    std::wcout << L"ioctlStage=after-read bytesReturned="
               << bytesReturned << std::endl;

    if (bytesReturned < sizeof(*output) ||
        output->StructVersion != TOPOLOGY_DP_PROBE_STRUCT_VERSION) {
        std::wcerr << L"Driver returned an incompatible DPCD-read structure.\n";
        return false;
    }

    if (output->MonitorIndex != monitorIndex ||
        output->TargetId != targetId ||
        output->DPCDAddress != address ||
        output->NumBytesRequested != length) {
        std::wcerr << L"Driver input echo mismatch; DPCD result was rejected."
                   << L" monitor=" << output->MonitorIndex
                   << L" target=" << output->TargetId
                   << L" address=0x" << std::hex << output->DPCDAddress
                   << std::dec << L" length=" << output->NumBytesRequested
                   << L"\n";
        return false;
    }

    return true;
}

bool SetSinkPower(
    HANDLE device,
    ULONG monitorIndex,
    ULONG targetId,
    ULONG powerState,
    TOPOLOGY_DP_PROBE_POWER_OUTPUT* output)
{
    TOPOLOGY_DP_PROBE_POWER_INPUT input = {};
    input.StructVersion = TOPOLOGY_DP_PROBE_STRUCT_VERSION;
    input.MonitorIndex = monitorIndex;
    input.TargetId = targetId;
    input.PowerState = powerState;

    DWORD bytesReturned = 0;
    ZeroMemory(output, sizeof(*output));

    std::wcout << L"ioctlStage=before-set-power"
               << L" monitor=" << monitorIndex
               << L" target=" << targetId
               << L" dpcd=0x600 state=0x" << std::hex << powerState
               << std::dec << std::endl;

    if (!DeviceIoControl(
            device,
            IOCTL_TOPOLOGY_DP_PROBE_SET_SINK_POWER,
            &input,
            sizeof(input),
            output,
            sizeof(*output),
            &bytesReturned,
            nullptr)) {
        std::wcerr << L"IOCTL_TOPOLOGY_DP_PROBE_SET_SINK_POWER failed. Win32Error="
                   << GetLastError() << L"\n";
        return false;
    }

    std::wcout << L"ioctlStage=after-set-power bytesReturned="
               << bytesReturned << std::endl;

    if (bytesReturned < sizeof(*output) ||
        output->StructVersion != TOPOLOGY_DP_PROBE_STRUCT_VERSION) {
        std::wcerr << L"Driver returned an incompatible sink-power structure.\n";
        return false;
    }

    if (output->MonitorIndex != monitorIndex ||
        output->TargetId != targetId ||
        output->PowerState != powerState) {
        std::wcerr << L"Driver sink-power input echo mismatch; result was rejected.\n";
        return false;
    }

    return true;
}

bool IsMonitorInterfaceReady(const TOPOLOGY_DP_PROBE_MONITOR_INFO& monitor)
{
    return NtSuccess(monitor.InterfaceStatus) &&
           NtSuccess(monitor.CapsStatus) &&
           monitor.NumRootPorts > 0;
}

bool PrintMonitors(const TOPOLOGY_DP_PROBE_LIST_OUTPUT& list)
{
    bool interfaceReady = false;
    std::wcout << L"controllerRevision=" << kControllerRevision
               << L" probeProtocolVersion="
               << TOPOLOGY_DP_PROBE_STRUCT_VERSION
               << L" monitorInterfaces=" << list.TotalMonitorInterfaces
               << L" returned=" << list.MonitorCount << L"\n";

    for (ULONG index = 0; index < list.MonitorCount; ++index) {
        const auto& monitor = list.Monitors[index];
        std::wcout << L"monitor=" << monitor.MonitorIndex << L" open=";
        PrintStatus(monitor.OpenStatus);
        std::wcout << L" dpInterface=";
        PrintStatus(monitor.InterfaceStatus);
        std::wcout << L" caps=";
        PrintStatus(monitor.CapsStatus);
        std::wcout << L" rootPorts=" << monitor.NumRootPorts
                   << L" dp=" << static_cast<ULONG>(monitor.DPVersionMajor)
                   << L"." << static_cast<ULONG>(monitor.DPVersionMinor)
                   << L"\n  path=" << monitor.DeviceInterfacePath << L"\n";

        interfaceReady = interfaceReady || IsMonitorInterfaceReady(monitor);
    }

    std::wcout << L"interfaceGate="
               << (interfaceReady ? L"PASS" : L"FAIL")
               << L" safeToRunRead="
               << (interfaceReady ? L"true" : L"false") << L"\n";
    return interfaceReady;
}

void PrintReadResult(const TOPOLOGY_DP_PROBE_READ_OUTPUT& result)
{
    std::wcout << L"monitor=" << result.MonitorIndex
               << L" target=" << result.TargetId
               << L" dpcd=0x" << std::hex << std::uppercase
               << result.DPCDAddress << std::dec << std::nouppercase
               << L" requested=" << result.NumBytesRequested
               << L" open=";
    PrintStatus(result.OpenStatus);
    std::wcout << L" interface=";
    PrintStatus(result.InterfaceStatus);
    std::wcout << L" caps=";
    PrintStatus(result.CapsStatus);
    std::wcout << L" address=";
    PrintStatus(result.AddressStatus);
    std::wcout << L" aux=";
    PrintStatus(result.AuxStatus);
    std::wcout << L"\n";

    if (NtSuccess(result.AddressStatus)) {
        std::wcout << L"  rootPort=" << result.RootPortIndex
                   << L" numLinks=" << result.NumLinks
                   << L" addressNativeError=0x" << std::hex
                   << result.DPNativeAddressError << std::dec
                   << L" relAddress=";

        if (result.NumLinks == 0) {
            std::wcout << L"direct";
        } else {
            ULONG count = result.NumLinks;
            if (count > TOPOLOGY_DP_PROBE_MAX_DP_ADDRESS) {
                count = TOPOLOGY_DP_PROBE_MAX_DP_ADDRESS;
            }
            for (ULONG i = 0; i < count; ++i) {
                if (i != 0) {
                    std::wcout << L".";
                }
                std::wcout << std::hex << std::uppercase
                           << static_cast<ULONG>(result.RelAddress[i])
                           << std::dec << std::nouppercase;
            }
        }
        std::wcout << L"\n";
    }

    if (NtSuccess(result.AuxStatus)) {
        std::wcout << L"  bytesDone=" << result.NumBytesDone
                   << L" auxNativeError=0x" << std::hex
                   << result.DPNativeAuxError << L" data=";

        ULONG count = result.NumBytesDone;
        if (count > TOPOLOGY_DP_PROBE_MAX_DPCD_BYTES) {
            count = TOPOLOGY_DP_PROBE_MAX_DPCD_BYTES;
        }

        for (ULONG i = 0; i < count; ++i) {
            if (i != 0) {
                std::wcout << L" ";
            }
            std::wcout << std::setw(2) << std::setfill(L'0')
                       << static_cast<ULONG>(result.Data[i]);
        }

        std::wcout << std::dec << std::nouppercase << std::setfill(L' ')
                   << L"\n";
    } else if (result.DPNativeAuxError != 0) {
        std::wcout << L"  auxNativeError=0x" << std::hex
                   << result.DPNativeAuxError << std::dec << L"\n";
    }
}

bool GetOption(int argc, wchar_t** argv, const wchar_t* name, ULONG* value)
{
    for (int i = 2; i < argc; ++i) {
        if (_wcsicmp(argv[i], name) == 0 && i + 1 < argc) {
            return ParseUnsigned(argv[i + 1], value);
        }
    }
    return false;
}

bool HasOption(int argc, wchar_t** argv, const wchar_t* name)
{
    for (int i = 2; i < argc; ++i) {
        if (_wcsicmp(argv[i], name) == 0) {
            return true;
        }
    }
    return false;
}

const wchar_t* GetTextOption(int argc, wchar_t** argv, const wchar_t* name)
{
    for (int i = 2; i < argc; ++i) {
        if (_wcsicmp(argv[i], name) == 0 && i + 1 < argc) {
            return argv[i + 1];
        }
    }
    return nullptr;
}

bool GetMonitorOption(int argc, wchar_t** argv, ULONG* value)
{
    return GetOption(argc, argv, L"--monitor", value) ||
           GetOption(argc, argv, L"--adapter", value);
}

bool HasMonitorOption(int argc, wchar_t** argv)
{
    return HasOption(argc, argv, L"--monitor") ||
           HasOption(argc, argv, L"--adapter");
}

int RunRead(HANDLE device, int argc, wchar_t** argv)
{
    ULONG monitor = 0;
    ULONG target = 0;
    ULONG address = 0;
    ULONG length = 0;

    if (!GetMonitorOption(argc, argv, &monitor) ||
        !GetOption(argc, argv, L"--target", &target) ||
        !GetOption(argc, argv, L"--address", &address) ||
        !GetOption(argc, argv, L"--length", &length) ||
        length == 0 || length > TOPOLOGY_DP_PROBE_MAX_DPCD_BYTES) {
        std::wcerr << L"read requires --monitor N --target N --address N --length 1..16\n";
        return 2;
    }

    TOPOLOGY_DP_PROBE_LIST_OUTPUT list = {};
    if (!QueryMonitors(device, &list)) {
        return 1;
    }

    if (monitor >= list.MonitorCount ||
        !IsMonitorInterfaceReady(list.Monitors[monitor])) {
        std::wcerr << L"Selected monitor did not pass the DP interface gate; DPCD read was not sent.\n";
        return 3;
    }

    TOPOLOGY_DP_PROBE_READ_OUTPUT output = {};
    if (!ReadDpcd(device, monitor, target, address, length, &output)) {
        return 1;
    }

    PrintReadResult(output);
    return NtSuccess(output.AuxStatus) ? 0 : 3;
}

int RunSnapshot(HANDLE device, int argc, wchar_t** argv)
{
    ULONG target = 0;
    if (!GetOption(argc, argv, L"--target", &target)) {
        std::wcerr << L"snapshot requires --target N\n";
        return 2;
    }

    ULONG selectedMonitor = 0;
    bool hasSelectedMonitor = GetMonitorOption(
        argc,
        argv,
        &selectedMonitor);

    if (HasMonitorOption(argc, argv) && !hasSelectedMonitor) {
        std::wcerr << L"--monitor requires a numeric value\n";
        return 2;
    }

    TOPOLOGY_DP_PROBE_LIST_OUTPUT list = {};
    if (!QueryMonitors(device, &list)) {
        return 1;
    }

    SYSTEMTIME now = {};
    GetLocalTime(&now);
    std::wcout << std::setfill(L'0')
               << std::setw(4) << static_cast<ULONG>(now.wYear) << L"-"
               << std::setw(2) << static_cast<ULONG>(now.wMonth) << L"-"
               << std::setw(2) << static_cast<ULONG>(now.wDay) << L" "
               << std::setw(2) << static_cast<ULONG>(now.wHour) << L":"
               << std::setw(2) << static_cast<ULONG>(now.wMinute) << L":"
               << std::setw(2) << static_cast<ULONG>(now.wSecond)
               << std::setfill(L' ')
               << L" target=" << target << L" readOnlySnapshot=true"
               << std::endl;
    if (!std::wcout.good()) {
        std::wcerr << L"Snapshot output stream failed before the first DPCD read.\n";
        return 1;
    }

    struct Range {
        ULONG Address;
        ULONG Length;
        const wchar_t* Name;
    };

    const Range ranges[] = {
        {0x00000, 16, L"receiver-capability"},
        {0x00100, 16, L"link-configuration"},
        {0x00200, 8, L"link-status"},
        {0x00600, 1, L"sink-power-state"},
    };

    bool anyReadSucceeded = false;

    for (ULONG i = 0; i < list.MonitorCount; ++i) {
        const ULONG monitor = list.Monitors[i].MonitorIndex;
        if (hasSelectedMonitor && monitor != selectedMonitor) {
            continue;
        }

        if (!IsMonitorInterfaceReady(list.Monitors[i])) {
            continue;
        }

        std::wcout << L"monitor=" << monitor
                   << L" path=" << list.Monitors[i].DeviceInterfacePath
                   << std::endl;

        for (const auto& range : ranges) {
            std::wcout << L"range=" << range.Name << std::endl;
            TOPOLOGY_DP_PROBE_READ_OUTPUT output = {};
            if (!ReadDpcd(
                    device,
                    monitor,
                    target,
                    range.Address,
                    range.Length,
                    &output)) {
                continue;
            }

            PrintReadResult(output);
            anyReadSucceeded = anyReadSucceeded || NtSuccess(output.AuxStatus);

            if (!NtSuccess(output.InterfaceStatus) ||
                !NtSuccess(output.AddressStatus)) {
                break;
            }
        }
    }

    return anyReadSucceeded ? 0 : 3;
}

int RunSetPower(HANDLE device, int argc, wchar_t** argv)
{
    ULONG monitor = 0;
    ULONG target = 0;
    const wchar_t* stateText = GetTextOption(argc, argv, L"--state");

    if (!GetMonitorOption(argc, argv, &monitor) ||
        !GetOption(argc, argv, L"--target", &target) ||
        stateText == nullptr ||
        !HasOption(argc, argv, L"--confirm-standard-dpcd-write")) {
        std::wcerr
            << L"set-power requires --monitor N --target N --state d0 "
            << L"--confirm-standard-dpcd-write\n";
        return 2;
    }

    ULONG powerState = 0;
    if (_wcsicmp(stateText, L"d0") == 0) {
        powerState = 0x01;
    } else {
        std::wcerr << L"--state must be d0; D3 is disabled until a D0 write gate passes\n";
        return 2;
    }

    TOPOLOGY_DP_PROBE_LIST_OUTPUT list = {};
    if (!QueryMonitors(device, &list)) {
        return 1;
    }

    if (monitor >= list.MonitorCount ||
        !IsMonitorInterfaceReady(list.Monitors[monitor])) {
        std::wcerr << L"Selected monitor did not pass the DP interface gate; write was not sent.\n";
        return 3;
    }

    TOPOLOGY_DP_PROBE_POWER_OUTPUT output = {};
    if (!SetSinkPower(device, monitor, target, powerState, &output)) {
        return 1;
    }

    std::wcout << L"monitor=" << output.MonitorIndex
               << L" target=" << output.TargetId
               << L" dpcd=0x600 state=D0"
               << L" open=";
    PrintStatus(output.OpenStatus);
    std::wcout << L" interface=";
    PrintStatus(output.InterfaceStatus);
    std::wcout << L" caps=";
    PrintStatus(output.CapsStatus);
    std::wcout << L" address=";
    PrintStatus(output.AddressStatus);
    std::wcout << L" write=";
    PrintStatus(output.WriteStatus);
    std::wcout << L"\n  rootPort=" << output.RootPortIndex
               << L" rootPorts=" << output.NumRootPorts
               << L" numLinks=" << output.NumLinks
               << L" bytesDone=" << output.NumBytesDone
               << L" addressNativeError=0x" << std::hex
               << output.DPNativeAddressError
               << L" writeNativeError=0x" << output.DPNativeWriteError
               << std::dec << L"\n";

    return NtSuccess(output.WriteStatus) && output.NumBytesDone == 1 ? 0 : 3;
}

void PrintUsage()
{
    std::wcout
        << L"TopologyDpProbeCtl - constrained WDDM DisplayPort diagnostic probe\n\n"
        << L"Commands:\n"
        << L"  TopologyDpProbeCtl.exe list\n"
        << L"  TopologyDpProbeCtl.exe read --monitor N --target N --address 0x600 --length 1\n"
        << L"  TopologyDpProbeCtl.exe snapshot --target N [--monitor N]\n"
        << L"  TopologyDpProbeCtl.exe set-power --monitor N --target N --state d0 "
        << L"--confirm-standard-dpcd-write\n";
}

} // namespace

int wmain(int argc, wchar_t** argv)
{
    std::wcout << std::unitbuf;
    std::wcerr << std::unitbuf;

    if (argc < 2 || _wcsicmp(argv[1], L"help") == 0 ||
        _wcsicmp(argv[1], L"--help") == 0) {
        PrintUsage();
        return 0;
    }

    ScopedHandle device;
    device.Value = OpenProbe();
    if (device.Value == INVALID_HANDLE_VALUE) {
        std::wcerr << L"Unable to open the Topology DP probe device. Win32Error="
                   << GetLastError()
                   << L". Install/start the driver and run as Administrator.\n";
        return 1;
    }

    if (_wcsicmp(argv[1], L"list") == 0) {
        TOPOLOGY_DP_PROBE_LIST_OUTPUT list = {};
        if (!QueryMonitors(device.Value, &list)) {
            return 1;
        }
        return PrintMonitors(list) ? 0 : 3;
    }

    if (_wcsicmp(argv[1], L"read") == 0) {
        return RunRead(device.Value, argc, argv);
    }

    if (_wcsicmp(argv[1], L"snapshot") == 0) {
        return RunSnapshot(device.Value, argc, argv);
    }

    if (_wcsicmp(argv[1], L"set-power") == 0) {
        return RunSetPower(device.Value, argc, argv);
    }

    PrintUsage();
    return 2;
}
