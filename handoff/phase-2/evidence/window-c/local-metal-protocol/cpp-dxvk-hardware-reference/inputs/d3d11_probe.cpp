#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_4.h>
#include <psapi.h>
#ifdef _MSC_VER
#include <wrl/client.h>
using Microsoft::WRL::ComPtr;
#else
#include <utility>
template <typename T>
class ComPtr {
public:
    ComPtr() = default;
    ComPtr(const ComPtr& other) : ptr_(other.ptr_) { if (ptr_) ptr_->AddRef(); }
    ComPtr(ComPtr&& other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
    ~ComPtr() { reset(); }
    ComPtr& operator=(const ComPtr& other) {
        if (this != &other) {
            if (other.ptr_) other.ptr_->AddRef();
            reset();
            ptr_ = other.ptr_;
        }
        return *this;
    }
    ComPtr& operator=(ComPtr&& other) noexcept {
        if (this != &other) {
            reset();
            ptr_ = other.ptr_;
            other.ptr_ = nullptr;
        }
        return *this;
    }
    void reset() {
        if (ptr_) {
            ptr_->Release();
            ptr_ = nullptr;
        }
    }
    T* Get() const { return ptr_; }
    T* operator->() const { return ptr_; }
    explicit operator bool() const { return ptr_ != nullptr; }
    T** ReleaseAndGetAddressOf() {
        reset();
        return &ptr_;
    }
    T** operator&() { return ReleaseAndGetAddressOf(); }
    template <typename U>
    HRESULT As(U** other) const {
        if (!ptr_) return E_POINTER;
        return ptr_->QueryInterface(__uuidof(U), reinterpret_cast<void**>(other));
    }
private:
    T* ptr_ = nullptr;
};
#endif

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <array>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <sstream>
#include <string>
#include <vector>

#ifdef _MSC_VER
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")
#pragma comment(lib, "psapi.lib")
#pragma comment(lib, "ws2_32.lib")
#endif

using Clock = std::chrono::steady_clock;

struct Options {
    unsigned frames = 900;
    unsigned warmup = 120;
    unsigned width = 1280;
    unsigned height = 720;
    unsigned commands = 16;
    unsigned commandEvery = 1;
    unsigned resourceEvery = 1;
    unsigned resourceBytes = 65536;
    std::string offloadMode = "pixel-readback";
    std::string metadataPath;
    std::string driverType = "hardware";
    std::string capturePath;
    unsigned captureFrame = 0;
    bool fingerprintOnly = false;
    std::string resourcePattern = "legacy";
    uint32_t seed = 1;
    std::string completionMode = "submit-only";
    std::string csvPath = "-";
    std::string transportHost;
    unsigned short transportPort = 39003;
};

struct CommandRecord {
    uint32_t opcode;
    uint32_t x;
    uint32_t y;
    uint32_t value;
};

struct FrameQueries {
    ComPtr<ID3D11Query> disjoint;
    ComPtr<ID3D11Query> start;
    ComPtr<ID3D11Query> end;
};

struct FrameResult {
    double cpuFrameMs = 0;
    double cpuSubmitMs = 0;
    double processCpuMs = 0;
    double gpuMs = 0;
    bool hasGpuTiming = false;
    double inputToPresentMs = 0;
    uint64_t residentBytes = 0;
    uint64_t deviceMemoryBytes = 0;
    bool hasDeviceMemory = false;
    uint64_t networkBytesOut = 0;
    uint64_t networkBytesIn = 0;
    double hostReceiveToPresentMs = 0;
    double hostGpuMs = 0;
    uint64_t hostResidentBytes = 0;
    uint64_t hostTextureBytes = 0;
};

static void storeLE(uint8_t* out, uint32_t value) {
    out[0] = static_cast<uint8_t>(value);
    out[1] = static_cast<uint8_t>(value >> 8);
    out[2] = static_cast<uint8_t>(value >> 16);
    out[3] = static_cast<uint8_t>(value >> 24);
}

static uint32_t loadLE(const uint8_t* in) {
    return uint32_t(in[0]) | (uint32_t(in[1]) << 8) | (uint32_t(in[2]) << 16) | (uint32_t(in[3]) << 24);
}

static void makeHeader(uint8_t* out, uint16_t kind, uint32_t sequence, uint32_t width, uint32_t height,
                       uint32_t commandBytes, uint32_t resourceBytes, uint32_t pixelBytes, uint16_t version = 1) {
    out[0] = 'G'; out[1] = 'F'; out[2] = 'X'; out[3] = '1';
    out[4] = static_cast<uint8_t>(version); out[5] = static_cast<uint8_t>(version >> 8);
    out[6] = static_cast<uint8_t>(kind); out[7] = static_cast<uint8_t>(kind >> 8);
    storeLE(out + 8, sequence); storeLE(out + 12, width); storeLE(out + 16, height);
    storeLE(out + 20, commandBytes); storeLE(out + 24, resourceBytes); storeLE(out + 28, pixelBytes);
}

static void sendAll(SOCKET s, const uint8_t* data, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        const int sent = send(s, reinterpret_cast<const char*>(data + offset), static_cast<int>(std::min<size_t>(count - offset, 1u << 20)), 0);
        if (sent == SOCKET_ERROR || sent == 0) throw std::runtime_error("transport send failed");
        offset += static_cast<size_t>(sent);
    }
}

static void recvAll(SOCKET s, uint8_t* data, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        const int got = recv(s, reinterpret_cast<char*>(data + offset), static_cast<int>(std::min<size_t>(count - offset, 1u << 20)), 0);
        if (got == SOCKET_ERROR || got == 0) throw std::runtime_error("transport receive failed");
        offset += static_cast<size_t>(got);
    }
}

static SOCKET connectHost(const Options& o, uint32_t commandBytes, uint32_t pixelBytes) {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) throw std::runtime_error("WSAStartup failed");
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) throw std::runtime_error("socket creation failed");
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(o.transportPort);
    if (InetPtonA(AF_INET, o.transportHost.c_str(), &address.sin_addr) != 1) throw std::runtime_error("transport host must be an IPv4 address");
    if (connect(s, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR) throw std::runtime_error("transport connect failed");
    std::array<uint8_t, 32> hello{};
    makeHeader(hello.data(), 1, o.warmup, o.width, o.height, commandBytes, o.resourceBytes, pixelBytes,
               o.offloadMode == "command-only" ? 2 : 1);
    sendAll(s, hello.data(), hello.size());
    return s;
}

static const char* kShader = R"(
ByteAddressBuffer InputData : register(t0);
cbuffer Params : register(b0) {
    uint PayloadOffset;
    uint PayloadBytes;
    uint ImageWidth;
    uint Pad;
};
struct VSOut { float4 position : SV_POSITION; };
VSOut VSMain(uint id : SV_VertexID) {
    float2 p = id == 0 ? float2(-1.0, -1.0) : (id == 1 ? float2(-1.0, 3.0) : float2(3.0, -1.0));
    VSOut o; o.position = float4(p, 0.0, 1.0); return o;
}
float4 PSMain(VSOut input) : SV_TARGET {
    uint2 pixel = uint2(input.position.xy);
    uint address = ((pixel.y * ImageWidth + pixel.x) * 4) % PayloadBytes;
    uint value = 0;
    [unroll] for (uint i = 0; i < 8; ++i) {
        value ^= InputData.Load(PayloadOffset + ((address + i * 4) % PayloadBytes));
    }
    float shade = (float)(value & 255) / 255.0;
    return float4(shade, 0.25 + shade * 0.5, 1.0 - shade * 0.35, 1.0);
}
)";

static Options parseOptions(int argc, char** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        const std::string key = argv[i];
        auto next = [&]() -> std::string {
            if (++i >= argc) throw std::runtime_error("missing value for " + key);
            return argv[i];
        };
        if (key == "--frames") o.frames = std::stoul(next());
        else if (key == "--warmup") o.warmup = std::stoul(next());
        else if (key == "--width") o.width = std::stoul(next());
        else if (key == "--height") o.height = std::stoul(next());
        else if (key == "--commands") o.commands = std::stoul(next());
        else if (key == "--command-every") o.commandEvery = std::stoul(next());
        else if (key == "--resource-every") o.resourceEvery = std::stoul(next());
        else if (key == "--resource-bytes") o.resourceBytes = std::stoul(next());
        else if (key == "--csv") o.csvPath = next();
        else if (key == "--offload-mode") o.offloadMode = next();
        else if (key == "--metadata-json") o.metadataPath = next();
        else if (key == "--fingerprint-only") o.fingerprintOnly = true;
        else if (key == "--driver-type") o.driverType = next();
        else if (key == "--capture-rgba") o.capturePath = next();
        else if (key == "--capture-frame") o.captureFrame = std::stoul(next());
        else if (key == "--resource-pattern") o.resourcePattern = next();
        else if (key == "--seed") o.seed = std::stoul(next());
        else if (key == "--completion-mode") o.completionMode = next();
        else if (key == "--transport-host") o.transportHost = next();
        else if (key == "--port") {
            const auto port = std::stoul(next());
            if (port == 0 || port > 65535) throw std::runtime_error("port must be in 1...65535");
            o.transportPort = static_cast<unsigned short>(port);
        }
        else if (key == "--help") {
            std::cout << "d3d11_probe --frames N --warmup N --width N --height N --commands N --command-every N --resource-bytes N --resource-every N --transport-host IPv4 --port N --csv PATH --offload-mode pixel-readback|command-only --metadata-json PATH --fingerprint-only --driver-type hardware|warp --capture-rgba PATH --capture-frame N --resource-pattern legacy|seeded --seed N\n";
            std::exit(0);
        } else throw std::runtime_error("unknown argument: " + key);
    }
    if (!o.frames || o.frames > 10000 || o.warmup > 1000000 || o.width < 64 || o.height < 64 ||
        o.width > 4096 || o.height > 4096 || !o.commands || o.commands > 4096 ||
        o.resourceBytes < 4 || o.resourceBytes > 32 * 1024 * 1024) {
        throw std::runtime_error("invalid workload dimensions or size");
    }
    if (!o.commandEvery) throw std::runtime_error("command resend interval must be positive");
    if (!o.resourceEvery) throw std::runtime_error("resource resend interval must be positive");
    if (!o.transportHost.empty() && static_cast<uint64_t>(o.width) * o.height * 4 +
        static_cast<uint64_t>(o.commands) * sizeof(CommandRecord) + o.resourceBytes > 64ull * 1024 * 1024) {
        throw std::runtime_error("offload payload exceeds the host protocol limit");
    }
    if (o.completionMode != "submit-only" && o.completionMode != "gpu-complete") throw std::runtime_error("invalid completion mode");
    if (o.offloadMode != "pixel-readback" && o.offloadMode != "command-only") throw std::runtime_error("invalid offload mode");
    if (o.driverType != "hardware" && o.driverType != "warp") throw std::runtime_error("invalid driver type");
    if (o.resourcePattern != "legacy" && o.resourcePattern != "seeded") throw std::runtime_error("invalid resource pattern");
    if (o.offloadMode == "command-only" && !o.fingerprintOnly && (o.commands != 16 || o.resourceBytes != 65536))
        throw std::runtime_error("command-only prototype requires 16 draws and 65536 resource bytes");
    if (o.offloadMode == "command-only" && o.transportHost.empty() && !o.fingerprintOnly)
        throw std::runtime_error("command-only requires a transport host");
    if (!o.capturePath.empty() && (o.offloadMode == "command-only" || o.captureFrame >= o.warmup + o.frames))
        throw std::runtime_error("capture requires a rendered frame within the run");
    static_assert(sizeof(CommandRecord) == 16, "protocol command record must be exactly 16 bytes");
    o.resourceBytes = (o.resourceBytes + 3u) & ~3u;
    return o;
}

static LRESULT CALLBACK windowProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_CLOSE) { DestroyWindow(h); return 0; }
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(h, m, w, l);
}

static HWND makeWindow(const Options& o) {
    const wchar_t* className = L"GraphicsLabD3D11Window";
    WNDCLASSW wc{};
    wc.lpfnWndProc = windowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = className;
    RegisterClassW(&wc);
    RECT r{0, 0, static_cast<LONG>(o.width), static_cast<LONG>(o.height)};
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND h = CreateWindowW(className, L"D3D11 graphics benchmark", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top,
        nullptr, nullptr, wc.hInstance, nullptr);
    if (!h) throw std::runtime_error("CreateWindowW failed");
    ShowWindow(h, SW_SHOW);
    UpdateWindow(h);
    return h;
}

static void check(HRESULT hr, const char* what) {
    if (FAILED(hr)) throw std::runtime_error(std::string(what) + " failed, HRESULT=" + std::to_string(static_cast<unsigned long>(hr)));
}

static void compileShader(const char* entry, const char* target, ComPtr<ID3DBlob>& blob) {
    ComPtr<ID3DBlob> errors;
    const HRESULT hr = D3DCompile(kShader, strlen(kShader), nullptr, nullptr, nullptr, entry, target,
        D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &blob, &errors);
    if (FAILED(hr)) {
        std::string message = errors ? std::string(static_cast<const char*>(errors->GetBufferPointer()), errors->GetBufferSize()) : "shader compilation failed";
        throw std::runtime_error(message);
    }
}

static uint64_t processCpu100ns() {
    FILETIME created{}, exited{}, kernel{}, user{};
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return 0;
    ULARGE_INTEGER k{}, u{};
    k.LowPart = kernel.dwLowDateTime; k.HighPart = kernel.dwHighDateTime;
    u.LowPart = user.dwLowDateTime; u.HighPart = user.dwHighDateTime;
    return k.QuadPart + u.QuadPart;
}

static uint64_t workingSetBytes() {
    PROCESS_MEMORY_COUNTERS_EX m{};
    m.cb = sizeof(m);
    return GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&m), sizeof(m)) ? m.WorkingSetSize : 0;
}

static bool queryDeviceMemory(IDXGIAdapter3* adapter, uint64_t& bytes) {
    if (!adapter) return false;
    DXGI_QUERY_VIDEO_MEMORY_INFO info{};
    if (FAILED(adapter->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info))) return false;
    bytes = info.CurrentUsage;
    return true;
}

static void writeHeader(std::ostream& out) {
    out << "transport_mode,frame_index,initialization_ms,warmup_ms,cpu_frame_ms,cpu_submit_ms,process_cpu_ms,gpu_ms,synthetic_input_to_present_return_ms,transferred_bytes,command_bytes,resource_bytes,resident_bytes,device_memory_bytes,power_w,temperature_c,network_bytes_out,network_bytes_in,host_receive_to_present_ms,host_gpu_ms,host_resident_bytes,host_texture_bytes\n";
}


static std::string jsonString(const std::string& value) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : value) {
        switch (c) {
        case '"': out << "\\\""; break;
        case '\\': out << "\\\\"; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default:
            if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << unsigned(c) << std::dec;
            else out << c;
        }
    }
    out << '"';
    return out.str();
}

static std::string utf8(const wchar_t* value) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) return "";
    std::string result(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value, -1, &result[0], size, nullptr, nullptr);
    result.pop_back();
    return result;
}

static std::string hex32(uint32_t value) {
    std::ostringstream out;
    out << "\"0x" << std::hex << std::setw(8) << std::setfill('0') << value << '"';
    return out.str();
}

static std::string adapterJson(const DXGI_ADAPTER_DESC1& d) {
    std::ostringstream out;
    out << "{\"adapter_description\":" << jsonString(utf8(d.Description))
        << ",\"vendor_id\":" << d.VendorId << ",\"device_id\":" << d.DeviceId
        << ",\"adapter_flags\":" << d.Flags
        << ",\"adapter_is_software\":" << ((d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ? "true" : "false") << '}';
    return out.str();
}

static void writeMetadata(const Options& o, ID3D11Device* device, D3D_FEATURE_LEVEL selected,
                          HRESULT createResult, const std::vector<HRESULT>& attempts) {
    DWORD session = 0;
    const BOOL sessionOK = ProcessIdToSessionId(GetCurrentProcessId(), &session);
    const DWORD sessionError = sessionOK ? 0 : GetLastError();
    ComPtr<IDXGIDevice> dxgiDevice;
    ComPtr<IDXGIAdapter> base;
    ComPtr<IDXGIAdapter1> adapter;
    DXGI_ADAPTER_DESC1 desc{};
    HRESULT descResult = E_POINTER;
    if (device) {
        descResult = device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void**>(dxgiDevice.ReleaseAndGetAddressOf()));
        if (SUCCEEDED(descResult)) descResult = dxgiDevice->GetAdapter(&base);
        if (SUCCEEDED(descResult)) descResult = base.As(&adapter);
        if (SUCCEEDED(descResult)) descResult = adapter->GetDesc1(&desc);
    }
    std::ostringstream out;
    out << "{\"schema_version\":1,\"requested_driver_type\":" << jsonString(o.driverType)
        << ",\"device_create_hresult\":" << hex32(static_cast<uint32_t>(createResult))
        << ",\"device_create_attempts\":[";
    for (size_t i = 0; i < attempts.size(); ++i) {
        if (i) out << ',';
        out << hex32(static_cast<uint32_t>(attempts[i]));
    }
    out << "],\"adapter_get_desc1_hresult\":" << hex32(static_cast<uint32_t>(descResult));
    if (SUCCEEDED(descResult)) {
        const std::string fields = adapterJson(desc);
        out << ',' << fields.substr(1, fields.size() - 2);
    } else {
        out << ",\"adapter_description\":null,\"vendor_id\":null,\"device_id\":null,\"adapter_flags\":null,\"adapter_is_software\":null";
    }
    out << ",\"selected_feature_level\":";
    if (device) out << jsonString(selected == D3D_FEATURE_LEVEL_11_1 ? "11_1" : selected == D3D_FEATURE_LEVEL_11_0 ? "11_0" : "other");
    else out << "null";
    out << ",\"selected_feature_level_value\":" << (device ? hex32(static_cast<uint32_t>(selected)) : "null")
        << ",\"windows_session_id\":" << (sessionOK ? std::to_string(session) : "null")
        << ",\"session_api_success\":" << (sessionOK ? "true" : "false")
        << ",\"session_api_error\":" << sessionError
        << ",\"transport_mode\":" << jsonString(o.transportHost.empty() ? "direct_present" : "offload_tcp")
        << ",\"offload_mode\":" << jsonString(o.offloadMode)
        << ",\"completion_mode\":" << jsonString(o.completionMode)
        << ",\"width\":" << o.width << ",\"height\":" << o.height
        << ",\"commands\":" << o.commands << ",\"resource_bytes\":" << o.resourceBytes
        << ",\"command_every\":" << o.commandEvery << ",\"resource_every\":" << o.resourceEvery
        << ",\"resource_pattern\":" << jsonString(o.resourcePattern) << ",\"seed\":" << o.seed
        << ",\"capture_requested\":" << (!o.capturePath.empty() ? "true" : "false")
        << ",\"capture_frame\":" << o.captureFrame << ",\"enumerated_adapters\":[";
    ComPtr<IDXGIFactory1> factory;
    const HRESULT factoryResult = CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(factory.ReleaseAndGetAddressOf()));
    bool first = true;
    if (SUCCEEDED(factoryResult)) {
        for (UINT i = 0; i < 32; ++i) {
            ComPtr<IDXGIAdapter1> item;
            const HRESULT enumResult = factory->EnumAdapters1(i, &item);
            if (enumResult == DXGI_ERROR_NOT_FOUND || FAILED(enumResult)) break;
            DXGI_ADAPTER_DESC1 d{};
            if (SUCCEEDED(item->GetDesc1(&d))) {
                if (!first) out << ',';
                out << adapterJson(d);
                first = false;
            }
        }
    }
    out << "],\"adapter_enumeration_hresult\":" << hex32(static_cast<uint32_t>(factoryResult)) << '}';
    const std::string value = out.str();
    if (!o.metadataPath.empty()) {
        std::ofstream file(o.metadataPath, std::ios::binary);
        if (!file) throw std::runtime_error("cannot create metadata JSON");
        file << value << '\n';
        if (!file) throw std::runtime_error("cannot write metadata JSON");
    }
    std::cerr << "probe_metadata_json=" << value << '\n' << std::flush;
}

static void fillPayload(std::vector<uint8_t>& payload, const Options& o, unsigned epoch) {
    if (o.resourcePattern == "legacy") {
        for (uint32_t i = 0; i < payload.size(); ++i) payload[i] = static_cast<uint8_t>((i * 31u + 7u) & 255u);
    } else {
        uint32_t state = o.seed ^ (epoch * 0x9e3779b9u);
        if (!state) state = 1;
        for (auto& byte : payload) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
            byte = static_cast<uint8_t>(state);
        }
    }
}

int main(int argc, char** argv) {
    const auto processStart = Clock::now();
    try {
        const Options o = parseOptions(argc, argv);
        const bool offload = !o.transportHost.empty();
        const bool commandOnly = o.offloadMode == "command-only";
        HWND window = (!offload && !o.fingerprintOnly) ? makeWindow(o) : nullptr;
        D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
        D3D_FEATURE_LEVEL selected{};
        const D3D_DRIVER_TYPE driver = o.driverType == "warp" ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE;
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        ComPtr<IDXGISwapChain> swapChain;
        HRESULT createResult = E_FAIL;
        std::vector<HRESULT> createAttempts;
        auto create = [&](const D3D_FEATURE_LEVEL* requestedLevels, UINT count) {
            if (!window) {
                return D3D11CreateDevice(nullptr, driver, nullptr, 0, requestedLevels, count,
                    D3D11_SDK_VERSION, &device, &selected, &context);
            }
            DXGI_SWAP_CHAIN_DESC swapDesc{};
            swapDesc.BufferCount = 2; swapDesc.BufferDesc.Width = o.width; swapDesc.BufferDesc.Height = o.height;
            swapDesc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            swapDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            swapDesc.OutputWindow = window; swapDesc.SampleDesc.Count = 1;
            swapDesc.Windowed = TRUE; swapDesc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
            return D3D11CreateDeviceAndSwapChain(nullptr, driver, nullptr, 0, requestedLevels, count,
                D3D11_SDK_VERSION, &swapDesc, &swapChain, &device, &selected, &context);
        };
        createResult = create(levels, 2);
        createAttempts.push_back(createResult);
        if (createResult == E_INVALIDARG) {
            createResult = create(&levels[1], 1);
            createAttempts.push_back(createResult);
        }
        writeMetadata(o, device.Get(), selected, createResult, createAttempts);
        check(createResult, "D3D11 device creation");
        if (o.fingerprintOnly) {
            std::cerr << "probe_ready_ms=" << std::fixed << std::setprecision(3)
                      << std::chrono::duration<double, std::milli>(Clock::now() - processStart).count() << '\n';
            return 0;
        }

        const uint32_t commandBytes = o.commands * (commandOnly ? 32u : sizeof(CommandRecord));
        const uint32_t payloadOffset = (commandBytes + 15u) & ~15u;
        const uint32_t bufferBytes = (payloadOffset + o.resourceBytes + 3u) & ~3u;
        std::vector<uint8_t> commandData(commandBytes, 0);
        for (unsigned i = 0; i < o.commands; ++i) {
            const size_t offset = i * (commandOnly ? 32u : sizeof(CommandRecord));
            storeLE(commandData.data() + offset, 1u);
            storeLE(commandData.data() + offset + 4, commandOnly ? 3u : i);
            storeLE(commandData.data() + offset + 8, 0u);
            storeLE(commandData.data() + offset + 12, commandOnly ? 0u : i * 17u + 3u);
            if (commandOnly) {
                storeLE(commandData.data() + offset + 16, payloadOffset);
                storeLE(commandData.data() + offset + 20, o.resourceBytes);
                storeLE(commandData.data() + offset + 24, o.width);
                storeLE(commandData.data() + offset + 28, 0u);
            }
        }
        std::vector<uint8_t> payload(o.resourceBytes);
        fillPayload(payload, o, 0);
        ComPtr<ID3D11Texture2D> renderTexture, stagingTexture;
        ComPtr<ID3D11RenderTargetView> renderTarget;
        ComPtr<ID3D11VertexShader> vertexShader;
        ComPtr<ID3D11PixelShader> pixelShader;
        ComPtr<ID3D11Buffer> inputBuffer, paramsBuffer;
        ComPtr<ID3D11ShaderResourceView> inputSrv;
        ComPtr<IDXGIAdapter3> adapter;
        ComPtr<ID3D11Query> completionEvent;
        std::vector<FrameQueries> queries(commandOnly ? 0 : o.frames);
        if (!commandOnly) {
            if (offload) {
                D3D11_TEXTURE2D_DESC d{};
                d.Width = o.width; d.Height = o.height; d.MipLevels = 1; d.ArraySize = 1;
                d.Format = DXGI_FORMAT_R8G8B8A8_UNORM; d.SampleDesc.Count = 1;
                d.Usage = D3D11_USAGE_DEFAULT; d.BindFlags = D3D11_BIND_RENDER_TARGET;
                check(device->CreateTexture2D(&d, nullptr, &renderTexture), "CreateTexture2D output");
            } else {
                check(swapChain->GetBuffer(0, IID_PPV_ARGS(&renderTexture)), "GetBuffer");
            }
            if (offload || !o.capturePath.empty()) {
                D3D11_TEXTURE2D_DESC d{};
                renderTexture->GetDesc(&d);
                d.Usage = D3D11_USAGE_STAGING; d.BindFlags = 0; d.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                check(device->CreateTexture2D(&d, nullptr, &stagingTexture), "CreateTexture2D staging");
            }
            check(device->CreateRenderTargetView(renderTexture.Get(), nullptr, &renderTarget), "CreateRenderTargetView");
            ComPtr<ID3DBlob> vsBlob, psBlob;
            compileShader("VSMain", "vs_5_0", vsBlob); compileShader("PSMain", "ps_5_0", psBlob);
            check(device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &vertexShader), "CreateVertexShader");
            check(device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &pixelShader), "CreatePixelShader");
            D3D11_BUFFER_DESC inputDesc{};
            inputDesc.ByteWidth = bufferBytes; inputDesc.Usage = D3D11_USAGE_DYNAMIC;
            inputDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE; inputDesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
            inputDesc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
            check(device->CreateBuffer(&inputDesc, nullptr, &inputBuffer), "CreateBuffer input");
            D3D11_SHADER_RESOURCE_VIEW_DESC srvDesc{};
            srvDesc.Format = DXGI_FORMAT_R32_TYPELESS; srvDesc.ViewDimension = D3D11_SRV_DIMENSION_BUFFEREX;
            srvDesc.BufferEx.NumElements = bufferBytes / 4; srvDesc.BufferEx.Flags = D3D11_BUFFEREX_SRV_FLAG_RAW;
            check(device->CreateShaderResourceView(inputBuffer.Get(), &srvDesc, &inputSrv), "CreateShaderResourceView");
            D3D11_BUFFER_DESC paramsDesc{};
            paramsDesc.ByteWidth = 16; paramsDesc.Usage = D3D11_USAGE_DYNAMIC;
            paramsDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER; paramsDesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
            check(device->CreateBuffer(&paramsDesc, nullptr, &paramsBuffer), "CreateBuffer params");
            D3D11_VIEWPORT viewport{};
            viewport.Width = static_cast<float>(o.width); viewport.Height = static_cast<float>(o.height); viewport.MaxDepth = 1;
            context->RSSetViewports(1, &viewport);
            context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            ID3D11Buffer* cb = paramsBuffer.Get(); ID3D11ShaderResourceView* srv = inputSrv.Get();
            context->VSSetShader(vertexShader.Get(), nullptr, 0); context->PSSetShader(pixelShader.Get(), nullptr, 0);
            context->PSSetConstantBuffers(0, 1, &cb); context->PSSetShaderResources(0, 1, &srv);
            ComPtr<IDXGIDevice> dxgiDevice; ComPtr<IDXGIAdapter> baseAdapter;
            if (SUCCEEDED(device.As(&dxgiDevice)) && SUCCEEDED(dxgiDevice->GetAdapter(&baseAdapter))) baseAdapter.As(&adapter);
            if (o.completionMode == "gpu-complete") {
                D3D11_QUERY_DESC d{}; d.Query = D3D11_QUERY_EVENT;
                check(device->CreateQuery(&d, &completionEvent), "CreateQuery completion event");
            }
            for (auto& q : queries) {
                D3D11_QUERY_DESC d{}; d.Query = D3D11_QUERY_TIMESTAMP_DISJOINT;
                check(device->CreateQuery(&d, &q.disjoint), "CreateQuery disjoint");
                d.Query = D3D11_QUERY_TIMESTAMP;
                check(device->CreateQuery(&d, &q.start), "CreateQuery start");
                check(device->CreateQuery(&d, &q.end), "CreateQuery end");
            }
        } else {
            // Device creation is retained only for M0. No Guest GPU work is submitted.
            context.ReleaseAndGetAddressOf(); device.ReleaseAndGetAddressOf();
        }
        SOCKET transport = INVALID_SOCKET;
        const uint16_t version = commandOnly ? 2 : 1;
        if (offload) transport = connectHost(o, commandBytes, commandOnly ? 0 : o.width * o.height * 4);
        const double initializationMs = std::chrono::duration<double, std::milli>(Clock::now() - processStart).count();
        std::cerr << "probe_ready_ms=" << std::fixed << std::setprecision(3) << initializationMs << '\n' << std::flush;

        auto renderOne = [&](unsigned frame, FrameQueries* q, FrameResult* result) {
            MSG msg{};
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
            const auto start = Clock::now();
            if (frame && frame % o.resourceEvery == 0) fillPayload(payload, o, frame / o.resourceEvery);
            const bool capture = !o.capturePath.empty() && frame == o.captureFrame;
            std::vector<uint8_t> pixels;
            if (!commandOnly) {
                D3D11_MAPPED_SUBRESOURCE mapped{};
                check(context->Map(inputBuffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped), "Map input");
                std::memcpy(mapped.pData, commandData.data(), commandBytes);
                std::memcpy(static_cast<uint8_t*>(mapped.pData) + payloadOffset, payload.data(), o.resourceBytes);
                context->Unmap(inputBuffer.Get(), 0);
                check(context->Map(paramsBuffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped), "Map params");
                const uint32_t params[4] = {payloadOffset, o.resourceBytes, o.width, 0u};
                std::memcpy(mapped.pData, params, sizeof(params)); context->Unmap(paramsBuffer.Get(), 0);
                ID3D11RenderTargetView* rtv = renderTarget.Get(); context->OMSetRenderTargets(1, &rtv, nullptr);
                if (q) { context->Begin(q->disjoint.Get()); context->End(q->start.Get()); }
                for (unsigned n = 0; n < o.commands; ++n) context->Draw(3, 0);
                if (offload || capture) context->CopyResource(stagingTexture.Get(), renderTexture.Get());
                if (q) { context->End(q->end.Get()); context->End(q->disjoint.Get()); }
                if (offload || capture) {
                    D3D11_MAPPED_SUBRESOURCE image{};
                    check(context->Map(stagingTexture.Get(), 0, D3D11_MAP_READ, 0, &image), "Map staging output");
                    pixels.resize(static_cast<size_t>(o.width) * o.height * 4);
                    for (unsigned row = 0; row < o.height; ++row)
                        std::memcpy(pixels.data() + static_cast<size_t>(row) * o.width * 4,
                            static_cast<const uint8_t*>(image.pData) + static_cast<size_t>(row) * image.RowPitch,
                            static_cast<size_t>(o.width) * 4);
                    context->Unmap(stagingTexture.Get(), 0);
                }
                if (capture) {
                    std::ofstream image(o.capturePath, std::ios::binary);
                    if (!image) throw std::runtime_error("cannot create RGBA capture");
                    image.write(reinterpret_cast<const char*>(pixels.data()), static_cast<std::streamsize>(pixels.size()));
                    if (!image) throw std::runtime_error("cannot write RGBA capture");
                }
            }
            if (offload) {
                std::array<uint8_t, 32> header{};
                const uint32_t commandTransfer = (frame == 0 || frame % o.commandEvery == 0) ? commandBytes : 0;
                const uint32_t resourceTransfer = (frame == 0 || frame % o.resourceEvery == 0) ? o.resourceBytes : 0;
                makeHeader(header.data(), 2, frame, o.width, o.height, commandTransfer, resourceTransfer,
                           static_cast<uint32_t>(pixels.size()), version);
                const uint64_t packetBytes = header.size() + commandTransfer + resourceTransfer + pixels.size();
                sendAll(transport, header.data(), header.size());
                if (commandTransfer) sendAll(transport, commandData.data(), commandTransfer);
                if (resourceTransfer) sendAll(transport, payload.data(), resourceTransfer);
                if (!pixels.empty()) sendAll(transport, pixels.data(), pixels.size());
                std::array<uint8_t, 32> ack{}; recvAll(transport, ack.data(), ack.size());
                if (ack[0] != 'G' || ack[1] != 'F' || ack[2] != 'X' || ack[3] != '1' ||
                    ack[4] != version || ack[5] != 0 || ack[6] != 3 || ack[7] != 0 ||
                    loadLE(ack.data() + 8) != frame ||
                    loadLE(ack.data() + 12) || loadLE(ack.data() + 16) ||
                    loadLE(ack.data() + 20) || loadLE(ack.data() + 24) || loadLE(ack.data() + 28))
                    throw std::runtime_error("invalid host acknowledgement");
                std::array<uint8_t, 24> metrics{}; recvAll(transport, metrics.data(), metrics.size());
                if (result) {
                    result->networkBytesOut = packetBytes; result->networkBytesIn = ack.size() + metrics.size();
                    result->hostReceiveToPresentMs = loadLE(metrics.data()) / 1000.0;
                    result->hostGpuMs = loadLE(metrics.data() + 4) / 1000.0;
                    std::memcpy(&result->hostResidentBytes, metrics.data() + 8, sizeof(uint64_t));
                    std::memcpy(&result->hostTextureBytes, metrics.data() + 16, sizeof(uint64_t));
                }
            } else {
                check(swapChain->Present(0, 0), "Present");
                if (o.completionMode == "gpu-complete") {
                    context->End(completionEvent.Get()); context->Flush();
                    const auto deadline = Clock::now() + std::chrono::seconds(30);
                    BOOL completed = FALSE;
                    HRESULT status = S_FALSE;
                    while ((status = context->GetData(completionEvent.Get(), &completed, sizeof(completed), 0)) == S_FALSE) {
                        if (Clock::now() >= deadline) throw std::runtime_error("frame GPU completion timed out");
                        if (FAILED(device->GetDeviceRemovedReason())) throw std::runtime_error("D3D device removed");
                        Sleep(0);
                    }
                    check(status, "GetData frame completion");
                    if (!completed) throw std::runtime_error("frame GPU completion event was not signaled");
                }
            }
            if (result) {
                result->cpuSubmitMs = std::chrono::duration<double, std::milli>(Clock::now() - start).count();
                result->inputToPresentMs = result->cpuSubmitMs;
            }
        };
        const auto warmupStart = Clock::now();
        for (unsigned i = 0; i < o.warmup; ++i) renderOne(i, nullptr, nullptr);
        const double warmupMs = std::chrono::duration<double, std::milli>(Clock::now() - warmupStart).count();
        std::vector<FrameResult> results(o.frames);
        const auto measurementStart = Clock::now();
        auto previousStart = Clock::now();
        for (unsigned i = 0; i < o.frames; ++i) {
            const auto frameStart = Clock::now(); const uint64_t cpuBefore = processCpu100ns();
            results[i].cpuFrameMs = i == 0 ? 0 : std::chrono::duration<double, std::milli>(frameStart - previousStart).count();
            renderOne(o.warmup + i, commandOnly ? nullptr : &queries[i], &results[i]);
            results[i].processCpuMs = static_cast<double>(processCpu100ns() - cpuBefore) / 10000.0;
            results[i].residentBytes = workingSetBytes();
            results[i].hasDeviceMemory = !commandOnly && queryDeviceMemory(adapter.Get(), results[i].deviceMemoryBytes);
            previousStart = frameStart;
        }
        if (!commandOnly) {
            context->Flush();
            const auto deadline = Clock::now() + std::chrono::seconds(15);
            for (unsigned i = 0; i < o.frames; ++i) {
                D3D11_QUERY_DATA_TIMESTAMP_DISJOINT disjoint{};
                UINT64 startTick = 0, endTick = 0;
                auto waitQuery = [&](ID3D11Query* query, void* destination, UINT size) {
                    HRESULT status = S_FALSE;
                    while ((status = context->GetData(query, destination, size, 0)) == S_FALSE) {
                        if (Clock::now() >= deadline) throw std::runtime_error("GPU query timed out");
                        if (FAILED(device->GetDeviceRemovedReason())) throw std::runtime_error("D3D device removed");
                        Sleep(1);
                    }
                    check(status, "GetData");
                };
                waitQuery(queries[i].disjoint.Get(), &disjoint, sizeof(disjoint));
                waitQuery(queries[i].start.Get(), &startTick, sizeof(startTick));
                waitQuery(queries[i].end.Get(), &endTick, sizeof(endTick));
                if (!disjoint.Disjoint && disjoint.Frequency && endTick > startTick) {
                    results[i].gpuMs = static_cast<double>(endTick - startTick) * 1000 / disjoint.Frequency;
                    results[i].hasGpuTiming = true;
                }
            }
        }
        const double measurementWallMs = std::chrono::duration<double, std::milli>(Clock::now() - measurementStart).count();
        std::cerr << "probe_completion_json={\"measured_frames\":" << o.frames
                  << ",\"measurement_wall_ms\":" << std::fixed << std::setprecision(6) << measurementWallMs
                  << ",\"throughput_including_gpu_drain_fps\":" << (1000.0 * o.frames / measurementWallMs)
                  << ",\"completion_mode\":" << jsonString(o.completionMode)
                  << ",\"completion_scope\":\"gpu-command-complete-not-screen-display\"}\n" << std::flush;
        std::ofstream file; std::ostream* out = &std::cout;
        if (o.csvPath != "-") { file.open(o.csvPath); if (!file) throw std::runtime_error("cannot open CSV output"); out = &file; }
        writeHeader(*out); *out << std::fixed << std::setprecision(6);
        for (unsigned i = 0; i < o.frames; ++i) {
            const auto& r = results[i]; const unsigned frame = o.warmup + i;
            *out << (offload ? "offload_tcp" : "direct_present") << ',' << i << ',' << initializationMs << ',' << warmupMs << ','
                 << r.cpuFrameMs << ',' << r.cpuSubmitMs << ',' << r.processCpuMs << ',';
            if (r.hasGpuTiming) *out << r.gpuMs;
            *out << ',' << r.inputToPresentMs << ',' << r.networkBytesOut + r.networkBytesIn << ','
                 << (offload && (frame == 0 || frame % o.commandEvery == 0) ? commandBytes : 0) << ','
                 << (offload && (frame == 0 || frame % o.resourceEvery == 0) ? o.resourceBytes : 0) << ',' << r.residentBytes << ',';
            if (r.hasDeviceMemory) *out << r.deviceMemoryBytes;
            *out << ",,," << r.networkBytesOut << ',' << r.networkBytesIn << ',';
            if (offload) *out << r.hostReceiveToPresentMs;
            *out << ',';
            if (offload && r.hostGpuMs > 0) *out << r.hostGpuMs;
            *out << ',';
            if (offload && r.hostResidentBytes > 0) *out << r.hostResidentBytes;
            *out << ',';
            if (offload) *out << r.hostTextureBytes;
            *out << '\n';
        }
        if (file) file.close();
        if (transport != INVALID_SOCKET) { closesocket(transport); WSACleanup(); }
        if (window) DestroyWindow(window);
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "d3d11_probe: " << e.what() << '\n';
        return 2;
    }
}
