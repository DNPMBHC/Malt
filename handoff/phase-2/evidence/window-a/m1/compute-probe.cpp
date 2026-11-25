// SPDX-License-Identifier: GPL-3.0-or-later
// Guest-owned explicit compute probe. Contributor: @DNPMBHC.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t kMaximumFrame = 65536;
constexpr uint32_t kMaximumValues = 4096;
struct Options {
  std::string host, nonce;
  uint16_t port = 0;
  uint64_t requestID = 1;
  uint32_t operation = 1, deadlineMs = 5000, socketTimeoutMs = 10000;
  int64_t scale = 3, bias = -7;
  std::vector<int32_t> values = {0, 1, -1, 2147483647, -2147483647};
};
void append32(std::vector<uint8_t>& out, uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8) out.push_back(static_cast<uint8_t>(value >> shift));
}
void append64(std::vector<uint8_t>& out, uint64_t value) {
  for (int shift = 56; shift >= 0; shift -= 8) out.push_back(static_cast<uint8_t>(value >> shift));
}
uint64_t checksum(const std::vector<int64_t>& values) {
  uint64_t hash = UINT64_C(14695981039346656037);
  for (int64_t value : values) {
    uint64_t bits = static_cast<uint64_t>(value);
    for (int shift = 56; shift >= 0; shift -= 8) {
      hash = (hash ^ static_cast<uint8_t>(bits >> shift)) * UINT64_C(1099511628211);
    }
  }
  return hash;
}
struct Reader {
  const std::vector<uint8_t>& bytes;
  size_t offset = 0;
  uint64_t integer(size_t size) {
    if (size > bytes.size() - offset) throw std::runtime_error("invalid response frame");
    uint64_t value = 0;
    for (size_t index = 0; index < size; ++index) value = (value << 8) | bytes[offset++];
    return value;
  }
  std::string nonce() {
    if (64 > bytes.size() - offset) throw std::runtime_error("invalid response nonce");
    std::string value(bytes.begin() + offset, bytes.begin() + offset + 64);
    offset += 64;
    return value;
  }
};
uint64_t unsignedNumber(const std::string& value, uint64_t maximum) {
  if (value.empty() || value[0] == '-') throw std::runtime_error("invalid unsigned argument");
  size_t consumed = 0;
  const uint64_t number = std::stoull(value, &consumed);
  if (consumed != value.size() || number > maximum) throw std::runtime_error("argument outside limit");
  return number;
}
int64_t signedNumber(const std::string& value) {
  size_t consumed = 0;
  const int64_t number = std::stoll(value, &consumed);
  if (consumed != value.size()) throw std::runtime_error("invalid integer argument");
  return number;
}
Options parse(int argc, char** argv) {
  Options options;
  for (int index = 1; index < argc; ++index) {
    const std::string key = argv[index];
    if (++index >= argc) throw std::runtime_error("missing argument value");
    const std::string value = argv[index];
    if (key == "--host") options.host = value;
    else if (key == "--port") options.port = static_cast<uint16_t>(unsignedNumber(value, 65535));
    else if (key == "--nonce") options.nonce = value;
    else if (key == "--request-id") options.requestID = unsignedNumber(value, UINT64_MAX);
    else if (key == "--deadline-ms") options.deadlineMs = static_cast<uint32_t>(unsignedNumber(value, UINT32_MAX));
    else if (key == "--socket-timeout-ms") options.socketTimeoutMs = static_cast<uint32_t>(unsignedNumber(value, 60000));
    else if (key == "--scale") options.scale = signedNumber(value);
    else if (key == "--bias") options.bias = signedNumber(value);
    else if (key == "--operation") {
      if (value == "affine") options.operation = 1;
      else if (value == "reject") options.operation = 2;
      else throw std::runtime_error("unsupported operation argument");
    } else if (key == "--values") {
      options.values.clear();
      std::stringstream stream(value);
      std::string item;
      while (std::getline(stream, item, ',')) {
        int64_t number = signedNumber(item);
        if (number < INT32_MIN || number > INT32_MAX || options.values.size() >= kMaximumValues)
          throw std::runtime_error("input outside limit");
        options.values.push_back(static_cast<int32_t>(number));
      }
    } else throw std::runtime_error("unknown argument");
  }
  if (options.host.empty() || options.port == 0 || options.nonce.size() != 64 ||
      options.deadlineMs == 0 || options.socketTimeoutMs == 0)
    throw std::runtime_error("invalid endpoint or deadline");
  for (char value : options.nonce)
    if (!((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f')))
      throw std::runtime_error("invalid nonce");
  return options;
}
void sendAll(SOCKET socket, const std::vector<uint8_t>& bytes) {
  size_t offset = 0;
  while (offset < bytes.size()) {
    int sent = send(socket, reinterpret_cast<const char*>(bytes.data() + offset),
                    static_cast<int>(bytes.size() - offset), 0);
    if (sent <= 0) throw std::runtime_error("transport send failed");
    offset += static_cast<size_t>(sent);
  }
}
std::vector<uint8_t> receive(SOCKET socket, size_t size) {
  std::vector<uint8_t> bytes(size);
  size_t offset = 0;
  while (offset < size) {
    int count = recv(socket, reinterpret_cast<char*>(bytes.data() + offset),
                     static_cast<int>(size - offset), 0);
    if (count <= 0) throw std::runtime_error("transport receive failed");
    offset += static_cast<size_t>(count);
  }
  return bytes;
}
SOCKET connectTo(const Options& options) {
  addrinfo hints{}, *addresses = nullptr;
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_protocol = IPPROTO_TCP;
  const std::string service = std::to_string(options.port);
  if (getaddrinfo(options.host.c_str(), service.c_str(), &hints, &addresses) != 0)
    throw std::runtime_error("endpoint resolution failed");
  SOCKET socket = INVALID_SOCKET;
  for (addrinfo* item = addresses; item; item = item->ai_next) {
    socket = ::socket(item->ai_family, item->ai_socktype, item->ai_protocol);
    if (socket == INVALID_SOCKET) continue;
    DWORD timeout = options.socketTimeoutMs;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof(timeout));
    u_long nonblocking = 1;
    if (ioctlsocket(socket, FIONBIO, &nonblocking) != 0) {
      closesocket(socket);
      socket = INVALID_SOCKET;
      continue;
    }
    bool connected = connect(socket, item->ai_addr, static_cast<int>(item->ai_addrlen)) == 0;
    if (!connected && WSAGetLastError() == WSAEWOULDBLOCK) {
      fd_set writable, failed;
      FD_ZERO(&writable); FD_ZERO(&failed);
      FD_SET(socket, &writable); FD_SET(socket, &failed);
      timeval limit{static_cast<long>(options.socketTimeoutMs / 1000),
                    static_cast<long>((options.socketTimeoutMs % 1000) * 1000)};
      if (select(0, nullptr, &writable, &failed, &limit) > 0 && FD_ISSET(socket, &writable)) {
        int socketError = 0, errorLength = sizeof(socketError);
        connected = getsockopt(socket, SOL_SOCKET, SO_ERROR,
                               reinterpret_cast<char*>(&socketError), &errorLength) == 0 && socketError == 0;
      }
    }
    nonblocking = 0;
    if (connected && ioctlsocket(socket, FIONBIO, &nonblocking) == 0) break;
    closesocket(socket);
    socket = INVALID_SOCKET;
  }
  freeaddrinfo(addresses);
  if (socket == INVALID_SOCKET) throw std::runtime_error("endpoint connection failed");
  return socket;
}
std::string guestArchitecture() {
  using IsWow64Process2Function = BOOL(WINAPI*)(HANDLE, USHORT*, USHORT*);
  const FARPROC address = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2");
  IsWow64Process2Function function = nullptr;
  static_assert(sizeof(function) == sizeof(address), "function pointer size differs");
  std::memcpy(&function, &address, sizeof(function));
  USHORT processMachine = 0, nativeMachine = 0;
  if (!function || !function(GetCurrentProcess(), &processMachine, &nativeMachine)) return "unknown";
  if (nativeMachine == 0xAA64) return "arm64";
  if (nativeMachine == 0x8664) return "x86_64";
  return "other";
}
std::string processArchitecture() {
#if defined(__aarch64__) || defined(_M_ARM64)
  return "arm64";
#elif defined(__x86_64__) || defined(_M_X64)
  return "x86_64";
#else
  return "other";
#endif
}
int run(const Options& options, SOCKET socket) {
  std::vector<uint8_t> body;
  append32(body, 1); append32(body, 1); append64(body, options.requestID);
  body.insert(body.end(), options.nonce.begin(), options.nonce.end());
  append32(body, options.operation); append32(body, options.deadlineMs);
  append32(body, static_cast<uint32_t>(options.values.size()));
  append64(body, static_cast<uint64_t>(options.scale)); append64(body, static_cast<uint64_t>(options.bias));
  for (int32_t value : options.values) append32(body, static_cast<uint32_t>(value));
  std::vector<uint8_t> frame;
  append32(frame, static_cast<uint32_t>(body.size()));
  frame.insert(frame.end(), body.begin(), body.end());
  sendAll(socket, frame);
  auto prefix = receive(socket, 4);
  Reader header{prefix};
  const uint32_t length = static_cast<uint32_t>(header.integer(4));
  if (length == 0 || length > kMaximumFrame) throw std::runtime_error("response exceeds limit");
  auto bytes = receive(socket, length);
  Reader reader{bytes};
  if (reader.integer(4) != 1 || reader.integer(4) != 2) throw std::runtime_error("wrong response version");
  if (reader.integer(8) != options.requestID || reader.nonce() != options.nonce)
    throw std::runtime_error("response correlation failed");
  const uint32_t status = static_cast<uint32_t>(reader.integer(4));
  const uint32_t errorCode = static_cast<uint32_t>(reader.integer(4));
  const uint32_t count = static_cast<uint32_t>(reader.integer(4));
  const uint64_t expectedChecksum = reader.integer(8);
  if (count > kMaximumValues || status < 1 || status > 4) throw std::runtime_error("invalid response state");
  std::vector<int64_t> values;
  for (uint32_t index = 0; index < count; ++index) values.push_back(static_cast<int64_t>(reader.integer(8)));
  if (reader.offset != bytes.size() || checksum(values) != expectedChecksum)
    throw std::runtime_error("response checksum failed");
  bool consistent = status != 1;
  if (status == 1) {
    consistent = values.size() == options.values.size() && errorCode == 0;
    for (size_t index = 0; consistent && index < options.values.size(); ++index) {
      int64_t product = 0, expected = 0;
      if (__builtin_mul_overflow(static_cast<int64_t>(options.values[index]), options.scale, &product) ||
          __builtin_add_overflow(product, options.bias, &expected) || values[index] != expected)
        consistent = false;
    }
  } else if (errorCode == 0 || !values.empty()) {
    throw std::runtime_error("failure response contains invalid data");
  }
  const char* names[] = {"unknown", "succeeded", "timedOut", "cancelled", "failed"};
  DWORD session = 0;
  ProcessIdToSessionId(GetCurrentProcessId(), &session);
  std::cout << "{\"schemaVersion\":1,\"scope\":\"explicitComputeInterfaceOnly\","
               "\"transparentPEMigration\":false,\"requestID\":" << options.requestID
            << ",\"targetPID\":" << GetCurrentProcessId() << ",\"sessionID\":" << session
            << ",\"guestArchitecture\":\"" << guestArchitecture()
            << "\",\"probeArchitecture\":\"" << processArchitecture()
            << "\",\"status\":\"" << names[status] << "\",\"errorCode\":" << errorCode
            << ",\"dataConsistent\":" << (consistent ? "true" : "false")
            << ",\"checksum\":" << expectedChecksum << ",\"values\":[";
  for (size_t index = 0; index < values.size(); ++index) {
    if (index) std::cout << ',';
    std::cout << values[index];
  }
  std::cout << "]}" << std::endl;
  if (!consistent) return 24;
  if (status == 1) return 0;
  if (status == 2) return 20;
  if (status == 3) return 21;
  return 22;
}
}  // namespace
int main(int argc, char** argv) {
  SOCKET socket = INVALID_SOCKET;
  bool ready = false;
  try {
    const Options options = parse(argc, argv);
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) throw std::runtime_error("transport initialization failed");
    ready = true;
    socket = connectTo(options);
    const int result = run(options, socket);
    closesocket(socket);
    WSACleanup();
    return result;
  } catch (const std::exception& error) {
    if (socket != INVALID_SOCKET) closesocket(socket);
    if (ready) WSACleanup();
    std::cout << "{\"schemaVersion\":1,\"scope\":\"explicitComputeInterfaceOnly\","
                 "\"transparentPEMigration\":false,\"status\":\"transportOrProtocolFailure\","
                 "\"dataConsistent\":false,\"message\":\"" << error.what() << "\"}" << std::endl;
    return 23;
  }
}
