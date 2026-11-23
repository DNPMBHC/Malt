/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef MODULE_A_PROTOCOL_H
#define MODULE_A_PROTOCOL_H

#if defined(_KERNEL_MODE)
#include <ntdef.h>
typedef UINT32 uint32_t;
typedef UINT64 uint64_t;
#define PROBE_FIELD_OFFSET(type, field) FIELD_OFFSET(type, field)
#else
#include <stddef.h>
#include <stdint.h>
#define PROBE_FIELD_OFFSET(type, field) offsetof(type, field)
#endif

#define MODULE_A_PROTOCOL_VERSION 2u
#define MODULE_A_DEVICE_TYPE 0x8000u
#define MODULE_A_FUNCTION_QUERY_SELF 0x800u
#define MODULE_A_FUNCTION_ARM_NOTIFICATION 0x801u
#define MODULE_A_FUNCTION_QUERY_NOTIFICATION 0x802u
#define MODULE_A_FUNCTION_DISARM_NOTIFICATION 0x803u
#define MODULE_A_FUNCTION_BIND_NOTIFICATION 0x804u
#define MODULE_A_SCOPE_SELF_ONLY 1u
#define MODULE_A_MACHINE_UNKNOWN 0x0000u
#define MODULE_A_MACHINE_X64 0x8664u
#define MODULE_A_MACHINE_ARM64 0xaa64u

/* Custom device type, METHOD_BUFFERED transfer. */
#define MODULE_A_CTL_CODE(function, access) \
    ((MODULE_A_DEVICE_TYPE << 16) | ((access) << 14) | ((function) << 2))
#define MODULE_A_IOCTL_QUERY_SELF \
    MODULE_A_CTL_CODE(MODULE_A_FUNCTION_QUERY_SELF, 1u)
#define MODULE_A_IOCTL_ARM_NOTIFICATION \
    MODULE_A_CTL_CODE(MODULE_A_FUNCTION_ARM_NOTIFICATION, 2u)
#define MODULE_A_IOCTL_QUERY_NOTIFICATION \
    MODULE_A_CTL_CODE(MODULE_A_FUNCTION_QUERY_NOTIFICATION, 1u)
#define MODULE_A_IOCTL_DISARM_NOTIFICATION \
    MODULE_A_CTL_CODE(MODULE_A_FUNCTION_DISARM_NOTIFICATION, 2u)
#define MODULE_A_IOCTL_BIND_NOTIFICATION \
    MODULE_A_CTL_CODE(MODULE_A_FUNCTION_BIND_NOTIFICATION, 2u)

#define MODULE_A_WIN32_DEVICE_NAME L"\\\\.\\ModuleAProbe"
#define MODULE_A_NT_DEVICE_NAME L"\\Device\\ModuleAProbe"
#define MODULE_A_DOS_DEVICE_NAME L"\\DosDevices\\ModuleAProbe"

/* The caller cannot select a PID, address, process, or target path. */
typedef struct MODULE_A_SELF_REQUEST {
    uint32_t struct_size;
    uint32_t protocol_version;
} MODULE_A_SELF_REQUEST;

typedef struct MODULE_A_SELF_RESPONSE {
    uint32_t struct_size;
    uint32_t protocol_version;
    uint32_t machine_type;
    uint32_t scope;
    uint64_t requestor_pid;
    uint64_t dispatch_attached_context_pid;
    uint32_t requestor_matches_current_context;
    uint32_t reserved;
} MODULE_A_SELF_RESPONSE;

/* Notification state is scoped to the process that arms it and one child. */
typedef struct MODULE_A_NOTIFICATION_RESPONSE {
    uint32_t struct_size;
    uint32_t protocol_version;
    uint32_t armed;
    uint32_t create_observed;
    uint32_t exit_observed;
    uint32_t reserved[3];
} MODULE_A_NOTIFICATION_RESPONSE;

/* Binds the collector's actual suspended child PID to a callback candidate. */
typedef struct MODULE_A_NOTIFICATION_BIND_REQUEST {
    uint32_t struct_size;
    uint32_t protocol_version;
    uint64_t child_pid;
} MODULE_A_NOTIFICATION_BIND_REQUEST;

/* Returned by BIND_NOTIFICATION so the collector can audit the exact PID accepted by the driver. */
typedef struct MODULE_A_NOTIFICATION_BIND_RESPONSE {
    uint32_t struct_size;
    uint32_t protocol_version;
    uint64_t bound_child_pid;
} MODULE_A_NOTIFICATION_BIND_RESPONSE;

#if defined(__cplusplus)
static_assert(sizeof(MODULE_A_SELF_REQUEST) == 8, "request ABI changed");
static_assert(sizeof(MODULE_A_SELF_RESPONSE) == 40, "response ABI changed");
static_assert(PROBE_FIELD_OFFSET(MODULE_A_SELF_RESPONSE, requestor_pid) == 16, "response ABI changed");
static_assert(sizeof(MODULE_A_NOTIFICATION_RESPONSE) == 32, "notification ABI changed");
static_assert(sizeof(MODULE_A_NOTIFICATION_BIND_REQUEST) == 16, "bind ABI changed");
static_assert(PROBE_FIELD_OFFSET(MODULE_A_NOTIFICATION_BIND_REQUEST, child_pid) == 8, "bind ABI changed");
static_assert(sizeof(MODULE_A_NOTIFICATION_BIND_RESPONSE) == 16, "bind response ABI changed");
static_assert(PROBE_FIELD_OFFSET(MODULE_A_NOTIFICATION_BIND_RESPONSE, bound_child_pid) == 8, "bind response ABI changed");
#elif defined(_MSC_VER)
typedef char module_a_request_size_check[(sizeof(MODULE_A_SELF_REQUEST) == 8) ? 1 : -1];
typedef char module_a_response_size_check[(sizeof(MODULE_A_SELF_RESPONSE) == 40) ? 1 : -1];
typedef char module_a_response_pid_offset_check[(PROBE_FIELD_OFFSET(MODULE_A_SELF_RESPONSE, requestor_pid) == 16) ? 1 : -1];
typedef char module_a_notification_size_check[(sizeof(MODULE_A_NOTIFICATION_RESPONSE) == 32) ? 1 : -1];
typedef char module_a_bind_size_check[(sizeof(MODULE_A_NOTIFICATION_BIND_REQUEST) == 16) ? 1 : -1];
typedef char module_a_bind_pid_offset_check[(PROBE_FIELD_OFFSET(MODULE_A_NOTIFICATION_BIND_REQUEST, child_pid) == 8) ? 1 : -1];
typedef char module_a_bind_response_size_check[(sizeof(MODULE_A_NOTIFICATION_BIND_RESPONSE) == 16) ? 1 : -1];
typedef char module_a_bind_response_pid_offset_check[(PROBE_FIELD_OFFSET(MODULE_A_NOTIFICATION_BIND_RESPONSE, bound_child_pid) == 8) ? 1 : -1];
#else
_Static_assert(sizeof(MODULE_A_SELF_REQUEST) == 8, "request ABI changed");
_Static_assert(sizeof(MODULE_A_SELF_RESPONSE) == 40, "response ABI changed");
_Static_assert(PROBE_FIELD_OFFSET(MODULE_A_SELF_RESPONSE, requestor_pid) == 16, "response ABI changed");
_Static_assert(sizeof(MODULE_A_NOTIFICATION_RESPONSE) == 32, "notification ABI changed");
_Static_assert(sizeof(MODULE_A_NOTIFICATION_BIND_REQUEST) == 16, "bind request size");
_Static_assert(PROBE_FIELD_OFFSET(MODULE_A_NOTIFICATION_BIND_REQUEST, child_pid) == 8, "bind request PID offset");
_Static_assert(sizeof(MODULE_A_NOTIFICATION_BIND_RESPONSE) == 16, "bind response size");
_Static_assert(PROBE_FIELD_OFFSET(MODULE_A_NOTIFICATION_BIND_RESPONSE, bound_child_pid) == 8, "bind response PID offset");
#endif

#endif
