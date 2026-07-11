#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <string>

#include <windows.h>
#include <swdevice.h>

namespace
{
    constexpr wchar_t DeviceId[] = L"TopologyDdcciAnchor";
    constexpr DWORD DeviceCreationTimeoutMilliseconds = 15000;

    HANDLE g_StopEvent = nullptr;

    struct CreationContext
    {
        HANDLE CompletedEvent = nullptr;
        HRESULT Result = E_PENDING;
        std::wstring DeviceInstanceId;
    };

    void PrintUsage()
    {
        std::wprintf(
            L"Usage: TopologyAnchorController.exe [--duration-seconds N]\n"
            L"\n"
            L"Without a duration, the anchor remains connected until Ctrl+C or process shutdown.\n");
    }

    bool TryParseDuration(int argc, wchar_t* argv[], DWORD& durationMilliseconds)
    {
        durationMilliseconds = INFINITE;

        if (argc == 1)
        {
            return true;
        }

        if (argc == 2 && (std::wcscmp(argv[1], L"--help") == 0 || std::wcscmp(argv[1], L"-h") == 0))
        {
            PrintUsage();
            return false;
        }

        if (argc != 3 || std::wcscmp(argv[1], L"--duration-seconds") != 0)
        {
            std::fwprintf(stderr, L"Invalid arguments.\n");
            PrintUsage();
            return false;
        }

        errno = 0;
        wchar_t* end = nullptr;
        const unsigned long long seconds = std::wcstoull(argv[2], &end, 10);
        const unsigned long long maxSeconds = (static_cast<unsigned long long>(INFINITE) - 1) / 1000;
        if (errno == ERANGE || end == argv[2] || *end != L'\0' || seconds == 0 || seconds > maxSeconds)
        {
            std::fwprintf(stderr, L"--duration-seconds must be an integer from 1 through %llu.\n", maxSeconds);
            return false;
        }

        durationMilliseconds = static_cast<DWORD>(seconds * 1000);
        return true;
    }

    BOOL WINAPI ConsoleControlHandler(DWORD controlType)
    {
        switch (controlType)
        {
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT:
        case CTRL_CLOSE_EVENT:
        case CTRL_LOGOFF_EVENT:
        case CTRL_SHUTDOWN_EVENT:
            if (g_StopEvent != nullptr)
            {
                SetEvent(g_StopEvent);
            }
            return TRUE;
        default:
            return FALSE;
        }
    }
}

VOID WINAPI CreationCallback(
    _In_ HSWDEVICE hSwDevice,
    _In_ HRESULT hrCreateResult,
    _In_opt_ PVOID pContext,
    _In_opt_ PCWSTR pszDeviceInstanceId)
{
    UNREFERENCED_PARAMETER(hSwDevice);

    auto* context = static_cast<CreationContext*>(pContext);
    context->Result = hrCreateResult;
    if (pszDeviceInstanceId != nullptr)
    {
        context->DeviceInstanceId = pszDeviceInstanceId;
    }
    SetEvent(context->CompletedEvent);
}

int __cdecl wmain(int argc, wchar_t* argv[])
{
    DWORD durationMilliseconds = INFINITE;
    if (!TryParseDuration(argc, argv, durationMilliseconds))
    {
        return (argc == 2 && (std::wcscmp(argv[1], L"--help") == 0 || std::wcscmp(argv[1], L"-h") == 0)) ? 0 : 2;
    }

    CreationContext context;
    context.CompletedEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_StopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (context.CompletedEvent == nullptr || g_StopEvent == nullptr)
    {
        std::fwprintf(stderr, L"CreateEvent failed with Win32 error %lu.\n", GetLastError());
        if (context.CompletedEvent != nullptr)
        {
            CloseHandle(context.CompletedEvent);
        }
        if (g_StopEvent != nullptr)
        {
            CloseHandle(g_StopEvent);
        }
        return 1;
    }

    if (!SetConsoleCtrlHandler(ConsoleControlHandler, TRUE))
    {
        std::fwprintf(stderr, L"SetConsoleCtrlHandler failed with Win32 error %lu.\n", GetLastError());
        CloseHandle(context.CompletedEvent);
        CloseHandle(g_StopEvent);
        return 1;
    }

    const wchar_t hardwareIds[] = L"TopologyDdcciAnchor\0";
    const wchar_t compatibleIds[] = L"TopologyDdcciAnchor\0";
    SW_DEVICE_CREATE_INFO createInfo = {};
    createInfo.cbSize = sizeof(createInfo);
    createInfo.pszzCompatibleIds = compatibleIds;
    createInfo.pszInstanceId = DeviceId;
    createInfo.pszzHardwareIds = hardwareIds;
    createInfo.pszDeviceDescription = L"Topology DDC Sleep Anchor";
    createInfo.CapabilityFlags = SWDeviceCapabilitiesRemovable |
                                 SWDeviceCapabilitiesSilentInstall |
                                 SWDeviceCapabilitiesDriverRequired;

    HSWDEVICE softwareDevice = nullptr;
    HRESULT result = SwDeviceCreate(
        DeviceId,
        L"HTREE\\ROOT\\0",
        &createInfo,
        0,
        nullptr,
        CreationCallback,
        &context,
        &softwareDevice);
    if (FAILED(result))
    {
        std::fwprintf(stderr, L"SwDeviceCreate failed immediately with HRESULT 0x%08lX.\n", static_cast<unsigned long>(result));
        SetConsoleCtrlHandler(ConsoleControlHandler, FALSE);
        CloseHandle(context.CompletedEvent);
        CloseHandle(g_StopEvent);
        return 1;
    }

    const DWORD creationWait = WaitForSingleObject(context.CompletedEvent, DeviceCreationTimeoutMilliseconds);
    if (creationWait != WAIT_OBJECT_0 || FAILED(context.Result))
    {
        if (creationWait == WAIT_TIMEOUT)
        {
            std::fwprintf(stderr, L"Timed out waiting for software-device creation.\n");
        }
        else if (creationWait == WAIT_FAILED)
        {
            std::fwprintf(stderr, L"Device-creation wait failed with Win32 error %lu.\n", GetLastError());
        }
        else
        {
            std::fwprintf(stderr, L"Software-device creation failed with HRESULT 0x%08lX.\n", static_cast<unsigned long>(context.Result));
        }

        SwDeviceClose(softwareDevice);
        SetConsoleCtrlHandler(ConsoleControlHandler, FALSE);
        CloseHandle(context.CompletedEvent);
        CloseHandle(g_StopEvent);
        return 1;
    }

    std::wprintf(L"READY device=%ls\n", context.DeviceInstanceId.c_str());
    std::fflush(stdout);

    const DWORD stopWait = WaitForSingleObject(g_StopEvent, durationMilliseconds);
    if (stopWait == WAIT_FAILED)
    {
        std::fwprintf(stderr, L"Anchor wait failed with Win32 error %lu.\n", GetLastError());
    }

    SwDeviceClose(softwareDevice);
    SetConsoleCtrlHandler(ConsoleControlHandler, FALSE);
    CloseHandle(context.CompletedEvent);
    CloseHandle(g_StopEvent);
    g_StopEvent = nullptr;

    std::wprintf(L"STOPPED\n");
    return stopWait == WAIT_FAILED ? 1 : 0;
}
