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
                       uint32_t commandBytes, uint32_t resourceBytes, uint32_t pixelBytes) {
    out[0] = 'G'; out[1] = 'F'; out[2] = 'X'; out[3] = '1';
    out[4] = 1; out[5] = 0;
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
    makeHeader(hello.data(), 1, o.warmup, o.width, o.height, commandBytes, o.resourceBytes, pixelBytes);
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
        else if (key == "--transport-host") o.transportHost = next();
        else if (key == "--port") {
            const auto port = std::stoul(next());
            if (port == 0 || port > 65535) throw std::runtime_error("port must be in 1...65535");
            o.transportPort = static_cast<unsigned short>(port);
        }
        else if (key == "--help") {
            std::cout << "d3d11_probe --frames N --warmup N --width N --height N --commands N --command-every N --resource-bytes N --resource-every N --transport-host IPv4 --port N --csv PATH\n";
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

int main(int argc, char** argv) {
    const auto processStart = Clock::now();
    try {
        const Options o = parseOptions(argc, argv);
        const bool offload = !o.transportHost.empty();
        HWND window = offload ? nullptr : makeWindow(o);
        UINT flags = 0;
        D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
        D3D_FEATURE_LEVEL selected{};
        ComPtr<ID3D11Device> device;
        ComPtr<ID3D11DeviceContext> context;
        ComPtr<IDXGISwapChain> swapChain;
        if (offload) {
            HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                levels, 2, D3D11_SDK_VERSION, &device, &selected, &context);
            if (hr == E_INVALIDARG) {
                hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                    &levels[1], 1, D3D11_SDK_VERSION, &device, &selected, &context);
            }
            check(hr, "D3D11CreateDevice");
        } else {
            DXGI_SWAP_CHAIN_DESC swapDesc{};
            swapDesc.BufferCount = 2;
            swapDesc.BufferDesc.Width = o.width;
            swapDesc.BufferDesc.Height = o.height;
            swapDesc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            swapDesc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            swapDesc.OutputWindow = window;
            swapDesc.SampleDesc.Count = 1;
            swapDesc.Windowed = TRUE;
            swapDesc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
            HRESULT hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                levels, 2, D3D11_SDK_VERSION, &swapDesc, &swapChain, &device, &selected, &context);
            if (hr == E_INVALIDARG) {
                hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                    &levels[1], 1, D3D11_SDK_VERSION, &swapDesc, &swapChain, &device, &selected, &context);
            }
            check(hr, "D3D11CreateDeviceAndSwapChain");
        }
        ComPtr<ID3D11Texture2D> backBuffer;
        ComPtr<ID3D11Texture2D> renderTexture;
        ComPtr<ID3D11Texture2D> stagingTexture;
        if (offload) {
            D3D11_TEXTURE2D_DESC textureDesc{};
            textureDesc.Width = o.width;
            textureDesc.Height = o.height;
            textureDesc.MipLevels = 1;
            textureDesc.ArraySize = 1;
            textureDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            textureDesc.SampleDesc.Count = 1;
            textureDesc.Usage = D3D11_USAGE_DEFAULT;
            textureDesc.BindFlags = D3D11_BIND_RENDER_TARGET;
            check(device->CreateTexture2D(&textureDesc, nullptr, &renderTexture), "CreateTexture2D output");
            textureDesc.Usage = D3D11_USAGE_STAGING;
            textureDesc.BindFlags = 0;
            textureDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            check(device->CreateTexture2D(&textureDesc, nullptr, &stagingTexture), "CreateTexture2D staging");
        } else {
            check(swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer)), "GetBuffer");
        }
        ComPtr<ID3D11RenderTargetView> renderTarget;
        check(device->CreateRenderTargetView(offload ? renderTexture.Get() : backBuffer.Get(), nullptr, &renderTarget), "CreateRenderTargetView");

        ComPtr<ID3DBlob> vsBlob, psBlob;
        compileShader("VSMain", "vs_5_0", vsBlob);
        compileShader("PSMain", "ps_5_0", psBlob);
        ComPtr<ID3D11VertexShader> vertexShader;
        ComPtr<ID3D11PixelShader> pixelShader;
        check(device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(), nullptr, &vertexShader), "CreateVertexShader");
        check(device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(), nullptr, &pixelShader), "CreatePixelShader");

        const uint32_t commandBytes = o.commands * sizeof(CommandRecord);
        const uint32_t payloadOffset = (commandBytes + 15u) & ~15u;
        const uint32_t bufferBytes = (payloadOffset + o.resourceBytes + 3u) & ~3u;
        D3D11_BUFFER_DESC inputDesc{};
        inputDesc.ByteWidth = bufferBytes;
        inputDesc.Usage = D3D11_USAGE_DYNAMIC;
        inputDesc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        inputDesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        inputDesc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_ALLOW_RAW_VIEWS;
        ComPtr<ID3D11Buffer> inputBuffer;
        check(device->CreateBuffer(&inputDesc, nullptr, &inputBuffer), "CreateBuffer input");
        D3D11_SHADER_RESOURCE_VIEW_DESC srvDesc{};
        srvDesc.Format = DXGI_FORMAT_R32_TYPELESS;
        srvDesc.ViewDimension = D3D11_SRV_DIMENSION_BUFFEREX;
        srvDesc.BufferEx.FirstElement = 0;
        srvDesc.BufferEx.NumElements = bufferBytes / 4;
        srvDesc.BufferEx.Flags = D3D11_BUFFEREX_SRV_FLAG_RAW;
        ComPtr<ID3D11ShaderResourceView> inputSrv;
        check(device->CreateShaderResourceView(inputBuffer.Get(), &srvDesc, &inputSrv), "CreateShaderResourceView");

        D3D11_BUFFER_DESC paramsDesc{};
        paramsDesc.ByteWidth = 16;
        paramsDesc.Usage = D3D11_USAGE_DYNAMIC;
        paramsDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        paramsDesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        ComPtr<ID3D11Buffer> paramsBuffer;
        check(device->CreateBuffer(&paramsDesc, nullptr, &paramsBuffer), "CreateBuffer params");

        D3D11_VIEWPORT viewport{};
        viewport.Width = static_cast<float>(o.width);
        viewport.Height = static_cast<float>(o.height);
        viewport.MaxDepth = 1.0f;
        context->RSSetViewports(1, &viewport);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D11Buffer* cb = paramsBuffer.Get();
        ID3D11ShaderResourceView* srv = inputSrv.Get();
        context->VSSetShader(vertexShader.Get(), nullptr, 0);
        context->PSSetShader(pixelShader.Get(), nullptr, 0);
        context->PSSetConstantBuffers(0, 1, &cb);
        context->PSSetShaderResources(0, 1, &srv);

        ComPtr<IDXGIDevice> dxgiDevice;
        ComPtr<IDXGIAdapter> baseAdapter;
        ComPtr<IDXGIAdapter3> adapter;
        if (SUCCEEDED(device.As(&dxgiDevice)) && SUCCEEDED(dxgiDevice->GetAdapter(&baseAdapter))) baseAdapter.As(&adapter);

        const uint64_t appResourceBytes = static_cast<uint64_t>(o.width) * o.height * 4 * 2 + bufferBytes + 16;
        SOCKET transport = INVALID_SOCKET;
        if (offload) transport = connectHost(o, commandBytes, o.width * o.height * 4);
        std::vector<CommandRecord> commands(o.commands);
        for (unsigned i = 0; i < o.commands; ++i) commands[i] = { 1u, i, 0u, i * 17u + 3u };
        std::vector<uint8_t> payload(o.resourceBytes);
        for (uint32_t i = 0; i < o.resourceBytes; ++i) payload[i] = static_cast<uint8_t>((i * 31u + 7u) & 255u);

        std::vector<FrameQueries> queries(o.frames);
        for (auto& q : queries) {
            D3D11_QUERY_DESC d{};
            d.Query = D3D11_QUERY_TIMESTAMP_DISJOINT;
            check(device->CreateQuery(&d, &q.disjoint), "CreateQuery disjoint");
            d.Query = D3D11_QUERY_TIMESTAMP;
            check(device->CreateQuery(&d, &q.start), "CreateQuery start");
            check(device->CreateQuery(&d, &q.end), "CreateQuery end");
        }
        const double initializationMs = std::chrono::duration<double, std::milli>(Clock::now() - processStart).count();
        std::cerr << "probe_ready_ms=" << std::fixed << std::setprecision(3) << initializationMs << "\n" << std::flush;

        auto renderOne = [&](unsigned frame, FrameQueries* queries, FrameResult* result) {
            MSG msg{};
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
            const auto start = Clock::now();
            D3D11_MAPPED_SUBRESOURCE mapped{};
            check(context->Map(inputBuffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped), "Map input");
            std::memcpy(mapped.pData, commands.data(), commandBytes);
            std::memcpy(static_cast<uint8_t*>(mapped.pData) + payloadOffset, payload.data(), o.resourceBytes);
            context->Unmap(inputBuffer.Get(), 0);
            check(context->Map(paramsBuffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped), "Map params");
            const uint32_t params[4] = { payloadOffset, o.resourceBytes, o.width, 0u };
            std::memcpy(mapped.pData, params, sizeof(params));
            context->Unmap(paramsBuffer.Get(), 0);
            ID3D11RenderTargetView* rtv = renderTarget.Get();
            context->OMSetRenderTargets(1, &rtv, nullptr);
            if (queries) {
                context->Begin(queries->disjoint.Get());
                context->End(queries->start.Get());
            }
            for (unsigned n = 0; n < o.commands; ++n) context->Draw(3, 0);
            if (offload) {
                context->CopyResource(stagingTexture.Get(), renderTexture.Get());
            }
            if (queries) {
                context->End(queries->end.Get());
                context->End(queries->disjoint.Get());
            }
            if (offload) {
                D3D11_MAPPED_SUBRESOURCE image{};
                check(context->Map(stagingTexture.Get(), 0, D3D11_MAP_READ, 0, &image), "Map staging output");
                std::vector<uint8_t> pixels(static_cast<size_t>(o.width) * o.height * 4);
                for (unsigned row = 0; row < o.height; ++row) {
                    std::memcpy(pixels.data() + static_cast<size_t>(row) * o.width * 4,
                                static_cast<const uint8_t*>(image.pData) + static_cast<size_t>(row) * image.RowPitch,
                                static_cast<size_t>(o.width) * 4);
                }
                context->Unmap(stagingTexture.Get(), 0);
                std::array<uint8_t, 32> header{};
                const uint32_t commandTransferBytes = frame % o.commandEvery == 0 ? commandBytes : 0;
                const uint32_t resourceTransferBytes = frame % o.resourceEvery == 0 ? o.resourceBytes : 0;
                makeHeader(header.data(), 2, frame, o.width, o.height, commandTransferBytes, resourceTransferBytes, o.width * o.height * 4);
                const uint64_t packetBytes = header.size() + commandTransferBytes + resourceTransferBytes + pixels.size();
                sendAll(transport, header.data(), header.size());
                if (commandTransferBytes) sendAll(transport, reinterpret_cast<const uint8_t*>(commands.data()), commandTransferBytes);
                if (resourceTransferBytes) sendAll(transport, payload.data(), resourceTransferBytes);
                sendAll(transport, pixels.data(), pixels.size());
                std::array<uint8_t, 32> ack{};
                recvAll(transport, ack.data(), ack.size());
                if (ack[0] != 'G' || ack[1] != 'F' || ack[2] != 'X' || ack[3] != '1' ||
                    ack[6] != 3 || loadLE(ack.data() + 8) != frame) throw std::runtime_error("invalid host acknowledgement");
                std::array<uint8_t, 24> metrics{};
                recvAll(transport, metrics.data(), metrics.size());
                if (result) {
                    result->networkBytesOut = packetBytes;
                    result->networkBytesIn = ack.size() + metrics.size();
                    result->hostReceiveToPresentMs = loadLE(metrics.data()) / 1000.0;
                    result->hostGpuMs = loadLE(metrics.data() + 4) / 1000.0;
                    std::memcpy(&result->hostResidentBytes, metrics.data() + 8, sizeof(uint64_t));
                    std::memcpy(&result->hostTextureBytes, metrics.data() + 16, sizeof(uint64_t));
                }
            } else {
                check(swapChain->Present(0, 0), "Present");
            }
            const auto end = Clock::now();
            if (result) {
                result->cpuSubmitMs = std::chrono::duration<double, std::milli>(end - start).count();
                result->inputToPresentMs = result->cpuSubmitMs;
            }
        };

        const auto warmupStart = Clock::now();
        for (unsigned i = 0; i < o.warmup; ++i) renderOne(i, nullptr, nullptr);
        const double warmupMs = std::chrono::duration<double, std::milli>(Clock::now() - warmupStart).count();

        std::vector<FrameResult> results(o.frames);
        auto previousStart = Clock::now();
        for (unsigned i = 0; i < o.frames; ++i) {
            const auto frameStart = Clock::now();
            const uint64_t cpuBefore = processCpu100ns();
            results[i].cpuFrameMs = i == 0 ? 0.0 : std::chrono::duration<double, std::milli>(frameStart - previousStart).count();
            renderOne(o.warmup + i, &queries[i], &results[i]);
            const uint64_t cpuAfter = processCpu100ns();
            results[i].processCpuMs = static_cast<double>(cpuAfter - cpuBefore) / 10000.0;
            results[i].residentBytes = workingSetBytes();
            results[i].hasDeviceMemory = queryDeviceMemory(adapter.Get(), results[i].deviceMemoryBytes);
            previousStart = frameStart;
        }

        context->Flush();
        const auto queryDeadline = Clock::now() + std::chrono::seconds(15);
        for (unsigned i = 0; i < o.frames; ++i) {
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT disjoint{};
            UINT64 startTick = 0, endTick = 0;
            auto waitQuery = [&](ID3D11Query* query, void* destination, UINT size, const char* name) {
                HRESULT status = S_FALSE;
                while ((status = context->GetData(query, destination, size, 0)) == S_FALSE) {
                    if (Clock::now() >= queryDeadline) throw std::runtime_error(std::string("GPU query timed out: ") + name);
                    if (FAILED(device->GetDeviceRemovedReason())) throw std::runtime_error("D3D device removed while waiting for query");
                    Sleep(1);
                }
                check(status, name);
            };
            waitQuery(queries[i].disjoint.Get(), &disjoint, sizeof(disjoint), "GetData disjoint");
            waitQuery(queries[i].start.Get(), &startTick, sizeof(startTick), "GetData start");
            waitQuery(queries[i].end.Get(), &endTick, sizeof(endTick), "GetData end");
            if (!disjoint.Disjoint && disjoint.Frequency && endTick > startTick) {
                results[i].gpuMs = static_cast<double>(endTick - startTick) * 1000.0 / disjoint.Frequency;
                results[i].hasGpuTiming = true;
            }
        }

        std::ofstream file;
        std::ostream* out = &std::cout;
        if (o.csvPath != "-") { file.open(o.csvPath); if (!file) throw std::runtime_error("cannot open CSV output"); out = &file; }
        writeHeader(*out);
        *out << std::fixed << std::setprecision(6);
        const uint64_t commandBytesPerFrame = commandBytes;
        for (unsigned i = 0; i < o.frames; ++i) {
            const auto& r = results[i];
            *out << (offload ? "offload_tcp" : "direct_present") << ',' << i << ',' << initializationMs << ',' << warmupMs << ','
                 << r.cpuFrameMs << ',' << r.cpuSubmitMs << ',' << r.processCpuMs << ',';
            if (r.hasGpuTiming) *out << r.gpuMs;
            *out << ','
                 << r.inputToPresentMs << ',' << r.networkBytesOut + r.networkBytesIn << ','
                 << (offload && ((o.warmup + i) % o.commandEvery == 0) ? commandBytesPerFrame : 0) << ','
                 << (offload && ((o.warmup + i) % o.resourceEvery == 0) ? o.resourceBytes : 0) << ',' << r.residentBytes << ',';
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
        std::cerr << "d3d11_probe: " << e.what() << "\n";
        return 2;
    }
}
