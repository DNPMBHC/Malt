/* SPDX-License-Identifier: GPL-3.0-or-later */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <wintrust.h>
#include <softpub.h>
#include <stdio.h>
#include <wchar.h>
#include <inttypes.h>
#include <string.h>
#include "../shared/module_a_protocol.h"

#ifndef IMAGE_FILE_MACHINE_ARM64EC
#define IMAGE_FILE_MACHINE_ARM64EC 0xA641
#endif

typedef BOOL (WINAPI *MODULE_A_IS_WOW64_PROCESS_2)(HANDLE, USHORT *, USHORT *);
typedef LONG (WINAPI *MODULE_A_RTL_GET_VERSION)(OSVERSIONINFOW *);

static const char *MachineName(USHORT machine)
{
    switch (machine) {
    case IMAGE_FILE_MACHINE_ARM64: return "arm64";
    case IMAGE_FILE_MACHINE_AMD64: return "x64";
    case IMAGE_FILE_MACHINE_I386: return "x86";
    case IMAGE_FILE_MACHINE_ARM64EC: return "arm64ec";
    default: return "unknown";
    }
}

static BOOL IsNonce(const wchar_t *value)
{
    size_t index;
    if (value == NULL || wcslen(value) != 64) return FALSE;
    for (index = 0; index < 64; ++index) {
        if (!((value[index] >= L'0' && value[index] <= L'9') ||
              (value[index] >= L'a' && value[index] <= L'f'))) return FALSE;
    }
    return TRUE;
}

static BOOL ReadAt(HANDLE file, LONGLONG offset, void *buffer, DWORD size)
{
    LARGE_INTEGER position;
    DWORD bytes = 0;
    position.QuadPart = offset;
    return SetFilePointerEx(file, position, NULL, FILE_BEGIN) &&
        ReadFile(file, buffer, size, &bytes, NULL) && bytes == size;
}

static USHORT ImageMachine(const wchar_t *path)
{
    HANDLE file;
    IMAGE_DOS_HEADER dos;
    DWORD signature;
    IMAGE_FILE_HEADER header;
    LARGE_INTEGER length;
    USHORT machine = 0;

    if (path == NULL) return machine;
    file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return machine;
    if (GetFileSizeEx(file, &length) && length.QuadPart >= sizeof(dos) &&
        ReadAt(file, 0, &dos, sizeof(dos)) && dos.e_magic == IMAGE_DOS_SIGNATURE &&
        dos.e_lfanew >= sizeof(dos) &&
        (LONGLONG)dos.e_lfanew <= length.QuadPart - (LONGLONG)sizeof(signature) - (LONGLONG)sizeof(header) &&
        ReadAt(file, dos.e_lfanew, &signature, sizeof(signature)) && signature == IMAGE_NT_SIGNATURE &&
        ReadAt(file, (LONGLONG)dos.e_lfanew + sizeof(signature), &header, sizeof(header))) {
        machine = header.Machine;
    }
    CloseHandle(file);
    return machine;
}

static const char *ImageSignature(const wchar_t *path)
{
    WINTRUST_FILE_INFO file;
    WINTRUST_DATA trust;
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    LONG status;

    if (path == NULL) return "unknown";
    ZeroMemory(&file, sizeof(file));
    file.cbStruct = sizeof(file);
    file.pcwszFilePath = path;
    ZeroMemory(&trust, sizeof(trust));
    trust.cbStruct = sizeof(trust);
    trust.dwUIChoice = WTD_UI_NONE;
    trust.fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN;
    trust.dwUnionChoice = WTD_CHOICE_FILE;
    trust.pFile = &file;
    trust.dwStateAction = WTD_STATEACTION_VERIFY;
    status = WinVerifyTrust(NULL, &action, &trust);
    trust.dwStateAction = WTD_STATEACTION_CLOSE;
    (void)WinVerifyTrust(NULL, &action, &trust);
    if (status == ERROR_SUCCESS) return "trustedAuthenticode";
    if (status == TRUST_E_NOSIGNATURE || status == TRUST_E_SUBJECT_FORM_UNKNOWN ||
        status == TRUST_E_PROVIDER_UNKNOWN) return "unsignedOrNoSignature";
    if (status == TRUST_E_BAD_DIGEST || status == TRUST_E_EXPLICIT_DISTRUST ||
        status == CERT_E_REVOKED || status == CERT_E_EXPIRED ||
        status == CERT_E_UNTRUSTEDROOT || status == TRUST_E_SUBJECT_NOT_TRUSTED) {
        return "untrusted";
    }
    return "unknown";
}

static uint64_t UnixSeconds(void)
{
    FILETIME fileTime;
    ULARGE_INTEGER value;
    const uint64_t epoch = UINT64_C(116444736000000000);
    GetSystemTimeAsFileTime(&fileTime);
    value.LowPart = fileTime.dwLowDateTime;
    value.HighPart = fileTime.dwHighDateTime;
    return value.QuadPart >= epoch ? (value.QuadPart - epoch) / UINT64_C(10000000) : 0;
}

static void RecordFailure(const char **stage, DWORD *win32Error,
    const char *newStage, DWORD newError)
{
    if (strcmp(*stage, "none") == 0) {
        *stage = newStage;
        *win32Error = newError;
    }
}

static BOOL ValidSelfResponse(const MODULE_A_SELF_RESPONSE *response, DWORD bytes)
{
    return bytes == sizeof(*response) &&
        response->struct_size == sizeof(*response) &&
        response->protocol_version == MODULE_A_PROTOCOL_VERSION &&
        response->scope == MODULE_A_SCOPE_SELF_ONLY &&
        response->requestor_matches_current_context <= 1 &&
        response->reserved == 0 && response->requestor_pid != 0 &&
        response->dispatch_attached_context_pid != 0;
}

static BOOL ValidNotificationResponse(
    const MODULE_A_NOTIFICATION_RESPONSE *response, DWORD bytes)
{
    return bytes == sizeof(*response) &&
        response->struct_size == sizeof(*response) &&
        response->protocol_version == MODULE_A_PROTOCOL_VERSION &&
        response->armed <= 1 && response->create_observed <= 1 &&
        response->exit_observed <= 1 && response->reserved[0] == 0 &&
        response->reserved[1] == 0 && response->reserved[2] == 0;
}

static BOOL ValidBindResponse(
    const MODULE_A_NOTIFICATION_BIND_RESPONSE *response, DWORD bytes,
    uint64_t expectedChildPID)
{
    return bytes == sizeof(*response) &&
        response->struct_size == sizeof(*response) &&
        response->protocol_version == MODULE_A_PROTOCOL_VERSION &&
        response->bound_child_pid == expectedChildPID;
}

static BOOL QueryNotification(HANDLE device, MODULE_A_SELF_REQUEST *request,
    MODULE_A_NOTIFICATION_RESPONSE *response, DWORD *bytesReturned,
    DWORD *win32Error, BOOL *malformedResponse)
{
    unsigned int attempt;
    *malformedResponse = FALSE;
    for (attempt = 0; attempt < 40; ++attempt) {
        ZeroMemory(response, sizeof(*response));
        *bytesReturned = 0;
        if (!DeviceIoControl(device, MODULE_A_IOCTL_QUERY_NOTIFICATION, request,
            sizeof(*request), response, sizeof(*response), bytesReturned, NULL)) {
            *win32Error = GetLastError();
            return FALSE;
        }
        if (!ValidNotificationResponse(response, *bytesReturned)) {
            *win32Error = 0;
            *malformedResponse = TRUE;
            return FALSE;
        }
        if (response->create_observed && response->exit_observed) return TRUE;
        Sleep(50);
    }
    *win32Error = ERROR_SUCCESS;
    return TRUE;
}

static BOOL RunNotificationProbe(HANDLE device, MODULE_A_SELF_REQUEST *request,
    BOOL *createObserved, BOOL *exitObserved, BOOL *cleanupComplete,
    BOOL *childPIDMatched, uint64_t *boundChildPID,
    DWORD *bytesReturned,
    const char **failureStage, DWORD *win32Error)
{
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    MODULE_A_NOTIFICATION_RESPONSE notification;
    MODULE_A_NOTIFICATION_BIND_REQUEST bindRequest;
    MODULE_A_NOTIFICATION_BIND_RESPONSE bindResponse;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION jobLimits;
    HANDLE childJob = NULL;
    wchar_t executable[MAX_PATH];
    wchar_t commandLine[MAX_PATH + 32];
    DWORD pathLength;
    DWORD notificationBytes = 0;
    DWORD notificationError = 0;
    BOOL malformedResponse = FALSE;
    BOOL armed = FALSE;
    BOOL childStarted = FALSE;
    BOOL childBound = FALSE;
    BOOL childResumed = FALSE;
    BOOL childCompleted = FALSE;
    BOOL childCleanupComplete = FALSE;
    BOOL notificationValid = FALSE;
    DWORD waitResult;
    BOOL result = FALSE;

    *cleanupComplete = FALSE;
    *childPIDMatched = FALSE;
    *boundChildPID = 0;

    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    pathLength = GetModuleFileNameW(NULL, executable, (DWORD)(sizeof(executable) / sizeof(executable[0])));
    if (pathLength == 0 || pathLength >= sizeof(executable) / sizeof(executable[0])) {
        RecordFailure(failureStage, win32Error, "notification",
            pathLength == 0 ? GetLastError() : ERROR_INSUFFICIENT_BUFFER);
        return FALSE;
    }
    if (_snwprintf_s(commandLine, sizeof(commandLine) / sizeof(commandLine[0]),
        _TRUNCATE, L"\"%ls\" --probe-child", executable) < 0) {
        RecordFailure(failureStage, win32Error, "notification", ERROR_INSUFFICIENT_BUFFER);
        return FALSE;
    }

    *bytesReturned = 0;
    if (!DeviceIoControl(device, MODULE_A_IOCTL_ARM_NOTIFICATION, request,
        sizeof(*request), NULL, 0, bytesReturned, NULL)) {
        RecordFailure(failureStage, win32Error, "notification", GetLastError());
        return FALSE;
    }
    armed = TRUE;

    childJob = CreateJobObjectW(NULL, NULL);
    if (childJob == NULL) {
        RecordFailure(failureStage, win32Error, "notification", GetLastError());
    } else {
        ZeroMemory(&jobLimits, sizeof(jobLimits));
        jobLimits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(childJob, JobObjectExtendedLimitInformation,
            &jobLimits, sizeof(jobLimits))) {
            RecordFailure(failureStage, win32Error, "notification", GetLastError());
            CloseHandle(childJob);
            childJob = NULL;
        }
    }

    if (childJob == NULL) {
        /* Job setup is required so a timed-out test child can be reaped. */
    } else if (!CreateProcessW(executable, commandLine, NULL, NULL, FALSE,
        CREATE_NO_WINDOW | CREATE_SUSPENDED, NULL, NULL, &startup, &process)) {
        RecordFailure(failureStage, win32Error, "notification", GetLastError());
    } else {
        childStarted = TRUE;
        if (!AssignProcessToJobObject(childJob, process.hProcess)) {
            RecordFailure(failureStage, win32Error, "notification", GetLastError());
        } else {
            ZeroMemory(&bindRequest, sizeof(bindRequest));
            bindRequest.struct_size = sizeof(bindRequest);
            bindRequest.protocol_version = MODULE_A_PROTOCOL_VERSION;
            bindRequest.child_pid = (uint64_t)process.dwProcessId;
            ZeroMemory(&bindResponse, sizeof(bindResponse));
            notificationBytes = 0;
            if (!DeviceIoControl(device, MODULE_A_IOCTL_BIND_NOTIFICATION,
                &bindRequest, sizeof(bindRequest), &bindResponse, sizeof(bindResponse),
                &notificationBytes, NULL)) {
                RecordFailure(failureStage, win32Error, "notification", GetLastError());
            } else if (!ValidBindResponse(&bindResponse, notificationBytes,
                                          (uint64_t)process.dwProcessId)) {
                RecordFailure(failureStage, win32Error, "response", ERROR_SUCCESS);
            } else {
                childBound = TRUE;
                *childPIDMatched = TRUE;
                *boundChildPID = bindResponse.bound_child_pid;
                if (ResumeThread(process.hThread) == (DWORD)-1) {
                    RecordFailure(failureStage, win32Error, "notification", GetLastError());
                } else {
                    childResumed = TRUE;
                }
            }
        }
        if (!childResumed && !TerminateProcess(process.hProcess, 1) &&
            GetLastError() != ERROR_ACCESS_DENIED) {
            RecordFailure(failureStage, win32Error, "notification", GetLastError());
        }
        waitResult = WaitForSingleObject(process.hProcess, 5000);
        if (waitResult == WAIT_OBJECT_0) {
            childCleanupComplete = TRUE;
            DWORD exitCode = 1;
            BOOL gotExitCode = GetExitCodeProcess(process.hProcess, &exitCode);
            childCompleted = gotExitCode && exitCode == 0;
            if (!childCompleted) {
                RecordFailure(failureStage, win32Error, "notification",
                    gotExitCode ? ERROR_PROCESS_ABORTED : GetLastError());
            }
        } else {
            DWORD error = waitResult == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError();
            RecordFailure(failureStage, win32Error, "notification", error);
            if (!TerminateProcess(process.hProcess, 1) &&
                GetLastError() != ERROR_ACCESS_DENIED) {
                RecordFailure(failureStage, win32Error, "notification", GetLastError());
            }
            waitResult = WaitForSingleObject(process.hProcess, 5000);
            if (waitResult == WAIT_OBJECT_0) {
                childCleanupComplete = TRUE;
                DWORD exitCode = 1;
                BOOL gotExitCode = GetExitCodeProcess(process.hProcess, &exitCode);
                childCompleted = gotExitCode && exitCode == 0;
                if (!childCompleted) {
                    RecordFailure(failureStage, win32Error, "notification",
                        gotExitCode ? ERROR_PROCESS_ABORTED : GetLastError());
                }
            } else {
                RecordFailure(failureStage, win32Error, "notification",
                    waitResult == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError());
            }
        }
        if (!childCleanupComplete && childJob != NULL) {
            if (CloseHandle(childJob)) {
                childJob = NULL;
            } else {
                RecordFailure(failureStage, win32Error, "notification", GetLastError());
            }
            waitResult = WaitForSingleObject(process.hProcess, 5000);
            if (waitResult == WAIT_OBJECT_0) {
                childCleanupComplete = TRUE;
                DWORD exitCode = 1;
                BOOL gotExitCode = GetExitCodeProcess(process.hProcess, &exitCode);
                childCompleted = gotExitCode && exitCode == 0;
                if (!childCompleted) {
                    RecordFailure(failureStage, win32Error, "notification",
                        gotExitCode ? ERROR_PROCESS_ABORTED : GetLastError());
                }
            } else {
                RecordFailure(failureStage, win32Error, "notification",
                    waitResult == WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError());
            }
        }
        if (childJob != NULL) {
            if (!CloseHandle(childJob)) {
                RecordFailure(failureStage, win32Error, "notification", GetLastError());
            }
            childJob = NULL;
        }
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
    if (childJob != NULL) {
        if (!CloseHandle(childJob)) {
            RecordFailure(failureStage, win32Error, "notification", GetLastError());
        }
        childJob = NULL;
    }

    notificationValid = QueryNotification(device, request, &notification,
        &notificationBytes, &notificationError, &malformedResponse);
    *bytesReturned = notificationBytes;
    if (!notificationValid) {
        if (malformedResponse) {
            RecordFailure(failureStage, win32Error, "response", notificationError);
        } else {
            RecordFailure(failureStage, win32Error, "notification", notificationError);
        }
    } else {
        *createObserved = notification.create_observed != 0;
        *exitObserved = notification.exit_observed != 0;
        if ((*createObserved && *exitObserved && notification.armed) ||
            notification.reserved[0] != 0 || notification.reserved[1] != 0 ||
            notification.reserved[2] != 0) {
            RecordFailure(failureStage, win32Error, "response", ERROR_SUCCESS);
        } else if (!*createObserved || !*exitObserved) {
            RecordFailure(failureStage, win32Error, "notification", ERROR_TIMEOUT);
        } else if (childStarted && childBound && childResumed && childCompleted &&
                   childCleanupComplete && *childPIDMatched) {
            result = TRUE;
        } else {
            /* A complete callback pair is insufficient when the collector
             * cannot prove the bound child was resumed and reaped. */
            RecordFailure(failureStage, win32Error, "notification", ERROR_INVALID_DATA);
        }
    }

    if (armed) {
        DWORD disarmBytes = 0;
        if (!DeviceIoControl(device, MODULE_A_IOCTL_DISARM_NOTIFICATION, request,
            sizeof(*request), NULL, 0, &disarmBytes, NULL)) {
            RecordFailure(failureStage, win32Error, "notification", GetLastError());
            result = FALSE;
        }
    }
    *cleanupComplete = childCleanupComplete;
    return result;
}

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *nonceWide = NULL;
    const wchar_t *imagePath = NULL;
    char nonce[65];
    HMODULE kernel32;
    HMODULE ntdll;
    MODULE_A_IS_WOW64_PROCESS_2 isWow64;
    MODULE_A_RTL_GET_VERSION getVersion;
    USHORT processMachine = 0;
    USHORT nativeMachine = 0;
    OSVERSIONINFOW version;
    HANDLE device;
    MODULE_A_SELF_REQUEST request;
    MODULE_A_SELF_RESPONSE response;
    BOOL notificationAttempted = FALSE;
    BOOL notificationCreateObserved = FALSE;
    BOOL notificationExitObserved = FALSE;
    BOOL notificationCleanupComplete = FALSE;
    BOOL notificationChildPIDMatched = FALSE;
    DWORD bytes = 0;
    BOOL ioctlSucceeded = FALSE;
    BOOL sameObject = FALSE;
    DWORD win32Error = 0;
    uint64_t observedPID = 0;
    uint64_t boundChildPID = 0;
    uint32_t protocol = 0;
    const char *loadState = "unknown";
    const char *failureStage = "none";
    int index;

    if (argc == 2 && wcscmp(argv[1], L"--probe-child") == 0) return 0;

    for (index = 1; index < argc; ++index) {
        if (wcscmp(argv[index], L"--nonce") == 0 && index + 1 < argc && nonceWide == NULL) {
            nonceWide = argv[++index];
        } else if (wcscmp(argv[index], L"--driver-image") == 0 && index + 1 < argc && imagePath == NULL) {
            imagePath = argv[++index];
        } else {
            fputs("Usage: module-a-probe --nonce <64 lowercase hex> [--driver-image <image>]\n", stderr);
            return 2;
        }
    }
    if (!IsNonce(nonceWide)) {
        fputs("A 64-character lowercase hexadecimal nonce is required.\n", stderr);
        return 2;
    }
    for (index = 0; index < 64; ++index) nonce[index] = (char)nonceWide[index];
    nonce[64] = 0;

    kernel32 = GetModuleHandleW(L"kernel32.dll");
    ntdll = GetModuleHandleW(L"ntdll.dll");
    isWow64 = kernel32 == NULL ? NULL :
        (MODULE_A_IS_WOW64_PROCESS_2)(void *)GetProcAddress(kernel32, "IsWow64Process2");
    if (isWow64 == NULL || !isWow64(GetCurrentProcess(), &processMachine, &nativeMachine)) {
        processMachine = 0;
        nativeMachine = 0;
    } else if (processMachine == IMAGE_FILE_MACHINE_UNKNOWN) {
        processMachine = nativeMachine;
    }
    ZeroMemory(&version, sizeof(version));
    version.dwOSVersionInfoSize = sizeof(version);
    getVersion = ntdll == NULL ? NULL :
        (MODULE_A_RTL_GET_VERSION)(void *)GetProcAddress(ntdll, "RtlGetVersion");
    if (getVersion == NULL || getVersion(&version) != 0) version.dwBuildNumber = 0;

    ZeroMemory(&request, sizeof(request));
    ZeroMemory(&response, sizeof(response));
    request.struct_size = sizeof(request);
    request.protocol_version = MODULE_A_PROTOCOL_VERSION;
    device = CreateFileW(MODULE_A_WIN32_DEVICE_NAME, GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (device == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        failureStage = "open";
        win32Error = error;
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) loadState = "notLoaded";
    } else {
        if (DeviceIoControl(device, MODULE_A_IOCTL_QUERY_SELF, &request, sizeof(request),
            &response, sizeof(response), &bytes, NULL)) {
            if (ValidSelfResponse(&response, bytes)) {
                ioctlSucceeded = TRUE;
                protocol = response.protocol_version;
                loadState = "loaded";
                observedPID = response.requestor_pid;
                sameObject = response.requestor_matches_current_context == 1 &&
                    response.requestor_pid == (uint64_t)GetCurrentProcessId() &&
                    response.dispatch_attached_context_pid == response.requestor_pid;
                notificationAttempted = TRUE;
                (void)RunNotificationProbe(device, &request, &notificationCreateObserved,
                    &notificationExitObserved, &notificationCleanupComplete,
                    &notificationChildPIDMatched, &boundChildPID, &bytes,
                    &failureStage, &win32Error);
            } else {
                failureStage = "response";
                win32Error = 0;
                loadState = "unknown";
            }
        } else {
            failureStage = "ioctl";
            win32Error = GetLastError();
            loadState = "unknown";
        }
        CloseHandle(device);
    }

    printf("{\"schemaVersion\":2,\"nonce\":\"%s\",\"capturedAtUnixSeconds\":%" PRIu64 ","
        "\"guest\":{\"kernelArchitecture\":\"%s\",\"processArchitecture\":\"%s\",\"windowsBuild\":%lu,"
        "\"secureBoot\":\"unknown\",\"codeIntegrity\":\"unknown\",\"testSigning\":\"unknown\","
        "\"kernelDebugger\":\"unknown\",\"memoryIntegrity\":\"unknown\"},"
        "\"driver\":{\"candidateImageArchitecture\":\"%s\",\"loadedProbeArchitecture\":\"%s\","
        "\"candidateImageAuthenticode\":\"%s\",\"loadState\":\"%s\",\"protocolVersion\":%u},"
        "\"observation\":{\"scope\":\"selfProbe\",\"requestorPID\":%lu,\"observedPID\":%" PRIu64 ","
        "\"dispatchAttachedContextPID\":%" PRIu64 ","
        "\"requestorMatchesCurrentContext\":%s,\"sameProcessObject\":%s,\"deviceControlSucceeded\":%s,"
        "\"failureStage\":\"%s\",\"win32Error\":%lu,\"bytesReturned\":%lu,"
        "\"notification\":{\"attempted\":%s,\"createObserved\":%s,\"exitObserved\":%s,\"childCleanupComplete\":%s,\"childPIDMatched\":%s,\"boundChildPID\":%" PRIu64 "}}}\n",
        nonce, UnixSeconds(), MachineName(nativeMachine), MachineName(processMachine), version.dwBuildNumber,
        MachineName(ImageMachine(imagePath)), MachineName((USHORT)(ioctlSucceeded ? response.machine_type : 0)),
        ImageSignature(imagePath), loadState, protocol, GetCurrentProcessId(), observedPID,
        ioctlSucceeded ? response.dispatch_attached_context_pid : 0,
        ioctlSucceeded && response.requestor_matches_current_context ? "true" : "false",
        sameObject ? "true" : "false", ioctlSucceeded ? "true" : "false",
        failureStage, win32Error, bytes, notificationAttempted ? "true" : "false",
        notificationCreateObserved ? "true" : "false",
        notificationExitObserved ? "true" : "false",
        notificationCleanupComplete ? "true" : "false",
        notificationChildPIDMatched ? "true" : "false", boundChildPID);
    return 0;
}
