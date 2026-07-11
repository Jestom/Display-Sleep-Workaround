#include <ntddk.h>
#include <wdf.h>
#include <ntstrsafe.h>

#include <initguid.h>
#include <ntddvdeo.h>
#include <dispmprt.h>

#include "..\shared\TopologyDpProbeIoctl.h"

extern "C" DRIVER_INITIALIZE DriverEntry;

EVT_WDF_DRIVER_DEVICE_ADD TopologyDpProbeEvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL TopologyDpProbeEvtIoDeviceControl;

namespace {

constexpr ULONG kDpcdSetPowerAddress = 0x00000600;
constexpr ULONG kDpcdPowerD0 = 0x01;

void ReleaseDpInterface(DXGK_DP_INTERFACE* dpInterface)
{
    if (dpInterface->Context != nullptr &&
        dpInterface->InterfaceDereference != nullptr) {
        dpInterface->InterfaceDereference(dpInterface->Context);
    }

    RtlZeroMemory(dpInterface, sizeof(*dpInterface));
}

NTSTATUS OpenMonitorTarget(
    WDFDEVICE device,
    PCUNICODE_STRING symbolicLink,
    WDFIOTARGET* ioTarget)
{
    *ioTarget = nullptr;

    WDF_OBJECT_ATTRIBUTES attributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = device;

    NTSTATUS status = WdfIoTargetCreate(device, &attributes, ioTarget);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    WDF_IO_TARGET_OPEN_PARAMS openParams;
    WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME(&openParams, symbolicLink, 0);
    openParams.ShareAccess = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

    status = WdfIoTargetOpen(*ioTarget, &openParams);
    if (!NT_SUCCESS(status)) {
        WdfObjectDelete(*ioTarget);
        *ioTarget = nullptr;
    }

    return status;
}

void CloseMonitorTarget(WDFIOTARGET ioTarget)
{
    if (ioTarget != nullptr) {
        WdfIoTargetClose(ioTarget);
        WdfObjectDelete(ioTarget);
    }
}

NTSTATUS QueryDpInterface(WDFIOTARGET ioTarget, DXGK_DP_INTERFACE* dpInterface)
{
    RtlZeroMemory(dpInterface, sizeof(*dpInterface));

    NTSTATUS status = WdfIoTargetQueryForInterface(
        ioTarget,
        &GUID_DXGK_DP_INTERFACE,
        reinterpret_cast<PINTERFACE>(dpInterface),
        sizeof(*dpInterface),
        DXGK_DP_INTERFACE_VERSION_1,
        nullptr);

    if (!NT_SUCCESS(status)) {
        return status;
    }

    if (dpInterface->Context == nullptr ||
        dpInterface->InterfaceDereference == nullptr ||
        dpInterface->DxgkDdiQueryDPCaps == nullptr ||
        dpInterface->DxgkDdiGetDPAddress == nullptr ||
        dpInterface->DxgkDdiDPAuxIoTransmission == nullptr) {
        ReleaseDpInterface(dpInterface);
        return STATUS_INVALID_DEVICE_STATE;
    }

    return STATUS_SUCCESS;
}

NTSTATUS GetLinkLength(PCWSTR link, size_t* linkLength)
{
    return RtlStringCchLengthW(link, NTSTRSAFE_MAX_CCH, linkLength);
}

NTSTATUS OpenMonitorTargetByIndex(
    WDFDEVICE device,
    ULONG monitorIndex,
    WDFIOTARGET* ioTarget)
{
    PWSTR symbolicLinks = nullptr;
    NTSTATUS status = IoGetDeviceInterfaces(
        &GUID_DEVINTERFACE_MONITOR,
        nullptr,
        0,
        &symbolicLinks);

    if (!NT_SUCCESS(status)) {
        return status;
    }

    ULONG currentIndex = 0;
    PWSTR current = symbolicLinks;
    status = STATUS_NOT_FOUND;

    while (*current != L'\0') {
        size_t linkLength = 0;
        status = GetLinkLength(current, &linkLength);
        if (!NT_SUCCESS(status)) {
            break;
        }

        if (currentIndex == monitorIndex) {
            UNICODE_STRING symbolicLink;
            RtlInitUnicodeString(&symbolicLink, current);
            status = OpenMonitorTarget(device, &symbolicLink, ioTarget);
            break;
        }

        ++currentIndex;
        current += linkLength + 1;
        status = STATUS_NOT_FOUND;
    }

    ExFreePool(symbolicLinks);
    return status;
}

NTSTATUS FillMonitorList(
    WDFDEVICE device,
    TOPOLOGY_DP_PROBE_LIST_OUTPUT* output)
{
    PWSTR symbolicLinks = nullptr;
    NTSTATUS status = IoGetDeviceInterfaces(
        &GUID_DEVINTERFACE_MONITOR,
        nullptr,
        0,
        &symbolicLinks);

    if (!NT_SUCCESS(status)) {
        return status;
    }

    ULONG monitorIndex = 0;
    PWSTR current = symbolicLinks;

    while (*current != L'\0') {
        size_t linkLength = 0;
        status = GetLinkLength(current, &linkLength);
        if (!NT_SUCCESS(status)) {
            break;
        }

        if (monitorIndex < TOPOLOGY_DP_PROBE_MAX_MONITORS) {
            auto* monitor = &output->Monitors[monitorIndex];
            monitor->MonitorIndex = monitorIndex;
            monitor->OpenStatus = STATUS_NOT_SUPPORTED;
            monitor->InterfaceStatus = STATUS_NOT_SUPPORTED;
            monitor->CapsStatus = STATUS_NOT_SUPPORTED;

            (void)RtlStringCchCopyW(
                monitor->DeviceInterfacePath,
                TOPOLOGY_DP_PROBE_PATH_CHARS,
                current);

            UNICODE_STRING symbolicLink;
            RtlInitUnicodeString(&symbolicLink, current);

            WDFIOTARGET ioTarget = nullptr;
            monitor->OpenStatus = OpenMonitorTarget(device, &symbolicLink, &ioTarget);

            if (NT_SUCCESS(monitor->OpenStatus)) {
                DXGK_DP_INTERFACE dpInterface = {};
                monitor->InterfaceStatus = QueryDpInterface(ioTarget, &dpInterface);

                if (NT_SUCCESS(monitor->InterfaceStatus)) {
                    const auto context = dpInterface.Context;
                    const auto queryDpCaps = dpInterface.DxgkDdiQueryDPCaps;

                    if (context == nullptr || queryDpCaps == nullptr) {
                        monitor->InterfaceStatus = STATUS_INVALID_DEVICE_STATE;
                    } else {
                        DXGKARG_QUERYDPCAPS caps = {};
                        monitor->CapsStatus = queryDpCaps(context, &caps);

                        if (NT_SUCCESS(monitor->CapsStatus)) {
                            monitor->NumRootPorts = caps.NumRootPorts;
                            monitor->DPVersionMajor = caps.DPVersionMajor;
                            monitor->DPVersionMinor = caps.DPVersionMinor;
                        }
                    }

                    ReleaseDpInterface(&dpInterface);
                }

                CloseMonitorTarget(ioTarget);
            }

            ++output->MonitorCount;
        }

        ++monitorIndex;
        current += linkLength + 1;
    }

    output->TotalMonitorInterfaces = monitorIndex;
    ExFreePool(symbolicLinks);
    return status;
}

void HandleListRequest(WDFDEVICE device, WDFREQUEST request)
{
    TOPOLOGY_DP_PROBE_LIST_OUTPUT* output = nullptr;
    size_t outputLength = 0;
    NTSTATUS status = WdfRequestRetrieveOutputBuffer(
        request,
        sizeof(*output),
        reinterpret_cast<PVOID*>(&output),
        &outputLength);

    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(request, status);
        return;
    }

    if (outputLength < sizeof(*output)) {
        WdfRequestComplete(request, STATUS_BUFFER_TOO_SMALL);
        return;
    }

    RtlZeroMemory(output, sizeof(*output));
    output->StructVersion = TOPOLOGY_DP_PROBE_STRUCT_VERSION;

    status = FillMonitorList(device, output);
    WdfRequestCompleteWithInformation(
        request,
        status,
        NT_SUCCESS(status) ? sizeof(*output) : 0);
}

void HandleReadRequest(WDFDEVICE device, WDFREQUEST request)
{
    TOPOLOGY_DP_PROBE_READ_INPUT* input = nullptr;
    TOPOLOGY_DP_PROBE_READ_OUTPUT* output = nullptr;
    size_t inputLength = 0;
    size_t outputLength = 0;

    NTSTATUS status = WdfRequestRetrieveInputBuffer(
        request,
        sizeof(*input),
        reinterpret_cast<PVOID*>(&input),
        &inputLength);

    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(request, status);
        return;
    }

    if (inputLength < sizeof(*input)) {
        WdfRequestComplete(request, STATUS_BUFFER_TOO_SMALL);
        return;
    }

    status = WdfRequestRetrieveOutputBuffer(
        request,
        sizeof(*output),
        reinterpret_cast<PVOID*>(&output),
        &outputLength);

    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(request, status);
        return;
    }

    if (outputLength < sizeof(*output)) {
        WdfRequestComplete(request, STATUS_BUFFER_TOO_SMALL);
        return;
    }

    if (input->StructVersion != TOPOLOGY_DP_PROBE_STRUCT_VERSION ||
        input->MonitorIndex >= TOPOLOGY_DP_PROBE_MAX_MONITORS ||
        input->NumBytesRequested == 0 ||
        input->NumBytesRequested > TOPOLOGY_DP_PROBE_MAX_DPCD_BYTES ||
        input->DPCDAddress > 0x000fffff ||
        input->NumBytesRequested - 1 > 0x000fffff - input->DPCDAddress ||
        input->CanUseCachedData > 1) {
        WdfRequestComplete(request, STATUS_INVALID_PARAMETER);
        return;
    }

    const TOPOLOGY_DP_PROBE_READ_INPUT inputCopy = *input;

    RtlZeroMemory(output, sizeof(*output));
    output->StructVersion = TOPOLOGY_DP_PROBE_STRUCT_VERSION;
    output->OpenStatus = STATUS_NOT_SUPPORTED;
    output->InterfaceStatus = STATUS_NOT_SUPPORTED;
    output->CapsStatus = STATUS_NOT_SUPPORTED;
    output->AddressStatus = STATUS_NOT_SUPPORTED;
    output->AuxStatus = STATUS_NOT_SUPPORTED;
    output->MonitorIndex = inputCopy.MonitorIndex;
    output->TargetId = inputCopy.TargetId;
    output->DPCDAddress = inputCopy.DPCDAddress;
    output->NumBytesRequested = inputCopy.NumBytesRequested;

    WDFIOTARGET ioTarget = nullptr;
    output->OpenStatus = OpenMonitorTargetByIndex(
        device,
        inputCopy.MonitorIndex,
        &ioTarget);

    if (NT_SUCCESS(output->OpenStatus)) {
        DXGK_DP_INTERFACE dpInterface = {};
        output->InterfaceStatus = QueryDpInterface(ioTarget, &dpInterface);

        if (NT_SUCCESS(output->InterfaceStatus)) {
            const auto context = dpInterface.Context;
            const auto queryDpCaps = dpInterface.DxgkDdiQueryDPCaps;
            const auto getDpAddress = dpInterface.DxgkDdiGetDPAddress;
            const auto readDpAux = dpInterface.DxgkDdiDPAuxIoTransmission;

            if (context == nullptr ||
                queryDpCaps == nullptr ||
                getDpAddress == nullptr ||
                readDpAux == nullptr) {
                output->InterfaceStatus = STATUS_INVALID_DEVICE_STATE;
            } else {
                DXGKARG_QUERYDPCAPS caps = {};
                output->CapsStatus = queryDpCaps(context, &caps);

                if (NT_SUCCESS(output->CapsStatus)) {
                    output->NumRootPorts = caps.NumRootPorts;
                    output->DPVersionMajor = caps.DPVersionMajor;
                    output->DPVersionMinor = caps.DPVersionMinor;
                }

                DXGKARG_GETDPADDRESS address = {};
                address.TargetId = inputCopy.TargetId;
                output->AddressStatus = getDpAddress(context, &address);

                output->DPNativeAddressError = address.DPNativeError;
                output->RootPortIndex = address.RootPortIndex;
                output->NumLinks = address.NumLinks;
                RtlCopyMemory(
                    output->RelAddress,
                    address.RelAddress,
                    sizeof(output->RelAddress));

                const bool rootPortIsValid =
                    NT_SUCCESS(output->CapsStatus) &&
                    address.RootPortIndex < caps.NumRootPorts;

                if (NT_SUCCESS(output->AddressStatus) &&
                    address.NumLinks == 0 &&
                    rootPortIsValid) {
                    DXGKARG_DPAUXIOTRANSMISSION aux = {};
                    aux.Write = 0;
                    aux.CanUseCachedData = inputCopy.CanUseCachedData;
                    aux.RootPortIndex = address.RootPortIndex;
                    aux.DPCDAddress = inputCopy.DPCDAddress;
                    aux.NumBytesRequested = static_cast<BYTE>(inputCopy.NumBytesRequested);

                    output->AuxStatus = readDpAux(context, &aux);

                    output->DPNativeAuxError = aux.DPNativeError;
                    output->NumBytesDone = aux.NumBytesDone;
                    RtlCopyMemory(output->Data, aux.Data, sizeof(output->Data));
                }
            }

            ReleaseDpInterface(&dpInterface);
        }

        CloseMonitorTarget(ioTarget);
    }

    WdfRequestCompleteWithInformation(request, STATUS_SUCCESS, sizeof(*output));
}

void HandleSetSinkPowerRequest(WDFDEVICE device, WDFREQUEST request)
{
    TOPOLOGY_DP_PROBE_POWER_INPUT* input = nullptr;
    TOPOLOGY_DP_PROBE_POWER_OUTPUT* output = nullptr;
    size_t inputLength = 0;
    size_t outputLength = 0;

    NTSTATUS status = WdfRequestRetrieveInputBuffer(
        request,
        sizeof(*input),
        reinterpret_cast<PVOID*>(&input),
        &inputLength);

    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(request, status);
        return;
    }

    if (inputLength < sizeof(*input)) {
        WdfRequestComplete(request, STATUS_BUFFER_TOO_SMALL);
        return;
    }

    status = WdfRequestRetrieveOutputBuffer(
        request,
        sizeof(*output),
        reinterpret_cast<PVOID*>(&output),
        &outputLength);

    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(request, status);
        return;
    }

    if (outputLength < sizeof(*output)) {
        WdfRequestComplete(request, STATUS_BUFFER_TOO_SMALL);
        return;
    }

    if (input->StructVersion != TOPOLOGY_DP_PROBE_STRUCT_VERSION ||
        input->MonitorIndex >= TOPOLOGY_DP_PROBE_MAX_MONITORS ||
        input->PowerState != kDpcdPowerD0) {
        WdfRequestComplete(request, STATUS_INVALID_PARAMETER);
        return;
    }

    const TOPOLOGY_DP_PROBE_POWER_INPUT inputCopy = *input;

    RtlZeroMemory(output, sizeof(*output));
    output->StructVersion = TOPOLOGY_DP_PROBE_STRUCT_VERSION;
    output->OpenStatus = STATUS_NOT_SUPPORTED;
    output->InterfaceStatus = STATUS_NOT_SUPPORTED;
    output->CapsStatus = STATUS_NOT_SUPPORTED;
    output->AddressStatus = STATUS_NOT_SUPPORTED;
    output->WriteStatus = STATUS_NOT_SUPPORTED;
    output->MonitorIndex = inputCopy.MonitorIndex;
    output->TargetId = inputCopy.TargetId;
    output->PowerState = inputCopy.PowerState;

    WDFIOTARGET ioTarget = nullptr;
    output->OpenStatus = OpenMonitorTargetByIndex(
        device,
        inputCopy.MonitorIndex,
        &ioTarget);

    if (NT_SUCCESS(output->OpenStatus)) {
        DXGK_DP_INTERFACE dpInterface = {};
        output->InterfaceStatus = QueryDpInterface(ioTarget, &dpInterface);

        if (NT_SUCCESS(output->InterfaceStatus)) {
            const auto context = dpInterface.Context;
            const auto queryDpCaps = dpInterface.DxgkDdiQueryDPCaps;
            const auto getDpAddress = dpInterface.DxgkDdiGetDPAddress;
            const auto auxTransmission = dpInterface.DxgkDdiDPAuxIoTransmission;

            if (context == nullptr ||
                queryDpCaps == nullptr ||
                getDpAddress == nullptr ||
                auxTransmission == nullptr) {
                output->InterfaceStatus = STATUS_INVALID_DEVICE_STATE;
            } else {
                DXGKARG_QUERYDPCAPS caps = {};
                output->CapsStatus = queryDpCaps(context, &caps);
                if (NT_SUCCESS(output->CapsStatus)) {
                    output->NumRootPorts = caps.NumRootPorts;
                }

                DXGKARG_GETDPADDRESS address = {};
                address.TargetId = inputCopy.TargetId;
                output->AddressStatus = getDpAddress(context, &address);
                output->DPNativeAddressError = address.DPNativeError;
                output->RootPortIndex = address.RootPortIndex;
                output->NumLinks = address.NumLinks;

                const bool directRootPortIsValid =
                    NT_SUCCESS(output->CapsStatus) &&
                    NT_SUCCESS(output->AddressStatus) &&
                    address.NumLinks == 0 &&
                    address.RootPortIndex < caps.NumRootPorts;

                if (directRootPortIsValid) {
                    DXGKARG_DPAUXIOTRANSMISSION aux = {};
                    aux.Write = 1;
                    aux.CanUseCachedData = 0;
                    aux.RootPortIndex = address.RootPortIndex;
                    aux.DPCDAddress = kDpcdSetPowerAddress;
                    aux.NumBytesRequested = 1;
                    aux.Data[0] = static_cast<BYTE>(inputCopy.PowerState);

                    output->WriteStatus = auxTransmission(context, &aux);
                    output->DPNativeWriteError = aux.DPNativeError;
                    output->NumBytesDone = aux.NumBytesDone;
                }
            }

            ReleaseDpInterface(&dpInterface);
        }

        CloseMonitorTarget(ioTarget);
    }

    WdfRequestCompleteWithInformation(request, STATUS_SUCCESS, sizeof(*output));
}

} // namespace

extern "C"
NTSTATUS DriverEntry(PDRIVER_OBJECT driverObject, PUNICODE_STRING registryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, TopologyDpProbeEvtDeviceAdd);

    return WdfDriverCreate(
        driverObject,
        registryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        WDF_NO_HANDLE);
}

NTSTATUS TopologyDpProbeEvtDeviceAdd(
    WDFDRIVER driver,
    PWDFDEVICE_INIT deviceInit)
{
    UNREFERENCED_PARAMETER(driver);

    WdfDeviceInitSetDeviceType(deviceInit, FILE_DEVICE_UNKNOWN);
    WdfDeviceInitSetExclusive(deviceInit, FALSE);
    WdfDeviceInitSetIoType(deviceInit, WdfDeviceIoBuffered);

    WDF_OBJECT_ATTRIBUTES deviceAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&deviceAttributes);
    deviceAttributes.ExecutionLevel = WdfExecutionLevelPassive;

    WDFDEVICE device = nullptr;
    NTSTATUS status = WdfDeviceCreate(
        &deviceInit,
        &deviceAttributes,
        &device);

    if (!NT_SUCCESS(status)) {
        return status;
    }

    status = WdfDeviceCreateDeviceInterface(
        device,
        &GUID_DEVINTERFACE_TOPOLOGY_DP_PROBE,
        nullptr);

    if (!NT_SUCCESS(status)) {
        return status;
    }

    WDF_IO_QUEUE_CONFIG queueConfig;
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(
        &queueConfig,
        WdfIoQueueDispatchSequential);
    queueConfig.EvtIoDeviceControl = TopologyDpProbeEvtIoDeviceControl;

    return WdfIoQueueCreate(
        device,
        &queueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        WDF_NO_HANDLE);
}

void TopologyDpProbeEvtIoDeviceControl(
    WDFQUEUE queue,
    WDFREQUEST request,
    size_t outputBufferLength,
    size_t inputBufferLength,
    ULONG ioControlCode)
{
    UNREFERENCED_PARAMETER(outputBufferLength);
    UNREFERENCED_PARAMETER(inputBufferLength);

    WDFDEVICE device = WdfIoQueueGetDevice(queue);

    switch (ioControlCode) {
    case IOCTL_TOPOLOGY_DP_PROBE_LIST:
        HandleListRequest(device, request);
        break;

    case IOCTL_TOPOLOGY_DP_PROBE_READ_DPCD:
        HandleReadRequest(device, request);
        break;

    case IOCTL_TOPOLOGY_DP_PROBE_SET_SINK_POWER:
        HandleSetSinkPowerRequest(device, request);
        break;

    default:
        WdfRequestComplete(request, STATUS_INVALID_DEVICE_REQUEST);
        break;
    }
}
