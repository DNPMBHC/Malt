// Maintainer: @DNPMBHC
// Read-only Vulkan feature query compiled for the Wine process architecture.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "loader_open_failed\n"); return 3; }
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr");
    if (!get) return 4;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)get(VK_NULL_HANDLE, "vkCreateInstance");
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .pApplicationName = "demo-app-feature-gate", .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance = VK_NULL_HANDLE;
    if (!create || create(&info, NULL, &instance) != VK_SUCCESS) return 5;
    PFN_vkEnumeratePhysicalDevices enumerate = (PFN_vkEnumeratePhysicalDevices)get(instance, "vkEnumeratePhysicalDevices");
    PFN_vkGetPhysicalDeviceFeatures features = (PFN_vkGetPhysicalDeviceFeatures)get(instance, "vkGetPhysicalDeviceFeatures");
    PFN_vkGetPhysicalDeviceProperties properties = (PFN_vkGetPhysicalDeviceProperties)get(instance, "vkGetPhysicalDeviceProperties");
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)get(instance, "vkDestroyInstance");
    uint32_t count = 0;
    if (!enumerate || !features || !properties || enumerate(instance, &count, NULL) != VK_SUCCESS || count == 0) return 6;
    VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
    if (!devices || enumerate(instance, &count, devices) != VK_SUCCESS) return 7;
    VkPhysicalDeviceFeatures supported;
    VkPhysicalDeviceProperties props;
    features(devices[0], &supported);
    properties(devices[0], &props);
    printf("{\"geometryShader\":%s,\"fillModeNonSolid\":%s,\"apiVersion\":%u,\"driverVersion\":%u}\n",
           supported.geometryShader ? "true" : "false", supported.fillModeNonSolid ? "true" : "false",
           props.apiVersion, props.driverVersion);
    free(devices);
    destroy(instance, NULL);
    dlclose(library);
    return supported.geometryShader && supported.fillModeNonSolid ? 0 : 8;
}

