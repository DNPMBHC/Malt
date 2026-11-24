// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC
// ABI: upstream macOS callbacks v4. No render-server flag is enabled.
#include "RendererFFIProbe.h"
#include <dlfcn.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

struct DemoCallbacks {
    int version;
    void (*write_fence)(void *, uint32_t);
    void *(*create_context)(void *, int, void *);
    void (*destroy_context)(void *, void *);
    int (*make_current)(void *, int, void *);
    int (*get_drm_fd)(void *);
    void (*write_context_fence)(void *, uint32_t, uint32_t, uint64_t);
    int (*get_server_fd)(void *, uint32_t);
    void *(*get_egl_display)(void *);
};

struct DemoBlob {
    uint32_t resource, context, memory_type, flags;
    uint64_t blob_id, size;
    const struct iovec *vectors;
    uint32_t vector_count;
};

_Static_assert(sizeof(struct DemoCallbacks) == 72, "callbacks v4 ABI size");
_Static_assert(sizeof(struct DemoBlob) == 48, "blob ABI size");

static void demo_fence(void *cookie, uint32_t fence) { (void)cookie; (void)fence; }
static void demo_context_fence(void *cookie, uint32_t context, uint32_t ring, uint64_t fence) {
    (void)cookie; (void)context; (void)ring; (void)fence;
}

static double demo_time_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}

static void demo_blob_probe(void *library, DemoRendererFFIReport *report) {
    int (*create)(const struct DemoBlob *) = dlsym(library, "virgl_renderer_resource_create_blob");
    int (*map)(uint32_t, void **, uint64_t *) = dlsym(library, "virgl_renderer_resource_map");
    int (*unmap)(uint32_t) = dlsym(library, "virgl_renderer_resource_unmap");
    void (*release)(uint32_t) = dlsym(library, "virgl_renderer_resource_unref");
    int (*export_blob)(uint32_t, uint32_t *, int *) = dlsym(library, "virgl_renderer_resource_export_blob");
    if (!create || !map || !unmap || !release) return;
    size_t bytes = (size_t)sysconf(_SC_PAGESIZE);
    void *memory = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory == MAP_FAILED) return;
    memset(memory, 0x3c, bytes);
    struct iovec vector = { memory, bytes };
    struct DemoBlob blob = { 99, 0, 1, 1, 0, bytes, &vector, 1 };
    report->blob_create_result = create(&blob);
    if (report->blob_create_result == 0) {
        void *mapped = NULL;
        report->blob_map_result = map(99, &mapped, &report->mapped_bytes);
        report->mapped_pointer_aliases_input = mapped == memory;
        if (report->blob_map_result == 0) unmap(99);
        if (export_blob) {
            uint32_t kind = 0;
            int descriptor = -1;
            report->blob_export_result = export_blob(99, &kind, &descriptor);
            if (report->blob_export_result == 0 && descriptor >= 0) close(descriptor);
        }
        release(99);
    }
    munmap(memory, bytes);
}

DemoRendererFFIReport demo_renderer_ffi_probe(void *library) {
    DemoRendererFFIReport report = {0};
    report.callbacks_version = 4;
    report.renderer_flags = (1 << 6) | (1 << 7);
    report.init_result = report.context_result = report.blob_create_result = -999;
    report.blob_map_result = report.blob_export_result = -999;
    int (*initialize)(void *, int, struct DemoCallbacks *) = dlsym(library, "virgl_renderer_init");
    void (*cleanup)(void *) = dlsym(library, "virgl_renderer_cleanup");
    void (*caps)(uint32_t, uint32_t *, uint32_t *) = dlsym(library, "virgl_renderer_get_cap_set");
    int (*context)(uint32_t, uint32_t, uint32_t, const char *) = dlsym(library, "virgl_renderer_context_create_with_flags");
    void (*destroy)(uint32_t) = dlsym(library, "virgl_renderer_context_destroy");
    if (!initialize || !cleanup || !caps) return report;
    struct DemoCallbacks callbacks = {0};
    callbacks.version = 4;
    callbacks.write_fence = demo_fence;
    callbacks.write_context_fence = demo_context_fence;
    report.init_attempted = 1;
    double start = demo_time_ms();
    report.init_result = initialize(&report, report.renderer_flags, &callbacks);
    report.init_ms = demo_time_ms() - start;
    if (report.init_result != 0) return report;
    uint32_t version = 0;
    caps(4, &version, &report.venus_capset_bytes);
    if (context && destroy && report.venus_capset_bytes) {
        report.context_result = context(1, 4, 0, "");
        if (report.context_result == 0) destroy(1);
    }
    demo_blob_probe(library, &report);
    cleanup(&report);
    return report;
}
