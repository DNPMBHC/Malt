// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC
// Minimal UEFI ABI declarations checked against the stable public EDK II headers.
#pragma once
#include <stdint.h>
#include <stddef.h>
typedef uint64_t DemoStatus;
typedef struct { uint32_t a; uint16_t b, c; uint8_t d[8]; } DemoGuid;
typedef struct { uint64_t signature; uint32_t revision, size, crc, reserved; } DemoTableHeader;
typedef struct { DemoTableHeader header; void *functions[44]; } DemoBootServices;
typedef struct {
    DemoTableHeader header;
    void *vendor;
    uint32_t revision;
    void *input_handle, *input, *output_handle, *output, *error_handle, *error;
    void *runtime;
    DemoBootServices *boot;
    uint64_t table_count;
    void *tables;
} DemoSystemTable;
typedef struct { void *functions[18]; uint64_t rom_bytes; void *rom; } DemoPCI;
typedef struct { uint64_t revision; void *functions[14]; } DemoFile;
typedef struct { uint64_t revision; void *open_volume; } DemoFileSystem;
typedef struct {
    uint32_t revision;
    void *parent, *system, *device, *path, *reserved;
    uint32_t options_size;
    void *options, *image;
    uint64_t image_size;
    uint32_t code_type, data_type;
    void *unload;
} DemoLoadedImage;
typedef DemoStatus (*DemoHandleProtocol)(void *, DemoGuid *, void **);
typedef DemoStatus (*DemoLocateHandles)(uint32_t, DemoGuid *, void *, uint64_t *, void ***);
typedef DemoStatus (*DemoAllocatePages)(uint32_t, uint32_t, uint64_t, uint64_t *);
typedef DemoStatus (*DemoFreePool)(void *);
typedef DemoStatus (*DemoStall)(uint64_t);
typedef DemoStatus (*DemoConfigAccess)(DemoPCI *, uint32_t, uint32_t, uint64_t, void *);
typedef DemoStatus (*DemoMemoryAccess)(DemoPCI *, uint32_t, uint8_t, uint64_t, uint64_t, void *);
typedef DemoStatus (*DemoOpenVolume)(DemoFileSystem *, DemoFile **);
typedef DemoStatus (*DemoOpenFile)(DemoFile *, DemoFile **, uint16_t *, uint64_t, uint64_t);
typedef DemoStatus (*DemoWriteFile)(DemoFile *, uint64_t *, void *);
typedef DemoStatus (*DemoCloseFile)(DemoFile *);
_Static_assert(offsetof(DemoSystemTable, boot) == 96, "UEFI system table ABI");
_Static_assert(offsetof(DemoLoadedImage, device) == 24, "UEFI loaded image ABI");
_Static_assert(offsetof(DemoPCI, rom_bytes) == 144, "UEFI PCI I/O ABI");
