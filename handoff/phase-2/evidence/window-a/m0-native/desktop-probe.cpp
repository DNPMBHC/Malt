// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC
// Self-owned GUI and DXGI probe. Reports only synthetic arguments and one test variable.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dwmapi.h>
#include <stdint.h>
#include <stdio.h>
#include <string>
#include <vector>

namespace {
std::string utf8(const std::wstring& text) {
  if (text.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), int(text.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size_t(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), int(text.size()), result.data(), size, nullptr, nullptr);
  return result;
}
std::string escape(const std::wstring& text) {
  auto bytes = utf8(text); std::string value = "\"";
  for (unsigned char ch : bytes) {
    if (ch == '"' || ch == '\\') { value += '\\'; value += char(ch); }
    else if (ch < 32) { char buffer[7]; snprintf(buffer, sizeof(buffer), "\\u%04x", ch); value += buffer; }
    else value += char(ch);
  }
  return value + "\"";
}
LRESULT CALLBACK windowProcedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_COMMAND && LOWORD(wparam) == 1) {
    SetWindowTextW(GetDlgItem(window, 3), L"Synthetic step 2\nThe explicit GUI interaction reached this step.");
    return 0;
  }
  if (message == WM_COMMAND && LOWORD(wparam) == 2) { DestroyWindow(window); return 0; }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(window, message, wparam, lparam);
}
}
int wmain(int argc, wchar_t** argv) {
  bool gui = false, installer = false, requireElevation = false; DWORD sleepMs = 0, exitCode = 0, childSleepMs = 0, outputBytes = 0;
  for (int i = 1; i < argc; ++i) {
    if (std::wstring(argv[i]) == L"--gui") gui = true;
    if (std::wstring(argv[i]) == L"--installer") { gui = true; installer = true; }
    if (std::wstring(argv[i]) == L"--require-elevation") requireElevation = true;
    if (std::wstring(argv[i]) == L"--sleep-ms" && i + 1 < argc) sleepMs = DWORD(wcstoul(argv[++i], nullptr, 10));
    if (std::wstring(argv[i]) == L"--exit-code" && i + 1 < argc) exitCode = DWORD(wcstoul(argv[++i], nullptr, 10));
    if (std::wstring(argv[i]) == L"--spawn-child" && i + 1 < argc) childSleepMs = DWORD(wcstoul(argv[++i], nullptr, 10));
    if (std::wstring(argv[i]) == L"--output-bytes" && i + 1 < argc) outputBytes = DWORD(wcstoul(argv[++i], nullptr, 10));
  }
  DWORD session = 0; ProcessIdToSessionId(GetCurrentProcessId(), &session);
  HWND window = nullptr; ID3D11Device* device = nullptr; ID3D11DeviceContext* context = nullptr; IDXGISwapChain* chain = nullptr;
  HRESULT result = S_OK, presented = S_OK; bool visible = false; DWORD cloaked = 0;
  if (gui) {
    WNDCLASSW type{}; type.lpfnWndProc = windowProcedure; type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = L"DemoDesktopProbe"; type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClassW(&type);
    window = CreateWindowExW(0, type.lpszClassName, installer ? L"demo-app setup preview" : L"demo-app desktop probe", WS_OVERLAPPEDWINDOW,
        40, 40, 400, 280, nullptr, nullptr, type.hInstance, nullptr);
    if (window) {
      ShowWindow(window, SW_SHOW); UpdateWindow(window); visible = IsWindowVisible(window);
      if (installer) {
        CreateWindowW(L"STATIC", L"Synthetic installer preview\nNo software is installed by this probe.",
            WS_CHILD | WS_VISIBLE, 18, 16, 350, 42, window, reinterpret_cast<HMENU>(3), type.hInstance, nullptr);
        CreateWindowW(L"BUTTON", L"Next", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
            206, 182, 72, 28, window, reinterpret_cast<HMENU>(1), type.hInstance, nullptr);
        CreateWindowW(L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE,
            288, 182, 72, 28, window, reinterpret_cast<HMENU>(2), type.hInstance, nullptr);
      }
      DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
      DXGI_SWAP_CHAIN_DESC description{}; description.BufferDesc.Width = 320; description.BufferDesc.Height = 200;
      description.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; description.SampleDesc.Count = 1;
      description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; description.BufferCount = 1;
      description.OutputWindow = window; description.Windowed = TRUE; description.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
      D3D_FEATURE_LEVEL level{};
      result = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
          nullptr, 0, D3D11_SDK_VERSION, &description, &chain, &device, &level, &context);
      if (FAILED(result)) result = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
          D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION, &description, &chain, &device, &level, &context);
      if (SUCCEEDED(result) && chain) {
        ID3D11Texture2D* backBuffer = nullptr; ID3D11RenderTargetView* view = nullptr;
        if (SUCCEEDED(chain->GetBuffer(0, __uuidof(ID3D11Texture2D), reinterpret_cast<void**>(&backBuffer))) &&
            SUCCEEDED(device->CreateRenderTargetView(backBuffer, nullptr, &view))) {
          const FLOAT color[] = {0.12f, 0.36f, 0.66f, 1.0f}; context->ClearRenderTargetView(view, color);
        }
        if (view) view->Release();
        if (backBuffer) backBuffer->Release();
        presented = chain->Present(0, 0);
      }
    } else result = HRESULT_FROM_WIN32(GetLastError());
  }
  wchar_t environment[4096]{}; auto environmentLength = GetEnvironmentVariableW(L"DEMO_E2E_ENV", environment, 4096);
  std::wstring envValue = environmentLength < 4096 ? std::wstring(environment, environmentLength) : L"<oversize>";
  std::string args = "[";
  for (int i = 1; i < argc; ++i) { if (i > 1) args += ','; args += escape(argv[i]); } args += ']';
  bool elevated = false;
  HANDLE token = nullptr;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    TOKEN_ELEVATION value{}; DWORD bytes = 0;
    if (GetTokenInformation(token, TokenElevation, &value, sizeof(value), &bytes)) elevated = value.TokenIsElevated;
    CloseHandle(token);
  }
  PROCESS_INFORMATION child{}; DWORD childError = 0;
  if (childSleepMs) {
    wchar_t own[32768]{}; DWORD length = GetModuleFileNameW(nullptr, own, 32768);
    if (!length || length >= 32768) childError = ERROR_FILENAME_EXCED_RANGE;
    else {
      auto childCommand = L"\"" + std::wstring(own, length) + L"\" --child --sleep-ms " + std::to_wstring(childSleepMs);
      STARTUPINFOW startup{}; startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESTDHANDLES;
      startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE); startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
      startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
      if (!CreateProcessW(own, childCommand.data(), nullptr, nullptr, TRUE, CREATE_SUSPENDED | CREATE_NO_WINDOW,
          nullptr, nullptr, &startup, &child)) childError = GetLastError();
    }
  }
  auto report = "{\"probeSchemaVersion\":1,\"probeArchitecture\":\"x86_64\",\"processID\":" + std::to_string(GetCurrentProcessId()) +
      ",\"sessionID\":" + std::to_string(session) + ",\"windowVisible\":" + (visible ? "true" : "false") +
      ",\"windowCloaked\":" + std::to_string(cloaked) + ",\"swapChainCreated\":" + (chain ? "true" : "false") +
      ",\"installerPreviewVisible\":" + ((installer && visible) ? "true" : "false") +
      ",\"presentSucceeded\":" + ((chain && SUCCEEDED(presented)) ? "true" : "false") +
      ",\"hresult\":" + std::to_string(int32_t(result)) + ",\"arguments\":" + args +
      ",\"environment\":" + escape(envValue) + ",\"elevated\":" + (elevated ? "true" : "false") +
      ",\"spawnedChildPID\":" + std::to_string(child.dwProcessId) + ",\"childSpawnError\":" + std::to_string(childError) + "}";
  fwrite(report.data(), 1, report.size(), stdout); fputc('\n', stdout); fflush(stdout);
  if (child.hThread) { ResumeThread(child.hThread); CloseHandle(child.hThread); CloseHandle(child.hProcess); }
  if (outputBytes) {
    const std::string chunk(4096, 'x');
    while (outputBytes) {
      auto count = outputBytes < chunk.size() ? outputBytes : DWORD(chunk.size());
      fwrite(chunk.data(), 1, count, stdout); outputBytes -= count;
    }
    fputc('\n', stdout); fflush(stdout);
  }
  fputs("demo-app stderr marker\n", stderr); fflush(stderr);
  ULONGLONG started = GetTickCount64();
  bool closed = false;
  while (GetTickCount64() - started < sleepMs) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) { closed = true; break; }
      TranslateMessage(&message); DispatchMessageW(&message);
    }
    if (closed) break;
    Sleep(10);
  }
  if (chain) chain->Release();
  if (context) context->Release();
  if (device) device->Release();
  if (window && IsWindow(window)) DestroyWindow(window);
  if (requireElevation && !elevated) return 77;
  if (childError) return 78;
  if (gui && (!visible || FAILED(result) || FAILED(presented))) return 76;
  return int(exitCode);
}
