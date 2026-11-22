/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <ntifs.h>
#include <wdmsec.h>
#include "../shared/module_a_protocol.h"

DRIVER_INITIALIZE DriverEntry;
DRIVER_UNLOAD ModuleAUnload;
DRIVER_DISPATCH ModuleACreateClose;
DRIVER_DISPATCH ModuleADeviceControl;
DRIVER_DISPATCH ModuleAUnsupported;

enum {
    MODULE_A_LIFECYCLE_IDLE = 0,
    MODULE_A_LIFECYCLE_ARMING = 1,
    MODULE_A_LIFECYCLE_ACTIVE = 2,
    MODULE_A_LIFECYCLE_CLEANUP = 3,
    MODULE_A_LIFECYCLE_OWNER_EXITED = 4
};

enum {
    MODULE_A_PENDING_CHILD_SLOTS = 8
};

static volatile LONG ModuleANotificationLifecycle;
static BOOLEAN ModuleANotificationRegistered;
static volatile LONG ModuleANotificationArmed;
static volatile LONG ModuleACreateObserved;
static volatile LONG ModuleAExitObserved;
static PEPROCESS volatile ModuleANotificationOwnerProcess;
static HANDLE volatile ModuleANotificationOwnerPid;
static HANDLE volatile ModuleANotificationChildPid;
static HANDLE volatile ModuleANotificationCandidatePid[MODULE_A_PENDING_CHILD_SLOTS];
static EX_RUNDOWN_REF ModuleANotificationRundown;
static KSPIN_LOCK ModuleANotificationStateLock;

static PEPROCESS ModuleAClearNotificationState(VOID);

static const GUID ModuleADeviceClass = {
    0x462b7b6a, 0x2d42, 0x49a6, {0xaa, 0x41, 0xcf, 0x24, 0x21, 0xc2, 0x89, 0x7b}
};

static VOID
ModuleAResetCandidatePids(VOID)
{
    ULONG index;
    for (index = 0; index < MODULE_A_PENDING_CHILD_SLOTS; ++index) {
        ModuleANotificationCandidatePid[index] = NULL;
    }
}

static BOOLEAN
ModuleARecordCandidatePid(_In_ HANDLE ProcessId)
{
    ULONG index;
    for (index = 0; index < MODULE_A_PENDING_CHILD_SLOTS; ++index) {
        if (ModuleANotificationCandidatePid[index] == NULL) {
            ModuleANotificationCandidatePid[index] = ProcessId;
            return TRUE;
        }
    }
    return FALSE;
}

static BOOLEAN
ModuleATakeCandidatePid(_In_ HANDLE ProcessId)
{
    ULONG index;
    for (index = 0; index < MODULE_A_PENDING_CHILD_SLOTS; ++index) {
        if (ModuleANotificationCandidatePid[index] == ProcessId) {
            ModuleANotificationCandidatePid[index] = NULL;
            return TRUE;
        }
    }
    return FALSE;
}

static VOID
ModuleAProcessNotify(_In_ PEPROCESS Process, _In_ HANDLE ProcessId,
    _Inout_opt_ PPS_CREATE_NOTIFY_INFO CreateInfo)
{
    LONG lifecycle;
    PEPROCESS ownerProcess;
    PEPROCESS releaseOwner = NULL;
    KIRQL oldIrql;

    if (!ExAcquireRundownProtection(&ModuleANotificationRundown)) {
        return;
    }

    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    lifecycle = InterlockedCompareExchange(&ModuleANotificationLifecycle, 0, 0);
    ownerProcess = (PEPROCESS)InterlockedCompareExchangePointer(
        (PVOID volatile*)&ModuleANotificationOwnerProcess, NULL, NULL);
    if (CreateInfo != NULL) {
        HANDLE ownerPid;
        if ((lifecycle == MODULE_A_LIFECYCLE_ARMING ||
             lifecycle == MODULE_A_LIFECYCLE_ACTIVE) &&
            InterlockedCompareExchange(&ModuleANotificationArmed, 0, 0) != 0) {
            ownerPid = (HANDLE)InterlockedCompareExchangePointer(
                (PVOID volatile*)&ModuleANotificationOwnerPid, NULL, NULL);
            if (ownerPid != NULL && CreateInfo->ParentProcessId == ownerPid) {
                (void)ModuleARecordCandidatePid(ProcessId);
            }
        }
        KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
        ExReleaseRundownProtection(&ModuleANotificationRundown);
        return;
    }

    if (Process == ownerProcess && ownerProcess != NULL) {
        while (lifecycle == MODULE_A_LIFECYCLE_ARMING ||
               lifecycle == MODULE_A_LIFECYCLE_ACTIVE) {
            LONG previous = InterlockedCompareExchange(
                &ModuleANotificationLifecycle, MODULE_A_LIFECYCLE_OWNER_EXITED,
                lifecycle);
            if (previous == lifecycle) {
                InterlockedExchange(&ModuleANotificationArmed, 0);
                releaseOwner = ModuleAClearNotificationState();
                break;
            }
            lifecycle = previous;
        }
    } else {
        (void)ModuleATakeCandidatePid(ProcessId);
        if ((lifecycle == MODULE_A_LIFECYCLE_ARMING ||
             lifecycle == MODULE_A_LIFECYCLE_ACTIVE) &&
               InterlockedCompareExchange(&ModuleANotificationArmed, 0, 0) != 0 &&
               ProcessId == (HANDLE)InterlockedCompareExchangePointer(
                   (PVOID volatile*)&ModuleANotificationChildPid, NULL, NULL) &&
               InterlockedCompareExchange(&ModuleACreateObserved, 0, 0) != 0) {
            InterlockedExchange(&ModuleAExitObserved, 1);
            InterlockedExchange(&ModuleANotificationArmed, 0);
        }
    }
    KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
    if (releaseOwner != NULL) {
        ObDereferenceObject(releaseOwner);
    }
    ExReleaseRundownProtection(&ModuleANotificationRundown);
}

/* Caller holds ModuleANotificationStateLock. */
static PEPROCESS
ModuleAClearNotificationState(VOID)
{
    PEPROCESS ownerProcess = (PEPROCESS)InterlockedExchangePointer(
        (PVOID volatile*)&ModuleANotificationOwnerProcess, NULL);
    InterlockedExchangePointer((PVOID volatile*)&ModuleANotificationOwnerPid, NULL);
    InterlockedExchangePointer((PVOID volatile*)&ModuleANotificationChildPid, NULL);
    ModuleAResetCandidatePids();
    InterlockedExchange(&ModuleANotificationArmed, 0);
    InterlockedExchange(&ModuleACreateObserved, 0);
    InterlockedExchange(&ModuleAExitObserved, 0);
    return ownerProcess;
}

static NTSTATUS
ModuleAReclaimExitedNotification(VOID)
{
    LONG lifecycle;
    PEPROCESS ownerProcess;
    KIRQL oldIrql;

    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    lifecycle = InterlockedCompareExchange(&ModuleANotificationLifecycle,
        MODULE_A_LIFECYCLE_CLEANUP, MODULE_A_LIFECYCLE_OWNER_EXITED);
    KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
    if (lifecycle != MODULE_A_LIFECYCLE_OWNER_EXITED) {
        return STATUS_DEVICE_BUSY;
    }
    ExWaitForRundownProtectionRelease(&ModuleANotificationRundown);
    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    ownerProcess = ModuleAClearNotificationState();
    KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
    if (ownerProcess != NULL) {
        ObDereferenceObject(ownerProcess);
    }
    ExReInitializeRundownProtection(&ModuleANotificationRundown);
    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    InterlockedExchange(&ModuleANotificationLifecycle, MODULE_A_LIFECYCLE_IDLE);
    KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
    return STATUS_SUCCESS;
}

static NTSTATUS
ModuleACleanupNotificationSession(_In_ LONG ExpectedLifecycle)
{
    LONG lifecycle;
    PEPROCESS ownerProcess;
    KIRQL oldIrql;

    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    lifecycle = InterlockedCompareExchange(&ModuleANotificationLifecycle, 0, 0);
    if (lifecycle == ExpectedLifecycle ||
        (ExpectedLifecycle == MODULE_A_LIFECYCLE_ACTIVE &&
         lifecycle == MODULE_A_LIFECYCLE_OWNER_EXITED)) {
        InterlockedExchange(&ModuleANotificationLifecycle, MODULE_A_LIFECYCLE_CLEANUP);
    }
    KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
    if (lifecycle != ExpectedLifecycle &&
        !(ExpectedLifecycle == MODULE_A_LIFECYCLE_ACTIVE &&
          lifecycle == MODULE_A_LIFECYCLE_OWNER_EXITED)) {
        return STATUS_INVALID_DEVICE_STATE;
    }
    ExWaitForRundownProtectionRelease(&ModuleANotificationRundown);
    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    ownerProcess = ModuleAClearNotificationState();
    KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
    if (ownerProcess != NULL) {
        ObDereferenceObject(ownerProcess);
    }
    ExReInitializeRundownProtection(&ModuleANotificationRundown);
    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    InterlockedExchange(&ModuleANotificationLifecycle, MODULE_A_LIFECYCLE_IDLE);
    KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
    return STATUS_SUCCESS;
}

static NTSTATUS
ModuleAReadRequest(_In_ PIRP Irp, _In_ PIO_STACK_LOCATION Stack,
    _Out_ MODULE_A_SELF_REQUEST* Request)
{
    if (Stack->Parameters.DeviceIoControl.InputBufferLength != sizeof(*Request) ||
        Irp->AssociatedIrp.SystemBuffer == NULL) {
        return STATUS_BUFFER_TOO_SMALL;
    }
    RtlCopyMemory(Request, Irp->AssociatedIrp.SystemBuffer, sizeof(*Request));
    if (Request->struct_size != sizeof(*Request) ||
        Request->protocol_version != MODULE_A_PROTOCOL_VERSION) {
        return STATUS_REVISION_MISMATCH;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
ModuleAReadBindRequest(_In_ PIRP Irp, _In_ PIO_STACK_LOCATION Stack,
    _Out_ MODULE_A_NOTIFICATION_BIND_REQUEST* Request)
{
    if (Stack->Parameters.DeviceIoControl.InputBufferLength != sizeof(*Request) ||
        Irp->AssociatedIrp.SystemBuffer == NULL) {
        return STATUS_BUFFER_TOO_SMALL;
    }
    RtlCopyMemory(Request, Irp->AssociatedIrp.SystemBuffer, sizeof(*Request));
    if (Request->struct_size != sizeof(*Request) ||
        Request->protocol_version != MODULE_A_PROTOCOL_VERSION) {
        return STATUS_REVISION_MISMATCH;
    }
    if (Request->child_pid == 0) return STATUS_INVALID_PARAMETER;
    return STATUS_SUCCESS;
}

static HANDLE
ModuleARequestorPid(_In_ PIRP Irp)
{
    PEPROCESS requestor = IoGetRequestorProcess(Irp);
    return requestor != NULL ? PsGetProcessId(requestor) : NULL;
}

static NTSTATUS
ModuleAComplete(_Inout_ PIRP Irp, _In_ NTSTATUS Status, _In_ ULONG_PTR Bytes)
{
    Irp->IoStatus.Status = Status;
    Irp->IoStatus.Information = Bytes;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return Status;
}

NTSTATUS
ModuleAUnsupported(_In_ PDEVICE_OBJECT DeviceObject, _Inout_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    return ModuleAComplete(Irp, STATUS_INVALID_DEVICE_REQUEST, 0);
}

NTSTATUS
ModuleACreateClose(_In_ PDEVICE_OBJECT DeviceObject, _Inout_ PIRP Irp)
{
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    UNREFERENCED_PARAMETER(DeviceObject);
    if (stack->MajorFunction == IRP_MJ_CREATE &&
        stack->FileObject != NULL && stack->FileObject->FileName.Length != 0) {
        return ModuleAComplete(Irp, STATUS_OBJECT_NAME_NOT_FOUND, 0);
    }
    return ModuleAComplete(Irp, STATUS_SUCCESS, 0);
}

NTSTATUS
ModuleADeviceControl(_In_ PDEVICE_OBJECT DeviceObject, _Inout_ PIRP Irp)
{
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    MODULE_A_SELF_REQUEST request;
    MODULE_A_SELF_RESPONSE response;
    MODULE_A_NOTIFICATION_RESPONSE notification;
    MODULE_A_NOTIFICATION_BIND_REQUEST bindRequest;
    MODULE_A_NOTIFICATION_BIND_RESPONSE bindResponse;
    PEPROCESS requestor;
    PEPROCESS currentContext;
    KIRQL oldIrql;
    HANDLE requestorPid;
    ULONG requiredAccess;
    NTSTATUS status;
    UNREFERENCED_PARAMETER(DeviceObject);

    switch (stack->Parameters.DeviceIoControl.IoControlCode) {
    case MODULE_A_IOCTL_QUERY_SELF:
    case MODULE_A_IOCTL_QUERY_NOTIFICATION:
        requiredAccess = FILE_READ_DATA;
        break;
    case MODULE_A_IOCTL_ARM_NOTIFICATION:
    case MODULE_A_IOCTL_DISARM_NOTIFICATION:
    case MODULE_A_IOCTL_BIND_NOTIFICATION:
        requiredAccess = FILE_WRITE_DATA;
        break;
    default:
        return ModuleAComplete(Irp, STATUS_INVALID_DEVICE_REQUEST, 0);
    }
    status = IoValidateDeviceIoControlAccess(Irp, requiredAccess);
    if (!NT_SUCCESS(status)) {
        return ModuleAComplete(Irp, status, 0);
    }
    if (stack->Parameters.DeviceIoControl.IoControlCode == MODULE_A_IOCTL_BIND_NOTIFICATION) {
        if (stack->Parameters.DeviceIoControl.OutputBufferLength < sizeof(bindResponse) ||
            Irp->AssociatedIrp.SystemBuffer == NULL) {
            return ModuleAComplete(Irp, STATUS_BUFFER_TOO_SMALL, 0);
        }
        status = ModuleAReadBindRequest(Irp, stack, &bindRequest);
        if (!NT_SUCCESS(status)) {
            return ModuleAComplete(Irp, status, 0);
        }
        requestorPid = ModuleARequestorPid(Irp);
        requestor = IoGetRequestorProcess(Irp);
        if (requestorPid == NULL || requestor == NULL) {
            return ModuleAComplete(Irp, STATUS_INVALID_PARAMETER, 0);
        }
        if (!ExAcquireRundownProtection(&ModuleANotificationRundown)) {
            return ModuleAComplete(Irp, STATUS_INVALID_DEVICE_STATE, 0);
        }
        KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
        if (InterlockedCompareExchange(&ModuleANotificationLifecycle, 0, 0) !=
            MODULE_A_LIFECYCLE_ACTIVE) {
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ExReleaseRundownProtection(&ModuleANotificationRundown);
            return ModuleAComplete(Irp, STATUS_INVALID_DEVICE_STATE, 0);
        }
        if (requestorPid != (HANDLE)InterlockedCompareExchangePointer(
                (PVOID volatile*)&ModuleANotificationOwnerPid, NULL, NULL) ||
            requestor != (PEPROCESS)InterlockedCompareExchangePointer(
                (PVOID volatile*)&ModuleANotificationOwnerProcess, NULL, NULL)) {
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ExReleaseRundownProtection(&ModuleANotificationRundown);
            return ModuleAComplete(Irp, STATUS_ACCESS_DENIED, 0);
        }
        if (InterlockedCompareExchangePointer(
                (PVOID volatile*)&ModuleANotificationChildPid, NULL, NULL) != NULL) {
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ExReleaseRundownProtection(&ModuleANotificationRundown);
            return ModuleAComplete(Irp, STATUS_DEVICE_BUSY, 0);
        }
        if (!ModuleATakeCandidatePid((HANDLE)(ULONG_PTR)bindRequest.child_pid)) {
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ExReleaseRundownProtection(&ModuleANotificationRundown);
            return ModuleAComplete(Irp, STATUS_INVALID_PARAMETER, 0);
        }
        InterlockedExchangePointer((PVOID volatile*)&ModuleANotificationChildPid,
            (PVOID)(ULONG_PTR)bindRequest.child_pid);
        InterlockedExchange(&ModuleACreateObserved, 1);
        RtlZeroMemory(&bindResponse, sizeof(bindResponse));
        bindResponse.struct_size = sizeof(bindResponse);
        bindResponse.protocol_version = MODULE_A_PROTOCOL_VERSION;
        bindResponse.bound_child_pid = bindRequest.child_pid;
        KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
        RtlCopyMemory(Irp->AssociatedIrp.SystemBuffer, &bindResponse, sizeof(bindResponse));
        ExReleaseRundownProtection(&ModuleANotificationRundown);
        return ModuleAComplete(Irp, STATUS_SUCCESS, sizeof(bindResponse));
    }

    status = ModuleAReadRequest(Irp, stack, &request);
    if (!NT_SUCCESS(status)) {
        return ModuleAComplete(Irp, status, 0);
    }

    if (stack->Parameters.DeviceIoControl.IoControlCode == MODULE_A_IOCTL_ARM_NOTIFICATION) {
        LONG lifecycle;
        PEPROCESS ownerProcess;
        requestorPid = ModuleARequestorPid(Irp);
        if (requestorPid == NULL) {
            return ModuleAComplete(Irp, STATUS_INVALID_PARAMETER, 0);
        }
        if (stack->Parameters.DeviceIoControl.OutputBufferLength != 0) {
            return ModuleAComplete(Irp, STATUS_INVALID_PARAMETER, 0);
        }
        ownerProcess = IoGetRequestorProcess(Irp);
        if (ownerProcess == NULL) {
            return ModuleAComplete(Irp, STATUS_INVALID_PARAMETER, 0);
        }
        if (InterlockedCompareExchange(&ModuleANotificationLifecycle, 0, 0) ==
            MODULE_A_LIFECYCLE_OWNER_EXITED) {
            status = ModuleAReclaimExitedNotification();
            if (!NT_SUCCESS(status)) {
                return ModuleAComplete(Irp, status, 0);
            }
        }
        /* Keep one reference for the published session and one for ARM's
         * local exit-status check and state transition. */
        ObReferenceObject(ownerProcess);
        ObReferenceObject(ownerProcess);
        KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
        lifecycle = InterlockedCompareExchange(&ModuleANotificationLifecycle,
            MODULE_A_LIFECYCLE_ARMING, MODULE_A_LIFECYCLE_IDLE);
        if (lifecycle != MODULE_A_LIFECYCLE_IDLE) {
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ObDereferenceObject(ownerProcess);
            ObDereferenceObject(ownerProcess);
            return ModuleAComplete(Irp, STATUS_DEVICE_BUSY, 0);
        }
        InterlockedExchangePointer((PVOID volatile*)&ModuleANotificationOwnerProcess,
            ownerProcess);
        InterlockedExchangePointer((PVOID volatile*)&ModuleANotificationOwnerPid,
            (PVOID)(ULONG_PTR)requestorPid);
        InterlockedExchangePointer((PVOID volatile*)&ModuleANotificationChildPid, NULL);
        ModuleAResetCandidatePids();
        InterlockedExchange(&ModuleACreateObserved, 0);
        InterlockedExchange(&ModuleAExitObserved, 0);
        InterlockedExchange(&ModuleANotificationArmed, 1);
        KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);

        /*
         * The owner can exit after ARM has taken its reference but before the
         * session becomes ACTIVE.  The process callback may have already
         * observed that exit while the state was IDLE, so check the referenced
         * process explicitly before publishing ACTIVE.
         */
        if (PsGetProcessExitStatus(ownerProcess) != STATUS_PENDING) {
            KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
            lifecycle = InterlockedCompareExchange(&ModuleANotificationLifecycle,
                MODULE_A_LIFECYCLE_OWNER_EXITED, MODULE_A_LIFECYCLE_ARMING);
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ObDereferenceObject(ownerProcess);
            if (lifecycle == MODULE_A_LIFECYCLE_ARMING ||
                lifecycle == MODULE_A_LIFECYCLE_OWNER_EXITED) {
                status = ModuleAReclaimExitedNotification();
                if (!NT_SUCCESS(status)) {
                    return ModuleAComplete(Irp, status, 0);
                }
            }
            return ModuleAComplete(Irp, STATUS_PROCESS_IS_TERMINATING, 0);
        }

        KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
        lifecycle = InterlockedCompareExchange(&ModuleANotificationLifecycle,
            MODULE_A_LIFECYCLE_ACTIVE, MODULE_A_LIFECYCLE_ARMING);
        KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
        if (lifecycle != MODULE_A_LIFECYCLE_ARMING) {
            /* The callback may have reclaimed the session while ARM was publishing it.
             * Drop the local reference acquired before taking the state lock. */
            ObDereferenceObject(ownerProcess);
            if (lifecycle == MODULE_A_LIFECYCLE_OWNER_EXITED) {
                status = ModuleAReclaimExitedNotification();
                if (!NT_SUCCESS(status)) {
                    return ModuleAComplete(Irp, status, 0);
                }
            }
            return ModuleAComplete(Irp, STATUS_PROCESS_IS_TERMINATING, 0);
        }
        ObDereferenceObject(ownerProcess);
        return ModuleAComplete(Irp, STATUS_SUCCESS, 0);
    }

    if (stack->Parameters.DeviceIoControl.IoControlCode == MODULE_A_IOCTL_QUERY_NOTIFICATION) {
        if (stack->Parameters.DeviceIoControl.OutputBufferLength < sizeof(notification) ||
            Irp->AssociatedIrp.SystemBuffer == NULL) {
            return ModuleAComplete(Irp, STATUS_BUFFER_TOO_SMALL, 0);
        }
        if (!ExAcquireRundownProtection(&ModuleANotificationRundown)) {
            return ModuleAComplete(Irp, STATUS_INVALID_DEVICE_STATE, 0);
        }
        KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
        if (InterlockedCompareExchange(&ModuleANotificationLifecycle, 0, 0) !=
            MODULE_A_LIFECYCLE_ACTIVE) {
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ExReleaseRundownProtection(&ModuleANotificationRundown);
            return ModuleAComplete(Irp, STATUS_INVALID_DEVICE_STATE, 0);
        }
        requestorPid = ModuleARequestorPid(Irp);
        requestor = IoGetRequestorProcess(Irp);
        if (requestorPid == NULL || requestor == NULL ||
            requestorPid != (HANDLE)InterlockedCompareExchangePointer(
                (PVOID volatile*)&ModuleANotificationOwnerPid, NULL, NULL) ||
            requestor != (PEPROCESS)InterlockedCompareExchangePointer(
                (PVOID volatile*)&ModuleANotificationOwnerProcess, NULL, NULL)) {
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ExReleaseRundownProtection(&ModuleANotificationRundown);
            return ModuleAComplete(Irp, STATUS_ACCESS_DENIED, 0);
        }
        RtlZeroMemory(&notification, sizeof(notification));
        notification.struct_size = sizeof(notification);
        notification.protocol_version = MODULE_A_PROTOCOL_VERSION;
        notification.armed = InterlockedCompareExchange(&ModuleANotificationArmed, 0, 0) != 0;
        notification.create_observed = InterlockedCompareExchange(
            &ModuleACreateObserved, 0, 0) != 0;
        notification.exit_observed = InterlockedCompareExchange(
            &ModuleAExitObserved, 0, 0) != 0;
        RtlCopyMemory(Irp->AssociatedIrp.SystemBuffer, &notification, sizeof(notification));
        KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
        ExReleaseRundownProtection(&ModuleANotificationRundown);
        return ModuleAComplete(Irp, STATUS_SUCCESS, sizeof(notification));
    }

    if (stack->Parameters.DeviceIoControl.IoControlCode == MODULE_A_IOCTL_DISARM_NOTIFICATION) {
        if (stack->Parameters.DeviceIoControl.OutputBufferLength != 0) {
            return ModuleAComplete(Irp, STATUS_INVALID_PARAMETER, 0);
        }
        if (!ExAcquireRundownProtection(&ModuleANotificationRundown)) {
            return ModuleAComplete(Irp, STATUS_INVALID_DEVICE_STATE, 0);
        }
        requestorPid = ModuleARequestorPid(Irp);
        requestor = IoGetRequestorProcess(Irp);
        KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
        if (requestorPid == NULL || requestor == NULL ||
            requestorPid != (HANDLE)InterlockedCompareExchangePointer(
                (PVOID volatile*)&ModuleANotificationOwnerPid, NULL, NULL) ||
            requestor != (PEPROCESS)InterlockedCompareExchangePointer(
                (PVOID volatile*)&ModuleANotificationOwnerProcess, NULL, NULL) ||
            InterlockedCompareExchange(&ModuleANotificationLifecycle, 0, 0) !=
                MODULE_A_LIFECYCLE_ACTIVE) {
            KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
            ExReleaseRundownProtection(&ModuleANotificationRundown);
            return ModuleAComplete(Irp, requestorPid == NULL || requestor == NULL
                ? STATUS_INVALID_PARAMETER : STATUS_ACCESS_DENIED, 0);
        }
        KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
        ExReleaseRundownProtection(&ModuleANotificationRundown);
        status = ModuleACleanupNotificationSession(MODULE_A_LIFECYCLE_ACTIVE);
        if (!NT_SUCCESS(status)) {
            return ModuleAComplete(Irp, status, 0);
        }
        return ModuleAComplete(Irp, STATUS_SUCCESS, 0);
    }

    if (stack->Parameters.DeviceIoControl.OutputBufferLength < sizeof(response) ||
        Irp->AssociatedIrp.SystemBuffer == NULL) {
        return ModuleAComplete(Irp, STATUS_BUFFER_TOO_SMALL, 0);
    }
    requestor = IoGetRequestorProcess(Irp);
    if (requestor == NULL) {
        return ModuleAComplete(Irp, STATUS_INVALID_PARAMETER, 0);
    }

    RtlZeroMemory(&response, sizeof(response));
    currentContext = PsGetCurrentProcess();
    response.struct_size = sizeof(response);
    response.protocol_version = MODULE_A_PROTOCOL_VERSION;
#if defined(_M_ARM64)
    response.machine_type = MODULE_A_MACHINE_ARM64;
#elif defined(_M_AMD64)
    response.machine_type = MODULE_A_MACHINE_X64;
#else
    response.machine_type = MODULE_A_MACHINE_UNKNOWN;
#endif
    response.scope = MODULE_A_SCOPE_SELF_ONLY;
    response.requestor_pid = (uint64_t)(ULONG_PTR)PsGetProcessId(requestor);
    response.dispatch_attached_context_pid = (uint64_t)(ULONG_PTR)PsGetProcessId(currentContext);
    response.requestor_matches_current_context = (requestor == currentContext) ? 1u : 0u;
    RtlCopyMemory(Irp->AssociatedIrp.SystemBuffer, &response, sizeof(response));
    return ModuleAComplete(Irp, STATUS_SUCCESS, sizeof(response));
}

VOID
ModuleAUnload(_In_ PDRIVER_OBJECT DriverObject)
{
    UNICODE_STRING link;
    KIRQL oldIrql;
    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    InterlockedExchange(&ModuleANotificationLifecycle, MODULE_A_LIFECYCLE_CLEANUP);
    KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
    if (ModuleANotificationRegistered) {
        NTSTATUS status = PsSetCreateProcessNotifyRoutineEx(ModuleAProcessNotify, TRUE);
        if (!NT_SUCCESS(status)) {
            DbgPrintEx(DPFLTR_IHVDRIVER_ID, DPFLTR_ERROR_LEVEL,
                "ModuleAProbe: callback removal failed during unload: 0x%08X\n", status);
            KeBugCheckEx(DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS,
                (ULONG_PTR)ModuleAProcessNotify, 0,
                (ULONG_PTR)ModuleAUnload, 0);
        }
    }
    ExWaitForRundownProtectionRelease(&ModuleANotificationRundown);
    ModuleANotificationRegistered = FALSE;
    KeAcquireSpinLock(&ModuleANotificationStateLock, &oldIrql);
    {
        PEPROCESS ownerProcess = ModuleAClearNotificationState();
        KeReleaseSpinLock(&ModuleANotificationStateLock, oldIrql);
        if (ownerProcess != NULL) {
            ObDereferenceObject(ownerProcess);
        }
    }
    RtlInitUnicodeString(&link, MODULE_A_DOS_DEVICE_NAME);
    IoDeleteSymbolicLink(&link);
    if (DriverObject->DeviceObject != NULL) {
        IoDeleteDevice(DriverObject->DeviceObject);
    }
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    UNICODE_STRING name;
    UNICODE_STRING link;
    UNICODE_STRING security;
    PDEVICE_OBJECT device = NULL;
    NTSTATUS status;
    ULONG index;
    UNREFERENCED_PARAMETER(RegistryPath);

    ExInitializeRundownProtection(&ModuleANotificationRundown);
    KeInitializeSpinLock(&ModuleANotificationStateLock);

    for (index = 0; index <= IRP_MJ_MAXIMUM_FUNCTION; ++index) {
        DriverObject->MajorFunction[index] = ModuleAUnsupported;
    }
    DriverObject->MajorFunction[IRP_MJ_CREATE] = ModuleACreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = ModuleACreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLEANUP] = ModuleACreateClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = ModuleADeviceControl;
    DriverObject->DriverUnload = ModuleAUnload;

    RtlInitUnicodeString(&name, MODULE_A_NT_DEVICE_NAME);
    RtlInitUnicodeString(&link, MODULE_A_DOS_DEVICE_NAME);
    RtlInitUnicodeString(&security, L"D:P(A;;GA;;;SY)(A;;GA;;;BA)");
    status = IoCreateDeviceSecure(DriverObject, 0, &name, MODULE_A_DEVICE_TYPE,
        FILE_DEVICE_SECURE_OPEN, FALSE, &security, &ModuleADeviceClass, &device);
    if (!NT_SUCCESS(status)) {
        return status;
    }
    device->Flags |= DO_BUFFERED_IO;
    status = IoCreateSymbolicLink(&link, &name);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(device);
        return status;
    }
    status = PsSetCreateProcessNotifyRoutineEx(ModuleAProcessNotify, FALSE);
    if (!NT_SUCCESS(status)) {
        IoDeleteSymbolicLink(&link);
        IoDeleteDevice(device);
        return status;
    }
    ModuleANotificationRegistered = TRUE;
    device->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}
