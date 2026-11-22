/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

#include "../shared/module_a_protocol.h"

_Static_assert(sizeof(MODULE_A_SELF_REQUEST) == 8, "request size");
_Static_assert(offsetof(MODULE_A_SELF_REQUEST, struct_size) == 0, "request size offset");
_Static_assert(offsetof(MODULE_A_SELF_REQUEST, protocol_version) == 4, "request version offset");
_Static_assert(sizeof(MODULE_A_SELF_RESPONSE) == 40, "response size");
_Static_assert(offsetof(MODULE_A_SELF_RESPONSE, struct_size) == 0, "response size offset");
_Static_assert(offsetof(MODULE_A_SELF_RESPONSE, protocol_version) == 4, "response version offset");
_Static_assert(offsetof(MODULE_A_SELF_RESPONSE, machine_type) == 8, "response machine offset");
_Static_assert(offsetof(MODULE_A_SELF_RESPONSE, scope) == 12, "response scope offset");
_Static_assert(offsetof(MODULE_A_SELF_RESPONSE, requestor_pid) == 16, "requestor PID offset");
_Static_assert(offsetof(MODULE_A_SELF_RESPONSE, dispatch_attached_context_pid) == 24, "dispatch attached context PID offset");
_Static_assert(offsetof(MODULE_A_SELF_RESPONSE, requestor_matches_current_context) == 32, "process comparison offset");
_Static_assert(offsetof(MODULE_A_SELF_RESPONSE, reserved) == 36, "reserved offset");
_Static_assert(MODULE_A_IOCTL_QUERY_SELF == 0x80006000u, "IOCTL encoding changed");
_Static_assert(MODULE_A_IOCTL_ARM_NOTIFICATION == 0x8000a004u, "arm IOCTL encoding changed");
_Static_assert(MODULE_A_IOCTL_QUERY_NOTIFICATION == 0x80006008u, "query IOCTL encoding changed");
_Static_assert(MODULE_A_IOCTL_DISARM_NOTIFICATION == 0x8000a00cu, "disarm IOCTL encoding changed");
_Static_assert(MODULE_A_IOCTL_BIND_NOTIFICATION == 0x8000a010u, "bind IOCTL encoding changed");
_Static_assert(sizeof(MODULE_A_NOTIFICATION_RESPONSE) == 32, "notification response size");
_Static_assert(offsetof(MODULE_A_NOTIFICATION_RESPONSE, armed) == 8, "notification armed offset");
_Static_assert(offsetof(MODULE_A_NOTIFICATION_RESPONSE, create_observed) == 12, "notification create offset");
_Static_assert(offsetof(MODULE_A_NOTIFICATION_RESPONSE, exit_observed) == 16, "notification exit offset");
_Static_assert(sizeof(MODULE_A_NOTIFICATION_BIND_REQUEST) == 16, "bind request size");
_Static_assert(offsetof(MODULE_A_NOTIFICATION_BIND_REQUEST, child_pid) == 8, "bind request PID offset");
_Static_assert(sizeof(MODULE_A_NOTIFICATION_BIND_RESPONSE) == 16, "bind response size");
_Static_assert(offsetof(MODULE_A_NOTIFICATION_BIND_RESPONSE, bound_child_pid) == 8, "bind response PID offset");

int main(void)
{
    const wchar_t win32_name[] = MODULE_A_WIN32_DEVICE_NAME;
    const wchar_t nt_name[] = MODULE_A_NT_DEVICE_NAME;
    const wchar_t dos_name[] = MODULE_A_DOS_DEVICE_NAME;
    MODULE_A_SELF_REQUEST request = {0};
    MODULE_A_SELF_RESPONSE response = {0};
    MODULE_A_NOTIFICATION_RESPONSE notification = {0};
    MODULE_A_NOTIFICATION_BIND_REQUEST bind = {0};
    MODULE_A_NOTIFICATION_BIND_RESPONSE bindResponse = {0};

    if (MODULE_A_PROTOCOL_VERSION != 2u) {
        fputs("protocol version mismatch\n", stderr);
        return 1;
    }

    if (wcscmp(win32_name, L"\\\\.\\ModuleAProbe") != 0 ||
        wcscmp(nt_name, L"\\Device\\ModuleAProbe") != 0 ||
        wcscmp(dos_name, L"\\DosDevices\\ModuleAProbe") != 0) {
        fputs("device name ABI mismatch\n", stderr);
        return 1;
    }
    if (request.struct_size != 0 || request.protocol_version != 0 ||
        response.struct_size != 0 || response.protocol_version != 0 ||
        response.reserved != 0 || notification.struct_size != 0 ||
        notification.protocol_version != 0 || notification.armed != 0 ||
        notification.create_observed != 0 || notification.exit_observed != 0 ||
        notification.reserved[0] != 0 || notification.reserved[1] != 0 ||
        notification.reserved[2] != 0 || bind.struct_size != 0 ||
        bind.protocol_version != 0 || bind.child_pid != 0 ||
        bindResponse.struct_size != 0 || bindResponse.protocol_version != 0 ||
        bindResponse.bound_child_pid != 0) {
        fputs("zero initialization check failed\n", stderr);
        return 1;
    }
    puts("protocol ABI checks passed");
    return 0;
}
