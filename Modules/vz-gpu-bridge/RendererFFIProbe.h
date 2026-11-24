// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC
#pragma once
#include <stdint.h>
typedef struct {
    int callbacks_version;
    int renderer_flags;
    int init_attempted;
    int init_result;
    double init_ms;
    uint32_t venus_capset_bytes;
    int context_result;
    int blob_create_result;
    int blob_map_result;
    uint64_t mapped_bytes;
    int mapped_pointer_aliases_input;
    int blob_export_result;
    int scanout_handle_type;
} DemoRendererFFIReport;
DemoRendererFFIReport demo_renderer_ffi_probe(void *library);
