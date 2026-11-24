// Real 3D High-Stress D3D11 Benchmark Probe (2,048 Draw Calls/frame, Multi-Pass, Dynamic CB/VB, Async SwapChain)
// Owner: @DNPMBHC

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <psapi.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct Config {
    int width = 1280;
    int height = 720;
    int warmup_frames = 30;
    int measured_frames = 180;
    int draws_per_frame = 2048;
    int cb_updates_per_frame = 256;
    std::string csv_path;
    std::string capture_path;
    bool warp = false;
    std::string notify_host;
    std::string notify_token;
    int notify_port = 0;
};

struct Vertex {
    float x, y, z;
    float u, v;
    float object_index;
};

struct alignas(16) DrawConstants {
    float offset_xy[2];
    float scale_xy[2];
    float color_rgba[4];
    float time_params[4];
};

const char* kPass1Shader = R"(
cbuffer DrawCB : register(b0) {
    float2 offset_xy;
    float2 scale_xy;
    float4 color_rgba;
    float4 time_params;
};

Texture2D texA : register(t0);
Texture2D texB : register(t1);
SamplerState sampLinear : register(s0);

struct VSIn {
    float3 pos : POSITION;
    float2 uv  : TEXCOORD0;
    float object_index : OBJECT0;
};

struct PSIn {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
    float4 col : COLOR0;
};

PSIn VSMain(VSIn input) {
    PSIn o;
    float angle = time_params.x + offset_xy.x * 3.14159;
    float s = sin(angle);
    float c = cos(angle);
    float2 p = float2(
        input.pos.x * c - input.pos.y * s,
        input.pos.x * s + input.pos.y * c
    );
    float gx = fmod(input.object_index, 64.0);
    float gy = floor(input.object_index / 64.0);
    float2 draw_offset = float2(-0.96 + gx * (1.92 / 64.0), -0.94 + gy * (1.88 / 32.0));
    p = p * scale_xy + draw_offset;
    o.pos = float4(p, input.pos.z, 1.0);
    o.uv = input.uv + time_params.yz * 0.05;
    o.col = color_rgba;
    return o;
}

float4 PSMain(PSIn input) : SV_TARGET {
    float4 a = texA.Sample(sampLinear, input.uv);
    float4 b = texB.Sample(sampLinear, input.uv * 2.0 + float2(time_params.w, -time_params.w));
    return saturate((a * 0.65 + b * 0.35) * input.col);
}
)";

const char* kPass2Shader = R"(
cbuffer CompositeCB : register(b0) {
    float2 offset_xy;
    float2 scale_xy;
    float4 color_rgba;
    float4 time_params;
};

Texture2D sceneTex : register(t0);
Texture2D detailTex : register(t1);
SamplerState sampLinear : register(s0);

struct PSIn {
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

PSIn VSMain(uint vid : SV_VertexID) {
    PSIn o;
    float2 pos = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
    o.pos = float4(pos, 0.0, 1.0);
    o.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5);
    return o;
}

float4 PSMain(PSIn input) : SV_TARGET {
    float2 texel = float2(1.0 / max(scale_xy.x, 1.0), 1.0 / max(scale_xy.y, 1.0));
    float4 c0 = sceneTex.Sample(sampLinear, input.uv);
    float4 c1 = sceneTex.Sample(sampLinear, input.uv + float2(texel.x, 0.0));
    float4 c2 = sceneTex.Sample(sampLinear, input.uv + float2(0.0, texel.y));
    float4 d  = detailTex.Sample(sampLinear, input.uv * 4.0 + time_params.xy * 0.01);
    float4 blended = c0 * 0.6 + (c1 + c2) * 0.2;
    return saturate(blended * 0.92 + d * 0.08);
}
)";

double now_ms(LARGE_INTEGER freq) {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (static_cast<double>(t.QuadPart) * 1000.0) / static_cast<double>(freq.QuadPart);
}

std::string wide_to_utf8(const wchar_t* wstr) {
    if (!wstr) return "";
    int needed = WideCharToMultiByte(CP_UTF8, 0, wstr, -1, nullptr, 0, nullptr, nullptr);
    if (needed <= 1) return "";
    std::string out(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wstr, -1, &out[0], needed, nullptr, nullptr);
    out.resize(static_cast<size_t>(needed - 1));
    return out;
}

std::string json_escape(const std::string& s) {
    std::ostringstream oss;
    for (unsigned char ch : s) {
        if (ch == '"' || ch == '\\') {
            oss << '\\' << static_cast<char>(ch);
        } else if (ch >= 0x20 && ch < 0x7f) {
            oss << static_cast<char>(ch);
        } else {
            oss << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(ch) << std::dec;
        }
    }
    return oss.str();
}

const char* feature_level_name(D3D_FEATURE_LEVEL fl) {
    switch (fl) {
        case D3D_FEATURE_LEVEL_11_1: return "11_1";
        case D3D_FEATURE_LEVEL_11_0: return "11_0";
        case D3D_FEATURE_LEVEL_10_1: return "10_1";
        case D3D_FEATURE_LEVEL_10_0: return "10_0";
        default: return "other";
    }
}

uint64_t query_resident_bytes() {
    PROCESS_MEMORY_COUNTERS_EX pmc;
    std::memset(&pmc, 0, sizeof(pmc));
    if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&pmc), sizeof(pmc))) {
        return static_cast<uint64_t>(pmc.WorkingSetSize);
    }
    return 0;
}

uint64_t query_device_memory_bytes(IDXGIAdapter3* adapter3) {
    if (!adapter3) return 0;
    DXGI_QUERY_VIDEO_MEMORY_INFO info;
    std::memset(&info, 0, sizeof(info));
    if (SUCCEEDED(adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info))) {
        return static_cast<uint64_t>(info.CurrentUsage);
    }
    return 0;
}

bool create_procedural_texture(
    ID3D11Device* device,
    int tex_size,
    uint32_t seed,
    ID3D11Texture2D** out_tex,
    ID3D11ShaderResourceView** out_srv
) {
    std::vector<uint32_t> pixels(static_cast<size_t>(tex_size * tex_size));
    for (int y = 0; y < tex_size; ++y) {
        for (int x = 0; x < tex_size; ++x) {
            uint32_t r = ((x * 7 + seed * 31) ^ (y * 3)) & 0xFF;
            uint32_t g = ((y * 5 + seed * 17) + (x / 2)) & 0xFF;
            uint32_t b = (((x + y) * 3 + seed * 13)) & 0xFF;
            pixels[static_cast<size_t>(y * tex_size + x)] = (0xFFu << 24) | (b << 16) | (g << 8) | r;
        }
    }
    D3D11_TEXTURE2D_DESC td;
    std::memset(&td, 0, sizeof(td));
    td.Width = static_cast<UINT>(tex_size);
    td.Height = static_cast<UINT>(tex_size);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;

    D3D11_SUBRESOURCE_DATA init;
    std::memset(&init, 0, sizeof(init));
    init.pSysMem = pixels.data();
    init.SysMemPitch = static_cast<UINT>(tex_size * 4);

    if (FAILED(device->CreateTexture2D(&td, &init, out_tex))) return false;
    if (FAILED(device->CreateShaderResourceView(*out_tex, nullptr, out_srv))) return false;
    return true;
}

bool parse_args(int argc, char** argv, Config& cfg) {
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next_val = [&](std::string& dst) -> bool {
            if (i + 1 >= argc) return false;
            dst = argv[++i];
            return true;
        };
        std::string v;
        if (a == "--width" && next_val(v)) cfg.width = std::atoi(v.c_str());
        else if (a == "--height" && next_val(v)) cfg.height = std::atoi(v.c_str());
        else if (a == "--warmup" && next_val(v)) cfg.warmup_frames = std::atoi(v.c_str());
        else if (a == "--frames" && next_val(v)) cfg.measured_frames = std::atoi(v.c_str());
        else if (a == "--draws" && next_val(v)) cfg.draws_per_frame = std::atoi(v.c_str());
        else if (a == "--cb-updates" && next_val(v)) cfg.cb_updates_per_frame = std::atoi(v.c_str());
        else if (a == "--csv" && next_val(v)) cfg.csv_path = v;
        else if (a == "--capture" && next_val(v)) cfg.capture_path = v;
        else if (a == "--warp") cfg.warp = true;
        else if (a == "--notify-host" && next_val(v)) cfg.notify_host = v;
        else if (a == "--notify-token" && next_val(v)) cfg.notify_token = v;
        else if (a == "--notify-port" && next_val(v)) cfg.notify_port = std::atoi(v.c_str());
        else {
            std::cerr << "Unknown argument: " << a << "\n";
            return false;
        }
    }
    if (cfg.width <= 0 || cfg.height <= 0 || cfg.measured_frames <= 0 || cfg.warmup_frames < 0 || cfg.draws_per_frame < 2 || cfg.cb_updates_per_frame < 2 || cfg.cb_updates_per_frame > cfg.draws_per_frame) return false;
    return true;
}

LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

}  // namespace

int main(int argc, char** argv) {
    Config cfg;
    if (!parse_args(argc, argv, cfg)) return 2;

    SOCKET marker_socket = INVALID_SOCKET;
    sockaddr_in marker_address{};
    if (cfg.notify_port > 0) {
        WSADATA data;
        if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return 19;
        marker_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        marker_address.sin_family = AF_INET;
        marker_address.sin_port = htons(static_cast<u_short>(cfg.notify_port));
        marker_address.sin_addr.s_addr = inet_addr(cfg.notify_host.c_str());
        if (marker_socket == INVALID_SOCKET || marker_address.sin_addr.s_addr == INADDR_NONE) return 19;
    }
    auto notify = [&](const char* phase) {
        if (marker_socket != INVALID_SOCKET) {
            const std::string message = cfg.notify_token + "|" + phase;
            return sendto(marker_socket, message.c_str(), static_cast<int>(message.size()), 0,
                          reinterpret_cast<sockaddr*>(&marker_address), sizeof(marker_address)) == static_cast<int>(message.size());
        }
        return true;
    };
    LARGE_INTEGER freq;
    QueryPerformanceFrequency(&freq);
    const double t_start = now_ms(freq);

    WNDCLASSA wc;
    std::memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleA(nullptr);
    wc.lpszClassName = "Real3DStressBenchClass";
    RegisterClassA(&wc);

    RECT rc = {0, 0, cfg.width, cfg.height};
    AdjustWindowRect(&rc, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowExA(
        0, wc.lpszClassName, "Real3D Stress Benchmark (2048 Draws)",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT,
        rc.right - rc.left, rc.bottom - rc.top,
        nullptr, nullptr, wc.hInstance, nullptr
    );
    if (!hwnd) {
        std::cerr << "bench_real3d: CreateWindowExA failed\n";
        return 3;
    }
    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
    UpdateWindow(hwnd);

    DXGI_SWAP_CHAIN_DESC scd;
    std::memset(&scd, 0, sizeof(scd));
    scd.BufferCount = 3;
    scd.BufferDesc.Width = static_cast<UINT>(cfg.width);
    scd.BufferDesc.Height = static_cast<UINT>(cfg.height);
    scd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    scd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.OutputWindow = hwnd;
    scd.SampleDesc.Count = 1;
    scd.Windowed = TRUE;
    scd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0
    };
    D3D_FEATURE_LEVEL selected_fl = D3D_FEATURE_LEVEL_11_0;
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* ctx = nullptr;
    IDXGISwapChain* swapchain = nullptr;

    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        nullptr, cfg.warp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
        levels, 4, D3D11_SDK_VERSION,
        &scd, &swapchain, &device, &selected_fl, &ctx
    );
    if (FAILED(hr)) {
        hr = D3D11CreateDeviceAndSwapChain(
            nullptr, cfg.warp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
            levels + 1, 3, D3D11_SDK_VERSION,
            &scd, &swapchain, &device, &selected_fl, &ctx
        );
    }
    if (FAILED(hr) || !device || !ctx || !swapchain) {
        std::cerr << "bench_real3d: D3D11CreateDeviceAndSwapChain failed hr=0x"
                  << std::hex << static_cast<uint32_t>(hr) << std::dec << "\n";
        return 4;
    }

    IDXGIDevice* dxgi_device = nullptr;
    IDXGIAdapter* adapter = nullptr;
    IDXGIAdapter1* adapter1 = nullptr;
    IDXGIAdapter3* adapter3 = nullptr;
    std::string adapter_desc = "unknown";
    uint32_t vendor_id = 0;
    uint32_t device_id = 0;
    uint32_t adapter_flags = 0;
    bool adapter_is_software = false;
    if (SUCCEEDED(device->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void**>(&dxgi_device))) && dxgi_device) {
        if (SUCCEEDED(dxgi_device->GetAdapter(&adapter)) && adapter) {
            if (SUCCEEDED(adapter->QueryInterface(__uuidof(IDXGIAdapter1), reinterpret_cast<void**>(&adapter1))) && adapter1) {
                DXGI_ADAPTER_DESC1 desc1;
                std::memset(&desc1, 0, sizeof(desc1));
                if (SUCCEEDED(adapter1->GetDesc1(&desc1))) {
                    adapter_desc = wide_to_utf8(desc1.Description);
                    vendor_id = desc1.VendorId;
                    device_id = desc1.DeviceId;
                    adapter_flags = desc1.Flags;
                    adapter_is_software = (desc1.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
                }
                adapter1->QueryInterface(__uuidof(IDXGIAdapter3), reinterpret_cast<void**>(&adapter3));
            }
        }
    }

    // Backbuffer RTV
    ID3D11Texture2D* backbuffer = nullptr;
    ID3D11RenderTargetView* backbuffer_rtv = nullptr;
    if (FAILED(swapchain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&backbuffer))) ||
        FAILED(device->CreateRenderTargetView(backbuffer, nullptr, &backbuffer_rtv))) {
        std::cerr << "bench_real3d: failed to create backbuffer RTV\n";
        return 5;
    }
    // Retain the backbuffer for separate validation readback.


    // Offscreen Pass 1 Render Target + SRV + Depth Stencil
    D3D11_TEXTURE2D_DESC rt_desc;
    std::memset(&rt_desc, 0, sizeof(rt_desc));
    rt_desc.Width = static_cast<UINT>(cfg.width);
    rt_desc.Height = static_cast<UINT>(cfg.height);
    rt_desc.MipLevels = 1;
    rt_desc.ArraySize = 1;
    rt_desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    rt_desc.SampleDesc.Count = 1;
    rt_desc.Usage = D3D11_USAGE_DEFAULT;
    rt_desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;

    ID3D11Texture2D* scene_tex = nullptr;
    ID3D11RenderTargetView* scene_rtv = nullptr;
    ID3D11ShaderResourceView* scene_srv = nullptr;
    if (FAILED(device->CreateTexture2D(&rt_desc, nullptr, &scene_tex)) ||
        FAILED(device->CreateRenderTargetView(scene_tex, nullptr, &scene_rtv)) ||
        FAILED(device->CreateShaderResourceView(scene_tex, nullptr, &scene_srv))) {
        std::cerr << "bench_real3d: failed to create offscreen RT\n";
        return 6;
    }

    D3D11_TEXTURE2D_DESC ds_desc = rt_desc;
    ds_desc.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
    ds_desc.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    ID3D11Texture2D* depth_tex = nullptr;
    ID3D11DepthStencilView* depth_dsv = nullptr;
    if (FAILED(device->CreateTexture2D(&ds_desc, nullptr, &depth_tex)) ||
        FAILED(device->CreateDepthStencilView(depth_tex, nullptr, &depth_dsv))) {
        std::cerr << "bench_real3d: failed to create depth buffer\n";
        return 7;
    }

    // Procedural textures & linear sampler
    ID3D11Texture2D* tex_a = nullptr;
    ID3D11ShaderResourceView* srv_a = nullptr;
    ID3D11Texture2D* tex_b = nullptr;
    ID3D11ShaderResourceView* srv_b = nullptr;
    if (!create_procedural_texture(device, 256, 1, &tex_a, &srv_a) ||
        !create_procedural_texture(device, 256, 7, &tex_b, &srv_b)) {
        std::cerr << "bench_real3d: failed to create procedural textures\n";
        return 8;
    }

    D3D11_SAMPLER_DESC samp_desc;
    std::memset(&samp_desc, 0, sizeof(samp_desc));
    samp_desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    samp_desc.AddressU = D3D11_TEXTURE_ADDRESS_WRAP;
    samp_desc.AddressV = D3D11_TEXTURE_ADDRESS_WRAP;
    samp_desc.AddressW = D3D11_TEXTURE_ADDRESS_WRAP;
    samp_desc.MaxLOD = D3D11_FLOAT32_MAX;
    ID3D11SamplerState* sampler = nullptr;
    if (FAILED(device->CreateSamplerState(&samp_desc, &sampler))) {
        std::cerr << "bench_real3d: failed to create sampler\n";
        return 9;
    }

    // Compile Pass 1 and Pass 2 shaders
    ID3DBlob *vs1_blob = nullptr, *ps1_blob = nullptr, *vs2_blob = nullptr, *ps2_blob = nullptr, *err_blob = nullptr;
    if (FAILED(D3DCompile(kPass1Shader, std::strlen(kPass1Shader), nullptr, nullptr, nullptr, "VSMain", "vs_4_0", 0, 0, &vs1_blob, &err_blob)) ||
        FAILED(D3DCompile(kPass1Shader, std::strlen(kPass1Shader), nullptr, nullptr, nullptr, "PSMain", "ps_4_0", 0, 0, &ps1_blob, &err_blob)) ||
        FAILED(D3DCompile(kPass2Shader, std::strlen(kPass2Shader), nullptr, nullptr, nullptr, "VSMain", "vs_4_0", 0, 0, &vs2_blob, &err_blob)) ||
        FAILED(D3DCompile(kPass2Shader, std::strlen(kPass2Shader), nullptr, nullptr, nullptr, "PSMain", "ps_4_0", 0, 0, &ps2_blob, &err_blob))) {
        if (err_blob) {
            std::cerr << "bench_real3d: shader compile error: "
                      << static_cast<const char*>(err_blob->GetBufferPointer()) << "\n";
            err_blob->Release();
        }
        return 10;
    }

    ID3D11VertexShader *vs1 = nullptr, *vs2 = nullptr;
    ID3D11PixelShader *ps1 = nullptr, *ps2 = nullptr;
    if (FAILED(device->CreateVertexShader(vs1_blob->GetBufferPointer(), vs1_blob->GetBufferSize(), nullptr, &vs1)) ||
        FAILED(device->CreatePixelShader(ps1_blob->GetBufferPointer(), ps1_blob->GetBufferSize(), nullptr, &ps1)) ||
        FAILED(device->CreateVertexShader(vs2_blob->GetBufferPointer(), vs2_blob->GetBufferSize(), nullptr, &vs2)) ||
        FAILED(device->CreatePixelShader(ps2_blob->GetBufferPointer(), ps2_blob->GetBufferSize(), nullptr, &ps2))) {
        std::cerr << "bench_real3d: failed to create shaders\n";
        return 11;
    }

    D3D11_INPUT_ELEMENT_DESC layout_desc[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"OBJECT", 0, DXGI_FORMAT_R32_FLOAT, 0, 20, D3D11_INPUT_PER_VERTEX_DATA, 0}
    };
    ID3D11InputLayout* input_layout = nullptr;
    if (FAILED(device->CreateInputLayout(layout_desc, 3, vs1_blob->GetBufferPointer(), vs1_blob->GetBufferSize(), &input_layout))) {
        std::cerr << "bench_real3d: failed to create input layout\n";
        return 12;
    }
    vs1_blob->Release(); ps1_blob->Release(); vs2_blob->Release(); ps2_blob->Release();

    // Dynamic vertex buffer (24 vertices = 8 triangles per draw call)
    constexpr int kVertsPerDraw = 24;
    D3D11_BUFFER_DESC vb_desc;
    std::memset(&vb_desc, 0, sizeof(vb_desc));
    vb_desc.ByteWidth = static_cast<UINT>(sizeof(Vertex) * kVertsPerDraw * (cfg.draws_per_frame - 1));
    vb_desc.Usage = D3D11_USAGE_DYNAMIC;
    vb_desc.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    vb_desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    ID3D11Buffer* vb = nullptr;
    if (FAILED(device->CreateBuffer(&vb_desc, nullptr, &vb))) {
        std::cerr << "bench_real3d: failed to create dynamic VB\n";
        return 13;
    }

    // Dynamic constant buffer
    D3D11_BUFFER_DESC cb_desc;
    std::memset(&cb_desc, 0, sizeof(cb_desc));
    cb_desc.ByteWidth = sizeof(DrawConstants);
    cb_desc.Usage = D3D11_USAGE_DYNAMIC;
    cb_desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cb_desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    ID3D11Buffer* cb = nullptr;
    if (FAILED(device->CreateBuffer(&cb_desc, nullptr, &cb))) {
        std::cerr << "bench_real3d: failed to create dynamic CB\n";
        return 14;
    }

    D3D11_QUERY_DESC qd;
    std::memset(&qd, 0, sizeof(qd));
    qd.Query = D3D11_QUERY_EVENT;
    ID3D11Query* end_event_query = nullptr;
    if (FAILED(device->CreateQuery(&qd, &end_event_query)) || !end_event_query) return 16;
    auto drain_gpu = [&]() -> bool {
        ctx->End(end_event_query);
        ctx->Flush();
        const double deadline = now_ms(freq) + 30000.0;
        BOOL complete = FALSE;
        while (true) {
            HRESULT result = ctx->GetData(end_event_query, &complete, sizeof(complete), D3D11_ASYNC_GETDATA_DONOTFLUSH);
            if (FAILED(result)) return false;
            if (result == S_OK && complete) return true;
            if (now_ms(freq) >= deadline) return false;
            Sleep(1);
        }
    };

    D3D11_VIEWPORT vp;
    vp.TopLeftX = 0.0f;
    vp.TopLeftY = 0.0f;
    vp.Width = static_cast<FLOAT>(cfg.width);
    vp.Height = static_cast<FLOAT>(cfg.height);
    vp.MinDepth = 0.0f;
    vp.MaxDepth = 1.0f;

    const double init_ms = now_ms(freq) - t_start;
    std::cout << "real3d_metadata_json={\"schema_version\":1"
              << ",\"adapter_description\":\"" << json_escape(adapter_desc) << "\""
              << ",\"vendor_id\":" << vendor_id
              << ",\"device_id\":" << device_id
              << ",\"adapter_flags\":" << adapter_flags
              << ",\"adapter_is_software\":" << (adapter_is_software ? "true" : "false")
              << ",\"selected_feature_level\":\"" << feature_level_name(selected_fl) << "\""
              << ",\"width\":" << cfg.width
              << ",\"height\":" << cfg.height
              << ",\"draws_per_frame\":" << cfg.draws_per_frame
              << ",\"cb_updates_per_frame\":" << cfg.cb_updates_per_frame
              << ",\"passes_per_frame\":2"
              << ",\"dynamic_vertex_bytes_per_frame\":" << vb_desc.ByteWidth
              << ",\"geometry_objects\":" << (cfg.draws_per_frame - 1)
              << ",\"async_swapchain\":true"
              << ",\"initialization_ms\":" << std::fixed << std::setprecision(3) << init_ms
              << "}\n";
    std::cout.flush();

    auto render_frame = [&](int frame_idx) -> bool {
        MSG msg;
        while (PeekMessageA(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            if (msg.message == WM_QUIT) return false;
            DispatchMessageA(&msg);
        }

        // Dynamic VB update every frame
        D3D11_MAPPED_SUBRESOURCE mapped_vb;
        if (SUCCEEDED(ctx->Map(vb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped_vb))) {
            auto* verts = static_cast<Vertex*>(mapped_vb.pData);
            Vertex unit[kVertsPerDraw];
            const float phase = static_cast<float>(frame_idx) * 0.05f;
            for (int tri = 0; tri < kVertsPerDraw / 3; ++tri) {
                const float a0 = phase + static_cast<float>(tri) * 0.785398f;
                const float a1 = a0 + 0.55f;
                const float z = 0.2f + 0.05f * static_cast<float>(tri);
                unit[tri * 3 + 0] = {0.0f, 0.0f, z, 0.5f, 0.5f, 0.0f};
                unit[tri * 3 + 1] = {std::cos(a0), std::sin(a0), z, 1.0f, 0.0f, 0.0f};
                unit[tri * 3 + 2] = {std::cos(a1), std::sin(a1), z, 0.0f, 1.0f, 0.0f};
            }
            for (int object = 0; object < cfg.draws_per_frame - 1; ++object) {
                for (int v = 0; v < kVertsPerDraw; ++v) {
                    Vertex vertex = unit[v];
                    vertex.object_index = static_cast<float>(object);
                    verts[object * kVertsPerDraw + v] = vertex;
                }
            }
            ctx->Unmap(vb, 0);
        } else return false;

        // Pass 1: Offscreen 3D geometry draws
        ID3D11ShaderResourceView* null_srvs[2] = {nullptr, nullptr};
        ctx->PSSetShaderResources(0, 2, null_srvs);

        const float clear_col[4] = {0.06f, 0.08f, 0.12f, 1.0f};
        ctx->OMSetRenderTargets(1, &scene_rtv, depth_dsv);
        ctx->RSSetViewports(1, &vp);
        ctx->ClearRenderTargetView(scene_rtv, clear_col);
        ctx->ClearDepthStencilView(depth_dsv, D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL, 1.0f, 0);

        UINT stride = sizeof(Vertex);
        UINT offset = 0;
        ctx->IASetInputLayout(input_layout);
        ctx->IASetVertexBuffers(0, 1, &vb, &stride, &offset);
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx->VSSetShader(vs1, nullptr, 0);
        ctx->PSSetShader(ps1, nullptr, 0);
        ctx->VSSetConstantBuffers(0, 1, &cb);
        ctx->PSSetConstantBuffers(0, 1, &cb);
        ID3D11ShaderResourceView* pass1_srvs[2] = {srv_a, srv_b};
        ctx->PSSetShaderResources(0, 2, pass1_srvs);
        ctx->PSSetSamplers(0, 1, &sampler);

        const int pass1_draws = cfg.draws_per_frame - 1;
        const int pass1_updates = cfg.cb_updates_per_frame - 1;
        const int cols = 64;
        const int rows = 32;
        for (int d = 0; d < pass1_draws; ++d) {
            if (d == 0 || (d * pass1_updates / pass1_draws) != ((d - 1) * pass1_updates / pass1_draws)) {
                D3D11_MAPPED_SUBRESOURCE mapped_cb;
                if (SUCCEEDED(ctx->Map(cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped_cb))) {
                    auto* c = static_cast<DrawConstants*>(mapped_cb.pData);
                    int gx = d % cols;
                    int gy = (d / cols) % rows;
                    c->offset_xy[0] = -0.96f + (static_cast<float>(gx) / static_cast<float>(cols)) * 1.92f;
                    c->offset_xy[1] = -0.94f + (static_cast<float>(gy) / static_cast<float>(rows)) * 1.88f;
                    c->scale_xy[0] = 0.025f;
                    c->scale_xy[1] = 0.040f;
                    c->color_rgba[0] = 0.3f + 0.7f * static_cast<float>(gx) / static_cast<float>(cols);
                    c->color_rgba[1] = 0.3f + 0.7f * static_cast<float>(gy) / static_cast<float>(rows);
                    c->color_rgba[2] = 0.85f;
                    c->color_rgba[3] = 1.0f;
                    c->time_params[0] = static_cast<float>(frame_idx) * 0.03f;
                    c->time_params[1] = static_cast<float>(gx) * 0.01f;
                    c->time_params[2] = static_cast<float>(gy) * 0.01f;
                    c->time_params[3] = static_cast<float>(frame_idx % 120) / 120.0f;
                    ctx->Unmap(cb, 0);
                } else return false;
            }
            ctx->Draw(kVertsPerDraw, static_cast<UINT>(d * kVertsPerDraw));
        }

        // Pass 2: Fullscreen composite sampling Pass 1 RT + detail texture
        ctx->OMSetRenderTargets(1, &backbuffer_rtv, nullptr);
        ctx->RSSetViewports(1, &vp);
        ctx->IASetInputLayout(nullptr);
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx->VSSetShader(vs2, nullptr, 0);
        ctx->PSSetShader(ps2, nullptr, 0);

        D3D11_MAPPED_SUBRESOURCE mapped_cb2;
        if (SUCCEEDED(ctx->Map(cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped_cb2))) {
            auto* c = static_cast<DrawConstants*>(mapped_cb2.pData);
            c->offset_xy[0] = 0.0f;
            c->offset_xy[1] = 0.0f;
            c->scale_xy[0] = static_cast<float>(cfg.width);
            c->scale_xy[1] = static_cast<float>(cfg.height);
            c->color_rgba[0] = 1.0f;
            c->color_rgba[1] = 1.0f;
            c->color_rgba[2] = 1.0f;
            c->color_rgba[3] = 1.0f;
            c->time_params[0] = static_cast<float>(frame_idx);
            c->time_params[1] = static_cast<float>(frame_idx) * 0.5f;
            c->time_params[2] = 0.0f;
            c->time_params[3] = 0.0f;
            ctx->Unmap(cb, 0);
        } else return false;
        ID3D11ShaderResourceView* pass2_srvs[2] = {scene_srv, srv_b};
        ctx->PSSetShaderResources(0, 2, pass2_srvs);
        ctx->PSSetSamplers(0, 1, &sampler);
        ctx->Draw(3, 0);

        // Async SwapChain present (no per-frame forced GPU event query fence)
        if (!cfg.capture_path.empty() && frame_idx == cfg.warmup_frames + cfg.measured_frames - 1) {
            D3D11_TEXTURE2D_DESC capture_desc;
            backbuffer->GetDesc(&capture_desc);
            capture_desc.Usage = D3D11_USAGE_STAGING;
            capture_desc.BindFlags = 0;
            capture_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            capture_desc.MiscFlags = 0;
            ID3D11Texture2D* staging = nullptr;
            if (FAILED(device->CreateTexture2D(&capture_desc, nullptr, &staging))) return false;
            ctx->CopyResource(staging, backbuffer);
            D3D11_MAPPED_SUBRESOURCE pixels;
            if (FAILED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &pixels))) { staging->Release(); return false; }
            std::ofstream raw(cfg.capture_path, std::ios::binary);
            for (int y = 0; y < cfg.height; ++y) raw.write(static_cast<const char*>(pixels.pData) + y * pixels.RowPitch, cfg.width * 4);
            bool written = raw.good();
            ctx->Unmap(staging, 0); staging->Release();
            if (!written) return false;
        }
        HRESULT present_result = swapchain->Present(0, 0);
        if (present_result != S_OK) {
            std::cerr << "Present result=0x" << std::hex << static_cast<uint32_t>(present_result) << std::dec << "\n";
            return false;
        }
        return true;
    };

    const double warmup_begin = now_ms(freq);
    for (int f = 0; f < cfg.warmup_frames; ++f) {
        if (!render_frame(f)) return 17;
    }
    if (!drain_gpu()) { std::cerr << "GPU completion failed or timed out\n"; return 18; }
    const double warmup_ms = now_ms(freq) - warmup_begin;

    struct FrameSample {
        int index;
        double frame_interval_ms;
        double submit_ms;
        uint64_t resident_bytes;
        uint64_t device_memory_bytes;
    };
    std::vector<FrameSample> samples;
    samples.reserve(static_cast<size_t>(cfg.measured_frames));

    std::cout << "real3d_measurement_begin=1\n"; std::cout.flush();
    if (!notify("begin")) return 19;
    const double measure_begin = now_ms(freq);
    double prev_t = measure_begin;
    for (int f = 0; f < cfg.measured_frames; ++f) {
        const double t0 = now_ms(freq);
        if (!render_frame(cfg.warmup_frames + f)) return 17;
        const double t1 = now_ms(freq);
        samples.push_back({
            f,
            (f == 0) ? (t1 - t0) : (t1 - prev_t),
            t1 - t0,
            query_resident_bytes(),
            query_device_memory_bytes(adapter3)
        });
        prev_t = t1;
    }

    const double drain_begin = now_ms(freq);
    if (!drain_gpu()) { std::cerr << "GPU completion failed or timed out\n"; return 18; }
    const double measure_end = now_ms(freq);
    if (!notify("end")) return 19;
    const double wall_ms = measure_end - measure_begin;
    const double drain_ms = measure_end - drain_begin;
    const double fps = wall_ms > 0.0 ? (static_cast<double>(cfg.measured_frames) * 1000.0 / wall_ms) : 0.0;

    if (!cfg.csv_path.empty()) {
        std::ofstream out(cfg.csv_path, std::ios::binary | std::ios::trunc);
        if (!out) {
            std::cerr << "bench_real3d: failed to open CSV path\n";
            return 15;
        }
        out << "frame_index,cpu_frame_ms,cpu_submit_ms,resident_bytes,device_memory_bytes\n";
        out << std::fixed << std::setprecision(6);
        for (const auto& s : samples) {
            out << s.index << "," << s.frame_interval_ms << "," << s.submit_ms << ","
                << s.resident_bytes << "," << s.device_memory_bytes << "\n";
        }
    }

    std::cout << "real3d_completion_json={\"measured_frames\":" << cfg.measured_frames
              << ",\"warmup_ms\":" << std::fixed << std::setprecision(3) << warmup_ms
              << ",\"measurement_wall_ms\":" << wall_ms
              << ",\"gpu_drain_ms\":" << drain_ms
              << ",\"throughput_including_gpu_drain_fps\":" << std::setprecision(6) << fps
              << ",\"draws_per_frame\":" << cfg.draws_per_frame
              << ",\"total_draw_calls\":" << (static_cast<uint64_t>(cfg.measured_frames) * static_cast<uint64_t>(cfg.draws_per_frame))
              << ",\"async_swapchain\":true"
              << "}\n";
    std::cout.flush();

    backbuffer->Release();
    if (end_event_query) end_event_query->Release();
    if (cb) cb->Release();
    if (vb) vb->Release();
    if (input_layout) input_layout->Release();
    if (vs1) vs1->Release();
    if (ps1) ps1->Release();
    if (vs2) vs2->Release();
    if (ps2) ps2->Release();
    if (sampler) sampler->Release();
    if (srv_a) srv_a->Release();
    if (tex_a) tex_a->Release();
    if (srv_b) srv_b->Release();
    if (tex_b) tex_b->Release();
    if (depth_dsv) depth_dsv->Release();
    if (depth_tex) depth_tex->Release();
    if (scene_srv) scene_srv->Release();
    if (scene_rtv) scene_rtv->Release();
    if (scene_tex) scene_tex->Release();
    if (backbuffer_rtv) backbuffer_rtv->Release();
    if (adapter3) adapter3->Release();
    if (adapter1) adapter1->Release();
    if (adapter) adapter->Release();
    if (dxgi_device) dxgi_device->Release();
    if (swapchain) swapchain->Release();
    if (ctx) ctx->Release();
    if (device) device->Release();
    if (marker_socket != INVALID_SOCKET) { closesocket(marker_socket); WSACleanup(); }
    SetThreadExecutionState(ES_CONTINUOUS);
    DestroyWindow(hwnd);
    return 0;
}
