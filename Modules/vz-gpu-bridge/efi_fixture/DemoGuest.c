// SPDX-License-Identifier: GPL-3.0-or-later
// Owner: @DNPMBHC
// Isolated EFI diagnostic only; this is not a Windows/WDDM/Venus producer.
#include "DemoUEFI.h"
static DemoGuid pci_guid = {0x4cf5b200,0x68b8,0x4ca5,{0x9e,0xec,0xb2,0x3e,0x3f,0x50,0x02,0x9a}};
static DemoGuid image_guid = {0x5b1b31a1,0x9562,0x11d2,{0x8e,0x3f,0,0xa0,0xc9,0x69,0x72,0x3b}};
static DemoGuid fs_guid = {0x964e5b22,0x6459,0x11d2,{0x8e,0x39,0,0xa0,0xc9,0x69,0x72,0x3b}};
static DemoBootServices *boot;
static DemoPCI *gpu;
static void *gpu_handle;
static uint8_t common_bar, notify_bar, shared_bar, shared_id;
static uint32_t common_offset, notify_offset, notify_multiplier, shared_offset;
static uint64_t shared_size, shared_offset_high, last_shared_error;
static uint32_t last_shared_magic;
static uint64_t shared_base;
struct Descriptor { uint64_t address; uint32_t length; uint16_t flags, next; };
struct Queue {
    struct Descriptor *descriptors;
    volatile uint16_t *available, *used;
    uint8_t *request, *reply;
    uint16_t size, notify;
};
static struct Queue queues[2];
struct Result {
    uint64_t status;
    uint32_t pci_id, pci_class, reply, features_high;
    uint8_t final_device_status, features_ok_device_status;
    uint16_t queues;
    uint8_t version_one, driver_ok, control_done, cursor_done, shared_written;
};
void *memset(void *pointer, int value, size_t count) {
    uint8_t *p=pointer;
    while(count--) *p++=(uint8_t)value;
    return pointer;
}
void *memcpy(void *destination, const void *source, size_t count) {
    uint8_t *d=destination; const uint8_t *s=source;
    while(count--) *d++=*s++;
    return destination;
}
static DemoStatus config(uint32_t width,uint32_t offset,uint64_t count,void *value,int write) {
    DemoConfigAccess access=(DemoConfigAccess)gpu->functions[write?7:6];
    return access(gpu,width,offset,count,value);
}
static DemoStatus memory(uint32_t width,uint8_t bar,uint64_t offset,uint64_t count,void *value,int write) {
    DemoMemoryAccess access=(DemoMemoryAccess)gpu->functions[write?3:2];
    return access(gpu,width,bar,offset,count,value);
}
static DemoStatus common(uint32_t width,uint32_t offset,void *value,int write) {
    return memory(width,common_bar,common_offset+offset,1,value,write);
}
static DemoStatus discover(struct Result *result,void *agent) {
    void **handles=0;uint64_t count=0;
    DemoLocateHandles locate=(DemoLocateHandles)boot->functions[36];
    DemoHandleProtocol protocol=(DemoHandleProtocol)boot->functions[16];
    DemoStatus status=locate(2,&pci_guid,0,&count,&handles);
    if(status) return status;
    for(uint64_t i=0;i<count;i++) {
        DemoPCI *candidate=0;
        if(protocol(handles[i],&pci_guid,(void **)&candidate)) continue;
        gpu=candidate;uint32_t id=0;
        if(!config(2,0,1,&id,0)&&id==0x10501af4) {result->pci_id=id;gpu_handle=handles[i];break;}
        gpu=0;
    }
    ((DemoFreePool)boot->functions[6])(handles);
    if(!gpu) return 1;
    typedef DemoStatus (*Disconnect)(void *,void *,void *);
    typedef DemoStatus (*OpenProtocol)(void *,DemoGuid *,void **,void *,void *,uint32_t);
    ((Disconnect)boot->functions[31])(gpu_handle,0,0);
    DemoStatus claim=((OpenProtocol)boot->functions[32])(gpu_handle,&pci_guid,(void **)&gpu,agent,gpu_handle,0x30);
    if(claim) return claim;
    config(2,8,1,&result->pci_class,0);
    uint16_t command=0;config(1,4,1,&command,0);command|=6;config(1,4,1,&command,1);
    uint8_t cap=0;config(0,0x34,1,&cap,0);uint8_t found=0;
    for(uint32_t steps=0;cap>=0x40&&steps<64;steps++) {
        uint8_t bytes[24]={0};
        if(config(0,cap,24,bytes,0)) return 2;
        if(bytes[0]==9&&bytes[2]>=16) {
            uint32_t offset=0;memcpy(&offset,bytes+8,4);
            if(bytes[3]==1) {common_bar=bytes[4];common_offset=offset;found|=1;}
            if(bytes[3]==2) {notify_bar=bytes[4];notify_offset=offset;memcpy(&notify_multiplier,bytes+16,4);found|=2;}
            if(bytes[3]==8) {
                shared_bar=bytes[4];shared_id=bytes[5];shared_offset=offset;
                uint32_t offset_high=0;memcpy(&offset_high,bytes+16,4);shared_offset_high=(uint64_t)offset_high<<32;
                uint32_t low=0,high=0;memcpy(&low,bytes+12,4);memcpy(&high,bytes+20,4);
                shared_size=((uint64_t)high<<32)|low;found|=4;
            }
        }
        if(bytes[1]==cap) return 3;
        cap=bytes[1];
    }
    uint32_t bar_low=0,bar_high=0;config(2,0x10+shared_bar*4,1,&bar_low,0);
    if((bar_low&6)==4) config(2,0x14+shared_bar*4,1,&bar_high,0);
    shared_base=((uint64_t)bar_high<<32)|(bar_low&~15U);
    return found==7?0:4;
}
static DemoStatus make_queue(uint16_t index) {
    struct Queue *q=&queues[index];
    if(common(1,22,&index,1)) return 5;
    common(1,24,&q->size,0);if(q->size<2) return 6;
    q->size=2;common(1,24,&q->size,1);common(1,30,&q->notify,0);
    uint64_t address=0;
    DemoStatus status=((DemoAllocatePages)boot->functions[2])(0,4,5,&address);
    if(status) return status;
    memset((void *)(uintptr_t)address,0,5*4096);
    q->descriptors=(void *)(uintptr_t)address;q->available=(void *)(uintptr_t)(address+4096);
    q->used=(void *)(uintptr_t)(address+8192);q->request=(void *)(uintptr_t)(address+12288);
    q->reply=(void *)(uintptr_t)(address+16384);
    uint64_t desc=address,avail=address+4096,used=address+8192;
    common(3,32,&desc,1);common(3,40,&avail,1);common(3,48,&used,1);
    uint16_t vector=0xffff;common(1,26,&vector,1);
    uint16_t enabled=1;return common(1,28,&enabled,1);
}
static int submit(uint16_t index,uint32_t type,uint32_t bytes,int reply) {
    struct Queue *q=&queues[index];memset(q->request,0,bytes);memcpy(q->request,&type,4);
    q->descriptors[0]=(struct Descriptor){(uintptr_t)q->request,bytes,reply?1:0,1};
    if(reply) q->descriptors[1]=(struct Descriptor){(uintptr_t)q->reply,4096,2,0};
    q->available[2]=0;__asm__ volatile("dmb ishst":::"memory");q->available[1]=1;
    __asm__ volatile("dmb ishst":::"memory");
    if(memory(1,notify_bar,notify_offset+(uint64_t)q->notify*notify_multiplier,1,&index,1)) return 0;
    for(uint32_t i=0;i<50000;i++) {
        __asm__ volatile("dmb ishld":::"memory");
        if(q->used[1]==1) return 1;
        ((DemoStall)boot->functions[28])(100);
    }
    return 0;
}
static DemoStatus shared_access(uint32_t width,uint64_t offset,uint64_t count,void *value,int write) {
    if(!shared_base||offset+count*(1ULL<<width)>shared_offset_high+shared_offset+shared_size) return 10;
    __asm__ volatile("dmb osh":::"memory");
    if(width==2) {
        volatile uint32_t *address=(void *)(uintptr_t)(shared_base+offset);uint32_t *words=value;
        for(uint64_t i=0;i<count;i++) {if(write) address[i]=words[i];else words[i]=address[i];}
    } else if(width==3) {
        volatile uint64_t *address=(void *)(uintptr_t)(shared_base+offset);uint64_t *words=value;
        for(uint64_t i=0;i<count;i++) {if(write) address[i]=words[i];else words[i]=address[i];}
    } else return 11;
    __asm__ volatile("dmb osh":::"memory");
    return 0;
}
static DemoStatus shared_draws(void) {
    uint32_t magic=0;uint64_t slot=0;uint32_t count=0;
    for(uint32_t attempt=0;attempt<100000;attempt++) {
        last_shared_error=shared_access(2,shared_offset_high+shared_offset+48,1,&magic,0);
        last_shared_magic=magic;
        if(!last_shared_error&&magic==0x44454d4f) break;
        ((DemoStall)boot->functions[28])(100);
    }
    if(magic!=0x44454d4f) return 7;
    shared_access(3,shared_offset_high+shared_offset+32,1,&slot,0);
    shared_access(2,shared_offset_high+shared_offset+16,1,&count,0);
    if(count!=2048||slot<16384||slot+(uint64_t)count*16>shared_size) return 8;
    for(uint32_t i=0;i<count;i++) {
        struct {uint32_t index,seed;float x,y;} command={i,77,(float)(i%64)/32.0f-0.98f,(float)((i/64)%32)/16.0f-0.97f};
        DemoStatus status=shared_access(2,shared_offset_high+shared_offset+slot+(uint64_t)i*16,4,&command,1);
        if(status) return status;
    }
    __asm__ volatile("dmb ishst":::"memory");
    uint32_t done=0x444f4e45;
    return shared_access(2,shared_offset_high+shared_offset+56,1,&done,1);
}
static char output[2048];static uint64_t length;
static void text(const char *value) {while(*value&&length<sizeof(output)-1) output[length++]=*value++;}
static void number(uint64_t value) {
    char digits[24];uint32_t count=0;
    do {digits[count++]=(char)('0'+value%10);value/=10;} while(value);
    while(count) output[length++]=digits[--count];
}
static void field(const char *name,uint64_t value) {text(",\"");text(name);text("\":");number(value);}
static void save(void *handle,struct Result *result) {
    DemoHandleProtocol protocol=(DemoHandleProtocol)boot->functions[16];
    DemoLoadedImage *image=0;DemoFileSystem *fs=0;DemoFile *root=0,*file=0;
    if(protocol(handle,&image_guid,(void **)&image)||protocol(image->device,&fs_guid,(void **)&fs)) return;
    if(((DemoOpenVolume)fs->open_volume)(fs,&root)) return;
    uint16_t *path=(uint16_t *)L"\\RESULT.JSON";
    if(!((DemoOpenFile)root->functions[0])(root,&file,path,0x8000000000000003ULL,0)) {
        text("{\"owner\":\"@DNPMBHC\",\"origin\":\"isolated_uefi_diagnostic_not_windows\"");
        field("status",result->status);field("vendorID",result->pci_id&0xffff);
        field("deviceID",result->pci_id>>16);field("pciClass",result->pci_class>>24);
        field("pciSubclass",(result->pci_class>>16)&255);field("queueCount",result->queues);
        field("featuresHigh",result->features_high);field("finalDeviceStatus",result->final_device_status);
        field("featuresOkDeviceStatus",result->features_ok_device_status);
        field("versionOneNegotiated",result->version_one);field("driverOk",result->driver_ok);
        field("controlCompleted",result->control_done);field("cursorCompleted",result->cursor_done);
        field("controlReplyType",result->reply);field("sharedMemoryRegionID",shared_id);
        field("sharedMemoryBytes",shared_size);field("sharedBAR",shared_bar);
        field("sharedBARAssigned",shared_base!=0);
        field("sharedOffset",shared_offset_high+shared_offset);field("lastSharedReadStatus",last_shared_error);
        field("lastSharedMagic",last_shared_magic);field("guestDrawCommandsWritten",result->shared_written?2048:0);
        text("}\n");uint64_t size=length;
        ((DemoWriteFile)file->functions[4])(file,&size,output);
        ((DemoCloseFile)file->functions[9])(file);
        ((DemoCloseFile)file->functions[1])(file);
    }
    ((DemoCloseFile)root->functions[1])(root);
}
DemoStatus efi_main(void *handle,DemoSystemTable *system) {
    boot=system->boot;struct Result result={0};
    result.status=discover(&result,handle);
    if(!result.status) {
        uint8_t status=0;common(0,20,&status,1);
        ((DemoStall)boot->functions[28])(10000);
        status=3;common(0,20,&status,1);
        uint32_t selector=1,feature=0;common(2,0,&selector,1);
        ((DemoStall)boot->functions[28])(1000);
        common(2,4,&feature,0);result.features_high=feature;
        result.version_one=(feature&1)!=0;common(2,8,&selector,1);feature=1;common(2,12,&feature,1);
        selector=0;common(2,8,&selector,1);feature=0;common(2,12,&feature,1);
        status=11;common(0,20,&status,1);
        ((DemoStall)boot->functions[28])(10000);
        common(0,20,&status,0);result.features_ok_device_status=status;
        common(1,18,&result.queues,0);
        if(!result.version_one||!(status&8)) result.status=9;
        if(!result.status) result.status=make_queue(0);
        if(!result.status) result.status=make_queue(1);
        if(!result.status) {
            status=15;common(0,20,&status,1);common(0,20,&status,0);result.driver_ok=status==15;
            result.final_device_status=status;
            result.control_done=submit(0,0x0100,24,1);memcpy(&result.reply,queues[0].reply,4);
            result.cursor_done=submit(1,0x0300,56,0);
            result.status=shared_draws();result.shared_written=result.status==0;
        }
    }
    save(handle,&result);
    for(;;) ((DemoStall)boot->functions[28])(100000);
}
