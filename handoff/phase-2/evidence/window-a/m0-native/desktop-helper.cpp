// SPDX-License-Identifier: GPL-3.0-or-later
// Maintainer: @DNPMBHC
// A Session 0 controller and a same-session desktop relay. No shell interpreter.
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <wtsapi32.h>
#include <userenv.h>
#include <sddl.h>
#include <aclapi.h>
#include <shlobj.h>
#include <stdint.h>
#include <stdio.h>
#include <string>
#include <vector>
#include <algorithm>
#include <stdexcept>
#include "exit-resolution.hpp"

namespace {
constexpr size_t kManifestLimit = 16384;
constexpr size_t kOutputLimit = 16384;
constexpr size_t kFrameLimit = 2 * kOutputLimit + 4096;
constexpr DWORD kStartupMs = 20000;
constexpr DWORD kCancelExit = 0xC000013A;

struct Handle {
  HANDLE h = nullptr;
  Handle() = default;
  explicit Handle(HANDLE value) : h(value) {}
  ~Handle() { reset(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : h(other.h) { other.h = nullptr; }
  Handle& operator=(Handle&& other) noexcept {
    if (this != &other) { reset(); h = other.h; other.h = nullptr; }
    return *this;
  }
  void reset(HANDLE value = nullptr) {
    if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h);
    h = value;
  }
  explicit operator bool() const { return h && h != INVALID_HANDLE_VALUE; }
};
struct Failure : std::exception {
  std::string code;
  DWORD win32;
  Failure(std::string value, DWORD error = GetLastError()) : code(std::move(value)), win32(error) {}
};
struct Manifest {
  std::wstring executable;
  std::vector<std::wstring> arguments;
  std::vector<std::pair<std::wstring, std::wstring>> environment;
};
enum State : uint32_t { Starting = 0, Running = 1, Exited = 2, Failed = 3 };
struct Record {
  uint32_t formatVersion = 5;
  State state = Starting;
  DWORD controller = 0, target = 0, session = 0, exitCode = 0, rootExitCode = 0, win32 = 0;
  uint64_t controllerCreated = 0, targetCreated = 0, targetJobHandle = 0, controllerTargetJobHandle = 0;
  bool outTruncated = false, errTruncated = false, cancelled = false, rootExited = false, launchSuppressed = false;
  DWORD activeProcessCount = 0;
  std::string error, out, err;
};

uint64_t filetime(FILETIME value) {
  return (uint64_t(value.dwHighDateTime) << 32) | value.dwLowDateTime;
}
uint64_t creation(HANDLE process) {
  FILETIME start{}, end{}, kernel{}, user{};
  if (!GetProcessTimes(process, &start, &end, &kernel, &user)) throw Failure("processIdentityUnavailable");
  return filetime(start);
}
std::wstring utf16(const std::string& text) {
  if (text.find('\0') != std::string::npos) throw Failure("invalidRequest", ERROR_INVALID_DATA);
  if (text.empty()) return {};
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), nullptr, 0);
  if (!count) throw Failure("invalidUTF8", ERROR_INVALID_DATA);
  std::wstring result(size_t(count), L'\0');
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), result.data(), count)) {
    throw Failure("invalidUTF8", ERROR_INVALID_DATA);
  }
  return result;
}
std::string ascii(const std::wstring& text) {
  std::string result;
  for (wchar_t ch : text) {
    if (ch > 127) throw Failure("invalidRequest", ERROR_INVALID_DATA);
    result.push_back(char(ch));
  }
  return result;
}
std::string base64(const std::string& data) {
  static const char* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string result;
  result.reserve((data.size() + 2) / 3 * 4);
  for (size_t i = 0; i < data.size(); i += 3) {
    uint32_t value = uint32_t(uint8_t(data[i])) << 16;
    if (i + 1 < data.size()) value |= uint32_t(uint8_t(data[i + 1])) << 8;
    if (i + 2 < data.size()) value |= uint8_t(data[i + 2]);
    result += alphabet[(value >> 18) & 63]; result += alphabet[(value >> 12) & 63];
    result += i + 1 < data.size() ? alphabet[(value >> 6) & 63] : '=';
    result += i + 2 < data.size() ? alphabet[value & 63] : '=';
  }
  return result;
}
std::string unbase64(const std::wstring& encoded, size_t limit) {
  auto text = ascii(encoded);
  if (text.size() % 4 || text.size() > (limit + 2) / 3 * 4) throw Failure("invalidRequest", ERROR_INVALID_DATA);
  std::string output;
  auto digit = [](char ch) -> int {
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
    if (ch >= '0' && ch <= '9') return ch - '0' + 52;
    if (ch == '+') return 62;
    if (ch == '/') return 63;
    return -1;
  };
  for (size_t i = 0; i < text.size(); i += 4) {
    int a = digit(text[i]), b = digit(text[i + 1]);
    int c = text[i + 2] == '=' ? 0 : digit(text[i + 2]);
    int d = text[i + 3] == '=' ? 0 : digit(text[i + 3]);
    bool padC = text[i + 2] == '=', padD = text[i + 3] == '=';
    if (a < 0 || b < 0 || c < 0 || d < 0 || (padC && !padD) ||
        ((padC || padD) && i + 4 != text.size()) || (padC && (b & 15)) || (padD && !padC && (c & 3))) {
      throw Failure("invalidRequest", ERROR_INVALID_DATA);
    }
    uint32_t value = (uint32_t(a) << 18) | (uint32_t(b) << 12) | (uint32_t(c) << 6) | uint32_t(d);
    output.push_back(char(value >> 16));
    if (!padC) output.push_back(char(value >> 8));
    if (!padD) output.push_back(char(value));
  }
  if (output.size() > limit) throw Failure("requestTooLarge", ERROR_BUFFER_OVERFLOW);
  return output;
}
void put32(std::string& bytes, uint32_t value) {
  for (int i = 0; i < 4; ++i) bytes.push_back(char(value >> (8 * i)));
}
void put64(std::string& bytes, uint64_t value) {
  for (int i = 0; i < 8; ++i) bytes.push_back(char(value >> (8 * i)));
}
void putText(std::string& bytes, const std::string& text) { put32(bytes, uint32_t(text.size())); bytes += text; }
struct Reader {
  const std::string& bytes;
  size_t position = 0;
  uint32_t u32() {
    if (bytes.size() - position < 4) throw Failure("invalidRequest", ERROR_INVALID_DATA);
    uint32_t value = 0;
    for (int i = 0; i < 4; ++i) value |= uint32_t(uint8_t(bytes[position++])) << (8 * i);
    return value;
  }
  uint64_t u64() { uint64_t low = u32(); return low | (uint64_t(u32()) << 32); }
  std::string text(size_t limit) {
    auto count = u32();
    if (count > limit || count > bytes.size() - position) throw Failure("invalidRequest", ERROR_INVALID_DATA);
    auto result = bytes.substr(position, count); position += count; return result;
  }
};
Manifest parseManifest(const std::wstring& encoded) {
  auto bytes = unbase64(encoded, kManifestLimit);
  if (bytes.size() < 4 || bytes.substr(0, 4) != "MBD1") throw Failure("invalidRequest", ERROR_INVALID_DATA);
  Reader reader{bytes, 4};
  Manifest result;
  result.executable = utf16(reader.text(kManifestLimit));
  if (result.executable.empty() || result.executable.size() < 3 || result.executable[1] != L':' ||
      (result.executable[2] != L'\\' && result.executable[2] != L'/')) {
    throw Failure("executableMustBeAbsolute", ERROR_INVALID_PARAMETER);
  }
  auto argc = reader.u32();
  if (argc > 1024) throw Failure("invalidRequest", ERROR_INVALID_DATA);
  for (uint32_t i = 0; i < argc; ++i) result.arguments.push_back(utf16(reader.text(kManifestLimit)));
  auto envc = reader.u32();
  if (envc > 256) throw Failure("invalidRequest", ERROR_INVALID_DATA);
  for (uint32_t i = 0; i < envc; ++i) {
    auto key = utf16(reader.text(kManifestLimit)), value = utf16(reader.text(kManifestLimit));
    if (key.empty() || key.find(L'=') != std::wstring::npos) throw Failure("invalidEnvironment", ERROR_INVALID_DATA);
    if (std::any_of(result.environment.begin(), result.environment.end(), [&](const auto& item) {
      return _wcsicmp(item.first.c_str(), key.c_str()) == 0;
    })) throw Failure("duplicateEnvironment", ERROR_INVALID_DATA);
    result.environment.emplace_back(key, value);
  }
  if (reader.position != bytes.size()) throw Failure("invalidRequest", ERROR_INVALID_DATA);
  return result;
}
std::wstring quote(const std::wstring& value) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t ch : value) {
    if (ch == L'\\') { ++slashes; continue; }
    if (ch == L'\"') result.append(slashes * 2 + 1, L'\\');
    else result.append(slashes, L'\\');
    slashes = 0; result += ch;
  }
  result.append(slashes * 2, L'\\'); result += L'\"';
  return result;
}
std::wstring command(const std::wstring& executable, const std::vector<std::wstring>& args) {
  std::wstring result = quote(executable);
  for (const auto& arg : args) result += L" " + quote(arg);
  if (result.size() >= 32767) throw Failure("requestTooLarge", ERROR_BUFFER_OVERFLOW);
  return result;
}
void validateID(const std::wstring& identifier) {
  if (identifier.size() != 36) throw Failure("invalidRequestID", ERROR_INVALID_PARAMETER);
  for (size_t i = 0; i < identifier.size(); ++i) {
    auto ch = identifier[i];
    bool dash = i == 8 || i == 13 || i == 18 || i == 23;
    if (dash ? ch != L'-' : !((ch >= L'0' && ch <= L'9') || (ch >= L'a' && ch <= L'f') || (ch >= L'A' && ch <= L'F'))) {
      throw Failure("invalidRequestID", ERROR_INVALID_PARAMETER);
    }
  }
}
std::wstring ownPath() {
  std::vector<wchar_t> buffer(32768);
  auto size = GetModuleFileNameW(nullptr, buffer.data(), DWORD(buffer.size()));
  if (!size || size >= buffer.size()) throw Failure("helperPathUnavailable");
  return std::wstring(buffer.data(), size);
}
std::wstring rootPath() {
  PWSTR path = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_ProgramData, 0, nullptr, &path))) throw Failure("storageUnavailable", ERROR_PATH_NOT_FOUND);
  std::wstring result(path); CoTaskMemFree(path);
  return result + L"\\demo-app";
}
bool reparse(const std::wstring& path) {
  auto flags = GetFileAttributesW(path.c_str());
  return flags != INVALID_FILE_ATTRIBUTES && (flags & FILE_ATTRIBUTE_REPARSE_POINT);
}
void secureDirectory(const std::wstring& path, bool requireNew = false) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
      L"O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1, &descriptor, nullptr)) throw Failure("storageSecurityUnavailable");
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), descriptor, FALSE};
  BOOL created = CreateDirectoryW(path.c_str(), &attributes);
  DWORD error = GetLastError();
  if (!created && (error != ERROR_ALREADY_EXISTS || requireNew)) {
    LocalFree(descriptor); throw Failure(requireNew ? "duplicateRequest" : "storageUnavailable", error);
  }
  if (reparse(path)) { LocalFree(descriptor); throw Failure("storageReparseRejected", ERROR_ACCESS_DENIED); }
  // A pre-created user-owned directory must not retain an owner's ability to rewrite its DACL.
  PSID owner = nullptr; PSECURITY_DESCRIPTOR existing = nullptr;
  DWORD ownerStatus = GetNamedSecurityInfoW(path.c_str(), SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
      &owner, nullptr, nullptr, nullptr, &existing);
  BYTE systemSID[SECURITY_MAX_SID_SIZE]{}, adminSID[SECURITY_MAX_SID_SIZE]{};
  DWORD systemBytes = sizeof(systemSID), adminBytes = sizeof(adminSID);
  bool trustedOwner = ownerStatus == ERROR_SUCCESS && owner &&
      CreateWellKnownSid(WinLocalSystemSid, nullptr, systemSID, &systemBytes) &&
      CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr, adminSID, &adminBytes) &&
      (EqualSid(owner, systemSID) || EqualSid(owner, adminSID));
  if (existing) LocalFree(existing);
  if (!trustedOwner) { LocalFree(descriptor); throw Failure("storageOwnerRejected", ERROR_ACCESS_DENIED); }
  BOOL present = FALSE, inherited = FALSE; PACL acl = nullptr;
  if (!GetSecurityDescriptorDacl(descriptor, &present, &acl, &inherited)) {
    LocalFree(descriptor); throw Failure("storageSecurityUnavailable");
  }
  DWORD status = SetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, acl, nullptr);
  LocalFree(descriptor);
  if (status != ERROR_SUCCESS) throw Failure("storageSecurityUnavailable", status);
}
std::wstring directory(const std::wstring& id, bool create) {
  auto base = rootPath(), sessions = base + L"\\sessions", result = sessions + L"\\" + id;
  if (create) { secureDirectory(base); secureDirectory(sessions); secureDirectory(result); }
  else if (reparse(base) || reparse(sessions) || reparse(result)) throw Failure("storageReparseRejected", ERROR_ACCESS_DENIED);
  return result;
}
Handle requestLock(const std::wstring& dir, DWORD timeoutMs = kStartupMs) {
  auto started = GetTickCount64();
  for (;;) {
    Handle lock(CreateFileW((dir + L"\\request.lock").c_str(), GENERIC_READ | GENERIC_WRITE,
        0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (lock) return lock;
    DWORD error = GetLastError();
    if (error != ERROR_SHARING_VIOLATION || GetTickCount64() - started >= timeoutMs) {
      throw Failure("requestLockUnavailable", error);
    }
    Sleep(10);
  }
}
bool cancellationRequested(const std::wstring& dir) {
  return GetFileAttributesW((dir + L"\\cancel.flag").c_str()) != INVALID_FILE_ATTRIBUTES;
}
std::string serialize(const Record& value) {
  std::string bytes = "MBS5";
  put32(bytes, value.state); put32(bytes, value.controller); put32(bytes, value.target);
  put32(bytes, value.session); put32(bytes, value.exitCode); put32(bytes, value.rootExitCode); put32(bytes, value.win32);
  put64(bytes, value.controllerCreated); put64(bytes, value.targetCreated);
  put64(bytes, value.targetJobHandle); put64(bytes, value.controllerTargetJobHandle);
  put32(bytes, (value.outTruncated ? 1 : 0) | (value.errTruncated ? 2 : 0) | (value.cancelled ? 4 : 0) | (value.rootExited ? 8 : 0) | (value.launchSuppressed ? 16 : 0));
  put32(bytes, value.activeProcessCount);
  putText(bytes, value.error); putText(bytes, value.out); putText(bytes, value.err);
  return bytes;
}
Record deserialize(const std::string& bytes) {
  if (bytes.size() < 4 || (bytes.substr(0, 4) != "MBS1" && bytes.substr(0, 4) != "MBS2" && bytes.substr(0, 4) != "MBS3" && bytes.substr(0, 4) != "MBS4" && bytes.substr(0, 4) != "MBS5")) throw Failure("invalidRelayFrame", ERROR_INVALID_DATA);
  bool version5 = bytes.substr(0, 4) == "MBS5", version4 = version5 || bytes.substr(0, 4) == "MBS4";
  bool version3 = version4 || bytes.substr(0, 4) == "MBS3";
  bool version2 = version3 || bytes.substr(0, 4) == "MBS2";
  Reader r{bytes, 4}; Record value;
  value.formatVersion = version5 ? 5 : version4 ? 4 : version3 ? 3 : version2 ? 2 : 1;
  uint32_t state = r.u32(); if (state > Failed) throw Failure("invalidRelayFrame", ERROR_INVALID_DATA);
  value.state = State(state); value.controller = r.u32(); value.target = r.u32(); value.session = r.u32();
  value.exitCode = r.u32(); value.rootExitCode = version2 ? r.u32() : value.exitCode;
  value.win32 = r.u32(); value.controllerCreated = r.u64(); value.targetCreated = r.u64();
  value.targetJobHandle = version3 ? r.u64() : 0;
  value.controllerTargetJobHandle = version4 ? r.u64() : 0;
  auto flags = r.u32(); value.outTruncated = flags & 1; value.errTruncated = flags & 2; value.cancelled = flags & 4;
  value.rootExited = flags & 8; value.launchSuppressed = flags & 16; value.activeProcessCount = r.u32();
  if (!version2 && value.state == Exited && value.cancelled) value.exitCode = ERROR_CANCELLED;
  value.error = r.text(256); value.out = r.text(kOutputLimit); value.err = r.text(kOutputLimit);
  if (r.position != bytes.size()) throw Failure("invalidRelayFrame", ERROR_INVALID_DATA);
  return value;
}
void save(const std::wstring& dir, const Record& record) {
  std::wstring destination = dir + L"\\record.bin", temporary = dir + L"\\record-next.bin";
  auto bytes = serialize(record);
  Handle file(CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (!file) throw Failure("storageWriteFailed");
  DWORD written = 0;
  if (!WriteFile(file.h, bytes.data(), DWORD(bytes.size()), &written, nullptr) || written != bytes.size()) throw Failure("storageWriteFailed");
  if (!FlushFileBuffers(file.h)) throw Failure("storageWriteFailed");
  file.reset();
  if (!MoveFileExW(temporary.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) throw Failure("storageWriteFailed");
}
Record load(const std::wstring& dir) {
  Handle file(CreateFileW((dir + L"\\record.bin").c_str(), GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (!file) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND) {
      Record value; value.error = "requestNotReady"; return value;
    }
    throw Failure("storageReadFailed");
  }
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file.h, &size) || size.QuadPart < 0 || size.QuadPart > LONGLONG(kFrameLimit)) throw Failure("invalidStatus", ERROR_INVALID_DATA);
  std::string bytes(size_t(size.QuadPart), '\0'); DWORD read = 0;
  if (!ReadFile(file.h, bytes.data(), DWORD(bytes.size()), &read, nullptr) || read != bytes.size()) throw Failure("storageReadFailed");
  return deserialize(bytes);
}
std::string jsonEscape(const std::string& value) {
  std::string result = "\"";
  for (unsigned char ch : value) {
    if (ch == '"' || ch == '\\') { result += '\\'; result += char(ch); }
    else if (ch < 32) { char buffer[7]; snprintf(buffer, sizeof(buffer), "\\u%04x", ch); result += buffer; }
    else result += char(ch);
  }
  return result + "\"";
}
std::string json(const std::wstring& id, const Record& r) {
  const char* states[] = {"starting", "running", "exited", "failed"};
  return "{\"schemaVersion\":1,\"requestID\":" + jsonEscape(ascii(id)) +
      ",\"controllerPID\":" + std::to_string(r.controller) + ",\"targetPID\":" + std::to_string(r.target) +
      ",\"sessionID\":" + std::to_string(r.session) + ",\"state\":\"" + states[r.state] +
      "\",\"exitCode\":" + (r.state == Exited ? std::to_string(int32_t(r.exitCode)) : "null") +
      ",\"stdoutBase64\":\"" + base64(r.out) + "\",\"stderrBase64\":\"" + base64(r.err) +
      "\",\"error\":" + (r.error.empty() ? "null" : jsonEscape(r.error)) +
      ",\"win32Error\":" + std::to_string(r.win32) +
      ",\"stdoutTruncated\":" + (r.outTruncated ? "true" : "false") +
      ",\"stderrTruncated\":" + (r.errTruncated ? "true" : "false") +
      ",\"cancelled\":" + (r.cancelled ? "true" : "false") +
      ",\"launchSuppressed\":" + (r.launchSuppressed ? "true" : "false") +
      ",\"rootExited\":" + (r.rootExited ? "true" : "false") +
      ",\"rootExitCode\":" + (r.rootExited ? std::to_string(int32_t(r.rootExitCode)) : "null") +
      ",\"activeProcessCount\":" + std::to_string(r.activeProcessCount) +
      ",\"targetCreationTime\":\"" + std::to_string(r.targetCreated) + "\"}";
}
void output(const std::wstring& id, const Record& value) {
  auto line = json(id, value); fwrite(line.data(), 1, line.size(), stdout); fputc('\n', stdout); fflush(stdout);
}
void privilege(const wchar_t* name) {
  Handle token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token.h)) throw Failure("privilegeUnavailable");
  TOKEN_PRIVILEGES privileges{}; privileges.PrivilegeCount = 1;
  if (!LookupPrivilegeValueW(nullptr, name, &privileges.Privileges[0].Luid)) throw Failure("privilegeUnavailable");
  privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
  SetLastError(ERROR_SUCCESS);
  if (!AdjustTokenPrivileges(token.h, FALSE, &privileges, 0, nullptr, nullptr) || GetLastError() == ERROR_NOT_ALL_ASSIGNED) {
    throw Failure("privilegeUnavailable", ERROR_PRIVILEGE_NOT_HELD);
  }
}
DWORD activeSession() {
  PWTS_SESSION_INFOW sessions = nullptr; DWORD count = 0, chosen = DWORD(-1), active = 0;
  if (!WTSEnumerateSessionsW(WTS_CURRENT_SERVER_HANDLE, 0, 1, &sessions, &count)) throw Failure("desktopQueryFailed");
  for (DWORD i = 0; i < count; ++i) {
    if (!sessions[i].SessionId || sessions[i].State != WTSActive) continue;
    LPWSTR user = nullptr; DWORD length = 0;
    if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, sessions[i].SessionId, WTSUserName, &user, &length)) {
      if (user && user[0]) { chosen = sessions[i].SessionId; ++active; }
      WTSFreeMemory(user);
    }
  }
  WTSFreeMemory(sessions);
  if (active != 1) throw Failure(active ? "ambiguousDesktop" : "noInteractiveDesktop", ERROR_NOT_FOUND);
  LPWSTR info = nullptr; DWORD bytes = 0;
  if (!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, chosen, WTSSessionInfoEx, &info, &bytes)) throw Failure("desktopQueryFailed");
  bool locked = true;
  if (bytes >= sizeof(WTSINFOEXW)) {
    auto extended = reinterpret_cast<WTSINFOEXW*>(info);
    locked = extended->Level != 1 || extended->Data.WTSInfoExLevel1.SessionFlags != WTS_SESSIONSTATE_UNLOCK;
  }
  WTSFreeMemory(info);
  if (locked) throw Failure("desktopLocked", ERROR_ACCESS_DENIED);
  return chosen;
}
std::wstring sidFor(HANDLE token) {
  DWORD bytes = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
  std::vector<uint8_t> buffer(bytes);
  if (!bytes || !GetTokenInformation(token, TokenUser, buffer.data(), bytes, &bytes)) throw Failure("userTokenUnavailable");
  LPWSTR text = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &text)) throw Failure("userTokenUnavailable");
  std::wstring result(text); LocalFree(text); return result;
}
Handle job() {
  Handle result(CreateJobObjectW(nullptr, nullptr));
  if (!result) throw Failure("jobUnavailable");
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{}; limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(result.h, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) throw Failure("jobUnavailable");
  return result;
}
DWORD activeProcesses(HANDLE targetJob) {
  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting{};
  if (!QueryInformationJobObject(targetJob, JobObjectBasicAccountingInformation, &accounting, sizeof(accounting), nullptr)) {
    throw Failure("jobStatusUnavailable");
  }
  return accounting.ActiveProcesses;
}
bool live(DWORD pid, uint64_t created) {
  if (!pid || !created) return false;
  Handle process(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid));
  if (!process) return false;
  try { return creation(process.h) == created && WaitForSingleObject(process.h, 0) == WAIT_TIMEOUT; }
  catch (...) { return false; }
}
void writeFrame(HANDLE pipe, const Record& value) {
  std::string bytes; auto body = serialize(value); put32(bytes, uint32_t(body.size())); bytes += body;
  DWORD written = 0;
  if (!WriteFile(pipe, bytes.data(), DWORD(bytes.size()), &written, nullptr) || written != bytes.size()) throw Failure("controllerDisconnected");
}
void controllerCommand(HANDLE pipe, char command) {
  DWORD written = 0; OVERLAPPED overlap{};
  Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  if (!event) throw Failure("channelUnavailable");
  overlap.hEvent = event.h;
  if (!WriteFile(pipe, &command, 1, &written, &overlap)) {
    DWORD error = GetLastError();
    if (error != ERROR_IO_PENDING) throw Failure("controllerWriteFailed", error);
    if (WaitForSingleObject(event.h, 1000) != WAIT_OBJECT_0) {
      CancelIoEx(pipe, &overlap); GetOverlappedResult(pipe, &overlap, &written, TRUE);
      throw Failure("controllerWriteTimeout", ERROR_TIMEOUT);
    }
    if (!GetOverlappedResult(pipe, &overlap, &written, FALSE)) throw Failure("controllerWriteFailed");
  }
  if (written != 1) throw Failure("controllerWriteFailed", ERROR_WRITE_FAULT);
}
void capture(HANDLE pipe, std::string& target, bool& truncated) {
  size_t drained = 0;
  for (;;) {
    DWORD available = 0;
    if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) {
      if (GetLastError() == ERROR_BROKEN_PIPE) return;
      throw Failure("outputReadFailed");
    }
    if (!available) return;
    char buffer[4096]; DWORD count = 0;
    if (!ReadFile(pipe, buffer, std::min<DWORD>(sizeof(buffer), available), &count, nullptr)) {
      if (GetLastError() == ERROR_BROKEN_PIPE) return;
      throw Failure("outputReadFailed");
    }
    if (!count) throw Failure("outputReadFailed", ERROR_READ_FAULT);
    auto retained = std::min<size_t>(count, kOutputLimit - target.size());
    target.append(buffer, retained); if (retained != count) truncated = true;
    drained += count;
    // A continuous-output child must not starve cancellation or process-tree accounting.
    if (drained >= 65536) return;
  }
}
std::vector<wchar_t> environmentBlock(const Manifest& manifest) {
  Handle token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE, &token.h)) throw Failure("environmentUnavailable");
  LPVOID raw = nullptr;
  if (!CreateEnvironmentBlock(&raw, token.h, FALSE)) throw Failure("environmentUnavailable");
  std::vector<std::wstring> entries;
  for (const wchar_t* p = static_cast<const wchar_t*>(raw); *p; p += wcslen(p) + 1) entries.emplace_back(p);
  DestroyEnvironmentBlock(raw);
  for (const auto& pair : manifest.environment) {
    auto prefix = pair.first + L"=";
    entries.erase(std::remove_if(entries.begin(), entries.end(), [&](const auto& item) {
      return _wcsnicmp(item.c_str(), prefix.c_str(), prefix.size()) == 0;
    }), entries.end());
    entries.push_back(prefix + pair.second);
  }
  std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) { return _wcsicmp(a.c_str(), b.c_str()) < 0; });
  std::vector<wchar_t> result;
  for (const auto& item : entries) { result.insert(result.end(), item.begin(), item.end()); result.push_back(L'\0'); }
  result.push_back(L'\0'); if (result.size() == 1) result.push_back(L'\0');
  if (result.size() > 32767) throw Failure("environmentTooLarge", ERROR_BUFFER_OVERFLOW);
  return result;
}
void checkInputDesktop() {
  HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop) throw Failure("desktopLocked");
  wchar_t name[128]{}; DWORD needed = 0;
  BOOL read = GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &needed);
  CloseDesktop(desktop);
  if (!read || _wcsicmp(name, L"Default")) throw Failure("desktopLocked", ERROR_ACCESS_DENIED);
}
int relay(const std::wstring&, const std::wstring& encoded, const std::wstring& pipeName, DWORD expectedController) {
  Handle pipe;
  auto start = GetTickCount64();
  while (GetTickCount64() - start < kStartupMs) {
    pipe.reset(CreateFileW(pipeName.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr));
    if (pipe) break;
    if (GetLastError() != ERROR_PIPE_BUSY && GetLastError() != ERROR_FILE_NOT_FOUND) return 2;
    Sleep(25);
  }
  if (!pipe) return 2;
  ULONG server = 0;
  if (!GetNamedPipeServerProcessId(pipe.h, &server) || server != expectedController) return 2;
  Record record; record.controller = expectedController;
  Handle process, targetJob;
  try {
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &record.session) || !record.session) throw Failure("relaySessionMismatch", ERROR_ACCESS_DENIED);
    checkInputDesktop();
    auto manifest = parseManifest(encoded);
    auto cmdline = command(manifest.executable, manifest.arguments);
    auto environment = environmentBlock(manifest);
    SECURITY_ATTRIBUTES inherit{sizeof(inherit), nullptr, TRUE};
    Handle outRead, outWrite, errRead, errWrite;
    if (!CreatePipe(&outRead.h, &outWrite.h, &inherit, 0) || !CreatePipe(&errRead.h, &errWrite.h, &inherit, 0)) throw Failure("outputPipeUnavailable");
    if (!SetHandleInformation(outRead.h, HANDLE_FLAG_INHERIT, 0) || !SetHandleInformation(errRead.h, HANDLE_FLAG_INHERIT, 0)) throw Failure("outputPipeUnavailable");
    Handle input(CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &inherit, OPEN_EXISTING, 0, nullptr));
    if (!input) throw Failure("inputUnavailable");
    STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.StartupInfo.lpDesktop = const_cast<wchar_t*>(L"winsta0\\default");
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdOutput = outWrite.h; startup.StartupInfo.hStdError = errWrite.h; startup.StartupInfo.hStdInput = input.h;
    SIZE_T attributeBytes = 0; InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeBytes);
    std::vector<uint8_t> attributes(attributeBytes);
    startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
    if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributeBytes)) throw Failure("processAttributesUnavailable");
    HANDLE allowed[] = {outWrite.h, errWrite.h, input.h};
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, allowed, sizeof(allowed), nullptr, nullptr)) {
      DeleteProcThreadAttributeList(startup.lpAttributeList); throw Failure("processAttributesUnavailable");
    }
    targetJob = job();
    record.targetJobHandle = uint64_t(reinterpret_cast<uintptr_t>(targetJob.h));
    PROCESS_INFORMATION info{};
    auto separator = manifest.executable.find_last_of(L"\\/");
    auto workingDirectory = manifest.executable.substr(0, separator);
    BOOL spawned = CreateProcessW(manifest.executable.c_str(), cmdline.data(), nullptr, nullptr, TRUE,
        CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
        environment.data(), workingDirectory.c_str(), &startup.StartupInfo, &info);
    DWORD spawnError = GetLastError(); DeleteProcThreadAttributeList(startup.lpAttributeList);
    if (!spawned) throw Failure(spawnError == ERROR_ELEVATION_REQUIRED ? "elevationRequired" : "targetLaunchFailed", spawnError);
    process.reset(info.hProcess); Handle thread(info.hThread);
    record.target = info.dwProcessId; record.targetCreated = creation(process.h);
    if (!AssignProcessToJobObject(targetJob.h, process.h)) { TerminateProcess(process.h, kCancelExit); throw Failure("jobAssignmentFailed"); }
    record.activeProcessCount = activeProcesses(targetJob.h);
    // The real target exists suspended; only an authenticated controller grant may resume it.
    record.state = Starting; writeFrame(pipe.h, record);
    char grant = 0; auto grantStart = GetTickCount64();
    for (;;) {
      DWORD available = 0;
      if (!PeekNamedPipe(pipe.h, nullptr, 0, nullptr, &available, nullptr)) throw Failure("controllerDisconnected");
      if (available) {
        DWORD got = 0;
        if (!ReadFile(pipe.h, &grant, 1, &got, nullptr) || got != 1 || (grant != 'R' && grant != 'C')) {
          throw Failure("invalidControllerFrame", ERROR_INVALID_DATA);
        }
        break;
      }
      if (GetTickCount64() - grantStart >= kStartupMs) throw Failure("resumeGrantTimeout", ERROR_TIMEOUT);
      Sleep(10);
    }
    if (grant == 'C') {
      record.cancelled = true;
      if (!TerminateJobObject(targetJob.h, kCancelExit)) throw Failure("cancelFailed");
    } else if (ResumeThread(thread.h) == DWORD(-1)) throw Failure("targetResumeFailed");
    outWrite.reset(); errWrite.reset(); input.reset();
    record.state = Running; writeFrame(pipe.h, record);
    auto lastFrame = GetTickCount64();
    for (;;) {
      capture(outRead.h, record.out, record.outTruncated); capture(errRead.h, record.err, record.errTruncated);
      DWORD available = 0;
      if (!PeekNamedPipe(pipe.h, nullptr, 0, nullptr, &available, nullptr)) throw Failure("controllerDisconnected");
      if (available) {
        char code = 0; DWORD got = 0;
        if (!ReadFile(pipe.h, &code, 1, &got, nullptr) || got != 1 || code != 'C') throw Failure("invalidControllerFrame", ERROR_INVALID_DATA);
        if (!record.cancelled) {
          record.cancelled = true;
          if (!TerminateJobObject(targetJob.h, kCancelExit)) throw Failure("cancelFailed");
        }
      }
      auto wait = WaitForSingleObject(process.h, 10);
      if (wait == WAIT_OBJECT_0 && !record.rootExited) {
        if (!GetExitCodeProcess(process.h, &record.rootExitCode)) throw Failure("targetExitUnavailable");
        record.rootExited = true;
      }
      if (wait == WAIT_FAILED) throw Failure("targetWaitFailed");
      record.activeProcessCount = activeProcesses(targetJob.h);
      // Installers and launchers may exit while their legitimate children keep running.
      // A normal root exit does not close the job or terminate those children.
      if (record.rootExited && !record.activeProcessCount) break;
      if (GetTickCount64() - lastFrame >= 100) { writeFrame(pipe.h, record); lastFrame = GetTickCount64(); }
      if (record.rootExited) Sleep(10);
    }
    // The job is empty naturally (or after an explicit cancel); it is safe to close now.
    targetJob.reset();
    Sleep(20); capture(outRead.h, record.out, record.outTruncated); capture(errRead.h, record.err, record.errTruncated);
    record.exitCode = record.cancelled ? ERROR_CANCELLED : record.rootExitCode;
    record.state = Exited; writeFrame(pipe.h, record);
    // Retain the real target HANDLE until the controller validates its identity and exit code.
    auto acknowledgedAt = GetTickCount64();
    while (GetTickCount64() - acknowledgedAt < 5000) {
      DWORD available = 0;
      if (!PeekNamedPipe(pipe.h, nullptr, 0, nullptr, &available, nullptr)) break;
      if (available) {
        char acknowledgement = 0; DWORD got = 0;
        if (!ReadFile(pipe.h, &acknowledgement, 1, &got, nullptr) || !got) break;
        if (acknowledgement == 'A') break;
      }
      Sleep(10);
    }
    return 0;
  } catch (const Failure& failure) {
    if (targetJob) TerminateJobObject(targetJob.h, kCancelExit);
    if (process) WaitForSingleObject(process.h, 3000);
    record.state = Failed; record.error = failure.code; record.win32 = failure.win32;
    try { writeFrame(pipe.h, record); } catch (...) {}
    return 2;
  }
}
int launch(const std::wstring& id, const std::wstring& encoded) {
  Record record; record.controller = GetCurrentProcessId(); record.controllerCreated = creation(GetCurrentProcess());
  std::wstring dir;
  Handle controllerJob, relayProcess, targetProcess, verifiedTargetJob;
  bool ownsRecord = false;
  try {
    auto manifest = parseManifest(encoded); (void)manifest;
    dir = directory(id, true);
    {
      auto lock = requestLock(dir);
      auto existing = load(dir);
      if (existing.launchSuppressed && existing.cancelled && !existing.target && cancellationRequested(dir)) {
        output(id, existing); return 0;
      }
      if (existing.controller || existing.state != Starting || existing.error != "requestNotReady") {
        throw Failure("duplicateRequest", ERROR_ALREADY_EXISTS);
      }
      if (cancellationRequested(dir)) {
        record.state = Failed; record.error = "launchCancelled"; record.win32 = ERROR_CANCELLED;
        record.cancelled = true; record.launchSuppressed = true; save(dir, record);
        output(id, record); return 0;
      }
      save(dir, record); ownsRecord = true;
    }
    DWORD ownSession = 0;
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &ownSession) || ownSession != 0) throw Failure("controllerMustRunInSessionZero", ERROR_ACCESS_DENIED);
    record.session = activeSession(); save(dir, record);
    privilege(SE_TCB_NAME); privilege(SE_ASSIGNPRIMARYTOKEN_NAME); privilege(SE_INCREASE_QUOTA_NAME);
    Handle userToken, primaryToken;
    if (!WTSQueryUserToken(record.session, &userToken.h) || !DuplicateTokenEx(userToken.h, MAXIMUM_ALLOWED, nullptr,
        SecurityImpersonation, TokenPrimary, &primaryToken.h)) throw Failure("userTokenUnavailable");
    auto sid = sidFor(primaryToken.h);
    auto sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;" + sid + L")";
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) throw Failure("channelSecurityUnavailable");
    SECURITY_ATTRIBUTES security{sizeof(security), descriptor, FALSE};
    auto pipeName = L"\\\\.\\pipe\\demo-app-" + id;
    Handle pipe(CreateNamedPipeW(pipeName.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, DWORD(kFrameLimit + 4), 64, 0, &security));
    LocalFree(descriptor);
    if (!pipe) throw Failure("channelUnavailable");
    Handle connected(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!connected) throw Failure("channelUnavailable");
    OVERLAPPED overlap{}; overlap.hEvent = connected.h;
    BOOL immediate = ConnectNamedPipe(pipe.h, &overlap); DWORD connectError = immediate ? ERROR_SUCCESS : GetLastError();
    if (!immediate && connectError != ERROR_IO_PENDING && connectError != ERROR_PIPE_CONNECTED) throw Failure("channelUnavailable", connectError);
    if (immediate || connectError == ERROR_PIPE_CONNECTED) SetEvent(connected.h);
    controllerJob = job();
    auto helper = ownPath(), cmdline = command(helper, {L"relay", id, encoded, pipeName, std::to_wstring(record.controller)});
    STARTUPINFOW startup{}; startup.cb = sizeof(startup); startup.lpDesktop = const_cast<wchar_t*>(L"winsta0\\default");
    PROCESS_INFORMATION info{}; LPVOID userEnvironment = nullptr;
    if (!CreateEnvironmentBlock(&userEnvironment, primaryToken.h, FALSE)) throw Failure("environmentUnavailable");
    auto spawnLock = requestLock(dir);
    if (cancellationRequested(dir)) { DestroyEnvironmentBlock(userEnvironment); throw Failure("launchCancelled", ERROR_CANCELLED); }
    BOOL spawned = CreateProcessAsUserW(primaryToken.h, helper.c_str(), cmdline.data(), nullptr, nullptr, FALSE,
        CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED | CREATE_NO_WINDOW, userEnvironment, nullptr, &startup, &info);
    DWORD spawnError = GetLastError(); DestroyEnvironmentBlock(userEnvironment);
    if (!spawned) throw Failure("relayLaunchFailed", spawnError);
    relayProcess.reset(info.hProcess); Handle thread(info.hThread);
    if (!AssignProcessToJobObject(controllerJob.h, relayProcess.h)) { TerminateProcess(relayProcess.h, kCancelExit); throw Failure("jobAssignmentFailed"); }
    if (ResumeThread(thread.h) == DWORD(-1)) throw Failure("relayResumeFailed");
    spawnLock.reset();
    HANDLE waits[] = {connected.h, relayProcess.h};
    auto wait = WaitForMultipleObjects(2, waits, FALSE, kStartupMs);
    if (wait != WAIT_OBJECT_0) { CancelIoEx(pipe.h, &overlap); throw Failure(wait == WAIT_TIMEOUT ? "desktopStartupTimeout" : "relayExitedBeforeReady", ERROR_TIMEOUT); }
    DWORD connectedBytes = 0;
    if (connectError == ERROR_IO_PENDING && !GetOverlappedResult(pipe.h, &overlap, &connectedBytes, FALSE)) throw Failure("channelUnavailable");
    ULONG client = 0;
    if (!GetNamedPipeClientProcessId(pipe.h, &client) || client != info.dwProcessId) throw Failure("relayIdentityMismatch", ERROR_ACCESS_DENIED);
    std::string buffered;
    auto started = GetTickCount64(); uint64_t cancelAt = 0; bool cancellationSent = false;
    for (;;) {
      if (!cancellationSent && cancellationRequested(dir)) {
        record.cancelled = true;
        // Do not let a cancellation terminate the suspended root before its actual Job is bound.
        if (verifiedTargetJob) {
          cancellationSent = true; cancelAt = GetTickCount64(); controllerCommand(pipe.h, 'C');
        }
      }
      DWORD available = 0;
      BOOL peeked = PeekNamedPipe(pipe.h, nullptr, 0, nullptr, &available, nullptr);
      if (peeked && available) {
        char bytes[4096]; DWORD read = 0; OVERLAPPED readOverlap{};
        Handle readEvent(CreateEventW(nullptr, TRUE, FALSE, nullptr)); readOverlap.hEvent = readEvent.h;
        if (!ReadFile(pipe.h, bytes, std::min<DWORD>(sizeof(bytes), available), &read, &readOverlap)) {
          if (GetLastError() != ERROR_IO_PENDING || WaitForSingleObject(readEvent.h, 1000) != WAIT_OBJECT_0 ||
              !GetOverlappedResult(pipe.h, &readOverlap, &read, FALSE)) {
            CancelIoEx(pipe.h, &readOverlap); throw Failure("relayDisconnected");
          }
        }
        buffered.append(bytes, read);
        while (buffered.size() >= 4) {
          Reader length{buffered}; auto size = length.u32();
          if (size > kFrameLimit) throw Failure("invalidRelayFrame", ERROR_INVALID_DATA);
          if (buffered.size() < size + 4) break;
          auto next = deserialize(buffered.substr(4, size)); buffered.erase(0, size + 4);
          if (next.controllerTargetJobHandle || next.controller != record.controller || next.session != record.session ||
              (record.target && (next.target != record.target || next.targetCreated != record.targetCreated ||
                                next.targetJobHandle != record.targetJobHandle))) {
            throw Failure("targetIdentityMismatch", ERROR_ACCESS_DENIED);
          }
          if (next.target && !targetProcess) {
            targetProcess.reset(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, next.target));
            DWORD session = 0;
            if (!targetProcess || creation(targetProcess.h) != next.targetCreated ||
                !ProcessIdToSessionId(next.target, &session) || session != record.session) {
              throw Failure("targetIdentityMismatch", ERROR_ACCESS_DENIED);
            }
          }
          if (next.target && !verifiedTargetJob) {
            if (next.state != Starting || !next.targetJobHandle || next.targetJobHandle > UINTPTR_MAX ||
                !DuplicateHandle(relayProcess.h, reinterpret_cast<HANDLE>(uintptr_t(next.targetJobHandle)),
                    GetCurrentProcess(), &verifiedTargetJob.h, JOB_OBJECT_QUERY | JOB_OBJECT_TERMINATE, FALSE, 0)) {
              throw Failure("targetJobBindingFailed");
            }
            BOOL belongs = FALSE;
            if (!IsProcessInJob(targetProcess.h, verifiedTargetJob.h, &belongs) || !belongs) {
              throw Failure("targetJobMembershipMismatch", ERROR_INVALID_DATA);
            }
          }
          next.controllerCreated = record.controllerCreated;
          next.controllerTargetJobHandle = uint64_t(reinterpret_cast<uintptr_t>(verifiedTargetJob.h));
          if (next.state == Starting && next.target) {
            auto lock = requestLock(dir);
            bool cancelledBeforeResume = cancellationRequested(dir);
            next.cancelled = next.cancelled || cancelledBeforeResume;
            // MBS5 startup barrier: persist the real target binding under the cancellation
            // lock before granting either resume or cancellation. A locked target-zero
            // authority snapshot therefore proves no target has been authorized to run.
            record = next; save(dir, record);
            if (cancelledBeforeResume) {
              if (!cancellationSent) {
                cancellationSent = true; cancelAt = GetTickCount64(); controllerCommand(pipe.h, 'C');
              }
            } else controllerCommand(pipe.h, 'R');
          }
          if (next.state == Exited) {
            auto finalLock = requestLock(dir);
            // Resolve from the relay's untouched flag/code pair. The broker may have observed a
            // cancellation after the relay finished naturally but before this final frame arrived.
            auto resolution = desktop_protocol::resolveRelayExit(
                next.exitCode, next.rootExitCode, next.cancelled, record.cancelled || cancellationRequested(dir));
            DWORD actualExit = 0;
            if (!next.rootExited || next.activeProcessCount != 0 || !targetProcess || WaitForSingleObject(targetProcess.h, 3000) != WAIT_OBJECT_0 ||
                !GetExitCodeProcess(targetProcess.h, &actualExit) || actualExit != next.rootExitCode ||
                !resolution.valid) {
              throw Failure("targetExitMismatch", ERROR_INVALID_DATA);
            }
            if (!verifiedTargetJob) throw Failure("targetJobBindingMissing", ERROR_INVALID_DATA);
            auto treeWait = GetTickCount64();
            while (activeProcesses(verifiedTargetJob.h) != 0 && GetTickCount64() - treeWait < 3000) Sleep(10);
            if (activeProcesses(verifiedTargetJob.h) != 0) throw Failure("targetTreeExitMismatch", ERROR_INVALID_DATA);
            next.cancelled = resolution.cancelled; next.exitCode = resolution.sessionExitCode;
            record = std::move(next); save(dir, record);
            finalLock.reset();
            char acknowledgement = 'A'; DWORD written = 0; OVERLAPPED ack{};
            Handle ackEvent(CreateEventW(nullptr, TRUE, FALSE, nullptr)); ack.hEvent = ackEvent.h;
            if (!WriteFile(pipe.h, &acknowledgement, 1, &written, &ack) && GetLastError() == ERROR_IO_PENDING) {
              if (WaitForSingleObject(ackEvent.h, 1000) == WAIT_OBJECT_0) GetOverlappedResult(pipe.h, &ack, &written, FALSE);
              else { CancelIoEx(pipe.h, &ack); GetOverlappedResult(pipe.h, &ack, &written, TRUE); }
            }
            output(id, record); return 0;
          }
          next.cancelled = next.cancelled || record.cancelled;
          record = std::move(next); save(dir, record);
          if (record.state == Failed) { output(id, record); return 0; }
        }
      }
      if (!peeked || WaitForSingleObject(relayProcess.h, 0) == WAIT_OBJECT_0) {
        // Drain frames written immediately before relay exit before declaring a fault.
        DWORD left = 0;
        if (!PeekNamedPipe(pipe.h, nullptr, 0, nullptr, &left, nullptr) || !left) throw Failure("relayDisconnected");
      }
      if (record.state == Starting && GetTickCount64() - started >= kStartupMs) throw Failure("desktopStartupTimeout", ERROR_TIMEOUT);
      if (cancellationSent && GetTickCount64() - cancelAt >= 5000) throw Failure("cancelAcknowledgementTimeout", ERROR_TIMEOUT);
      Sleep(10);
    }
  } catch (const Failure& failure) {
    if (verifiedTargetJob) TerminateJobObject(verifiedTargetJob.h, kCancelExit);
    if (controllerJob) TerminateJobObject(controllerJob.h, kCancelExit);
    if (relayProcess) WaitForSingleObject(relayProcess.h, 3000);
    if (targetProcess) WaitForSingleObject(targetProcess.h, 3000);
    record.state = Failed; record.error = failure.code; record.win32 = failure.win32;
    if (failure.code == "launchCancelled") { record.cancelled = true; record.launchSuppressed = !record.target; }
    if (!dir.empty() && ownsRecord) { try { save(dir, record); } catch (...) {} }
    output(id, record); return 0;
  }
}
Record status(const std::wstring& id) {
  auto dir = directory(id, false);
  auto value = load(dir);
  if ((value.state == Running || value.state == Starting) && value.controller && !live(value.controller, value.controllerCreated)) {
    // The broker commits its terminal record before exiting. An active snapshot can become
    // stale between load() and live(); reread authority before declaring controller loss.
    auto refreshed = load(dir);
    if (refreshed.controller != value.controller || refreshed.controllerCreated != value.controllerCreated ||
        (value.target && refreshed.target != value.target) ||
        (value.targetCreated && refreshed.targetCreated != value.targetCreated) ||
        (value.session && refreshed.session != value.session) ||
        (value.targetJobHandle && refreshed.targetJobHandle != value.targetJobHandle) ||
        (value.controllerTargetJobHandle && refreshed.controllerTargetJobHandle != value.controllerTargetJobHandle)) {
      throw Failure("statusIdentityMismatch", ERROR_INVALID_DATA);
    }
    value = std::move(refreshed);
    if (value.state == Exited || value.state == Failed) return value;
    value.state = Failed; value.error = "controllerExited"; value.win32 = ERROR_BROKEN_PIPE;
    // Closing the controller's kill-on-close job terminates the entire guest process tree.
  }
  return value;
}
// Emergency cleanup is independent of QGA PID-result caches. It never opens or kills a
// target by an unauthenticated bare PID and never equates a broker exit with tree completion.
int forceCancel(const std::wstring& id) {
  Record value;
  std::wstring dir;
  Handle lock, controller, target, targetJob;
  bool controllerVerified = false, controllerExited = false, controllerAbsent = false;
  bool rootVerified = false, rootExited = false, jobVerified = false, jobEmpty = false;
  DWORD cleanupError = ERROR_TIMEOUT;
  const auto cleanupStarted = GetTickCount64();
  auto remaining = [&]() -> DWORD {
    auto elapsed = GetTickCount64() - cleanupStarted;
    return elapsed >= 5000 ? 0 : DWORD(5000 - elapsed);
  };
  try {
    dir = directory(id, true); value = load(dir);
    lock = requestLock(dir, remaining()); value = load(dir);
    if (value.state == Exited) { output(id, value); return 0; }
    Handle flag(CreateFileW((dir + L"\\cancel.flag").c_str(), GENERIC_WRITE, FILE_SHARE_READ,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!flag || !FlushFileBuffers(flag.h)) throw Failure("cleanupUnconfirmed");
    flag.reset();
    value.cancelled = true;
    if (!value.controller) {
      value.state = Failed; value.error = "launchCancelled"; value.win32 = ERROR_CANCELLED;
      value.launchSuppressed = true; save(dir, value); output(id, value); return 0;
    }
    if (!value.controllerCreated) throw Failure("cleanupUnconfirmed", ERROR_INVALID_DATA);
    controller.reset(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION |
        PROCESS_DUP_HANDLE | PROCESS_TERMINATE, FALSE, value.controller));
    if (!controller) {
      // ERROR_INVALID_PARAMETER means this PID has no process object. Access denial or
      // another lookup failure cannot prove the original broker is gone.
      if (GetLastError() != ERROR_INVALID_PARAMETER) throw Failure("cleanupUnconfirmed");
      controllerAbsent = true; controllerExited = true;
    } else if (creation(controller.h) != value.controllerCreated) {
      // A reused PID belongs to a different process. The old broker is gone; never kill
      // the new process and never duplicate a handle from its unrelated handle table.
      controllerAbsent = true; controllerExited = true; controller.reset();
    } else {
      controllerVerified = true;
      controllerExited = WaitForSingleObject(controller.h, 0) == WAIT_OBJECT_0;
    }
    if (!value.target) {
      if (controllerVerified && !controllerExited) {
        if (!TerminateProcess(controller.h, kCancelExit)) cleanupError = GetLastError();
        controllerExited = WaitForSingleObject(controller.h, remaining()) == WAIT_OBJECT_0;
      }
      if (controllerExited) {
        auto refreshed = load(dir);
        if (refreshed.controller != value.controller || refreshed.controllerCreated != value.controllerCreated ||
            (value.session && refreshed.session != value.session)) {
          throw Failure("cleanupUnconfirmed", ERROR_INVALID_DATA);
        }
        // MBS5 persists every target before granting R under this same held lock. Older
        // records are accepted only for explicit failures that precede relay creation.
        bool legacyPreTargetFailure = refreshed.state == Failed &&
            (refreshed.error == "noInteractiveDesktop" || refreshed.error == "ambiguousDesktop" ||
             refreshed.error == "desktopLocked" || refreshed.error == "desktopQueryFailed" ||
             refreshed.error == "controllerMustRunInSessionZero" || refreshed.error == "userTokenUnavailable" ||
             refreshed.error == "privilegeUnavailable");
        bool neverAuthorizedTarget = !refreshed.target && !refreshed.targetCreated &&
            !refreshed.targetJobHandle && !refreshed.controllerTargetJobHandle &&
            (refreshed.formatVersion >= 5 || legacyPreTargetFailure);
        value = std::move(refreshed);
        if (neverAuthorizedTarget) {
          value.state = Failed; value.error = "launchCancelled"; value.win32 = ERROR_CANCELLED;
          value.cancelled = true; value.launchSuppressed = true; value.rootExited = false;
          value.activeProcessCount = 0; save(dir, value); output(id, value); return 0;
        }
      }
    }
    if (!controllerVerified || !controller || controllerAbsent) throw Failure("cleanupUnconfirmed", ERROR_INVALID_DATA);
    // Retain the exact target handle before terminating the broker. PID reuse cannot
    // retarget it, and the protected authority record binds the broker's live Job handle.
    if (value.target && value.targetCreated) {
      target.reset(OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, value.target));
      DWORD session = 0;
      rootVerified = target && creation(target.h) == value.targetCreated &&
          ProcessIdToSessionId(value.target, &session) && session == value.session;
      if (!rootVerified) target.reset();
    }
    if (rootVerified && value.controllerTargetJobHandle && value.controllerTargetJobHandle <= UINTPTR_MAX &&
        DuplicateHandle(controller.h, reinterpret_cast<HANDLE>(uintptr_t(value.controllerTargetJobHandle)),
            GetCurrentProcess(), &targetJob.h, JOB_OBJECT_QUERY | JOB_OBJECT_TERMINATE, FALSE, 0)) {
      // An exited root can have left accounting. Its authenticated suspended membership
      // was persisted by the broker; a currently live root must still belong to this Job.
      BOOL belongs = FALSE;
      auto rootWait = WaitForSingleObject(target.h, 0);
      jobVerified = rootWait == WAIT_OBJECT_0 ||
          (rootWait == WAIT_TIMEOUT && IsProcessInJob(target.h, targetJob.h, &belongs) && belongs);
      if (jobVerified) {
        (void)activeProcesses(targetJob.h);
        if (!TerminateJobObject(targetJob.h, kCancelExit)) cleanupError = GetLastError();
      }
    }
    if (WaitForSingleObject(controller.h, 0) == WAIT_OBJECT_0) controllerExited = true;
    else {
      if (!TerminateProcess(controller.h, kCancelExit)) cleanupError = GetLastError();
      controllerExited = WaitForSingleObject(controller.h, remaining()) == WAIT_OBJECT_0;
    }
    if (rootVerified && WaitForSingleObject(target.h, remaining()) == WAIT_OBJECT_0 &&
        GetExitCodeProcess(target.h, &value.rootExitCode)) {
      rootExited = true; value.rootExited = true;
    }
    if (jobVerified) {
      for (;;) {
        value.activeProcessCount = activeProcesses(targetJob.h);
        jobEmpty = value.activeProcessCount == 0;
        if (jobEmpty || !remaining()) break;
        Sleep(std::min<DWORD>(10, remaining()));
      }
    }
    value.outTruncated = true; value.errTruncated = true;
    if (controllerExited && rootVerified && rootExited && jobVerified && jobEmpty) {
      value.state = Exited; value.exitCode = ERROR_CANCELLED; value.win32 = 0; value.error.clear();
      value.cancelled = true; value.launchSuppressed = false; save(dir, value); output(id, value); return 0;
    }
  } catch (const Failure& failure) {
    cleanupError = failure.win32;
    // Only the previously authenticated broker handle is eligible for best-effort kill.
    // No PID-only controller or target termination occurs, including every reuse case.
    if (controllerVerified && controller && !controllerExited) {
      if (WaitForSingleObject(controller.h, 0) != WAIT_OBJECT_0) TerminateProcess(controller.h, kCancelExit);
      controllerExited = WaitForSingleObject(controller.h, remaining()) == WAIT_OBJECT_0;
    }
  }
  value.state = Failed; value.error = "cleanupUnconfirmed"; value.win32 = cleanupError;
  value.cancelled = true; value.outTruncated = true; value.errTruncated = true;
  if (controllerVerified && controllerExited && !dir.empty()) {
    try { save(dir, value); } catch (...) {}
  }
  output(id, value); return 0;
}
int cancel(const std::wstring& id) {
  auto dir = directory(id, true);
  Record value;
  {
    auto lock = requestLock(dir); value = load(dir);
    if (value.state == Exited || (value.state == Failed && value.controller)) { output(id, value); return 0; }
    Handle flag(CreateFileW((dir + L"\\cancel.flag").c_str(), GENERIC_WRITE, FILE_SHARE_READ,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (!flag) throw Failure("cancelFailed");
    if (!FlushFileBuffers(flag.h)) throw Failure("cancelPersistenceFailed");
    flag.reset();
    if (!value.controller) {
      value.state = Failed; value.error = "launchCancelled"; value.win32 = ERROR_CANCELLED;
      value.cancelled = true; value.launchSuppressed = true; save(dir, value);
      output(id, value); return 0;
    }
  }
  auto start = GetTickCount64();
  while (GetTickCount64() - start < 10000) {
    value = status(id);
    if (value.state == Exited || value.state == Failed) { output(id, value); return 0; }
    Sleep(25);
  }
  throw Failure("cancelAcknowledgementTimeout", ERROR_TIMEOUT);
}
int mkdir(const std::wstring& encoded) {
  auto path = utf16(unbase64(encoded, kManifestLimit));
  if (path.size() < 3 || path[1] != L':' || (path[2] != L'\\' && path[2] != L'/')) throw Failure("directoryMustBeAbsolute", ERROR_INVALID_PARAMETER);
  std::replace(path.begin(), path.end(), L'/', L'\\');
  size_t offset = 3;
  for (;;) {
    auto separator = path.find(L'\\', offset);
    auto part = separator == std::wstring::npos ? path : path.substr(0, separator);
    if (part.size() > 3 && !CreateDirectoryW(part.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) throw Failure("directoryCreateFailed");
    if (reparse(part)) throw Failure("directoryReparseRejected", ERROR_ACCESS_DENIED);
    auto flags = GetFileAttributesW(part.c_str());
    if (flags == INVALID_FILE_ATTRIBUTES || !(flags & FILE_ATTRIBUTE_DIRECTORY)) throw Failure("directoryUnavailable", ERROR_DIRECTORY);
    if (separator == std::wstring::npos) break;
    offset = separator + 1;
  }
  Record result; result.state = Exited; result.exitCode = 0; output(L"", result); return 0;
}
} // namespace

int wmain(int argc, wchar_t** argv) {
  std::wstring id;
  try {
    if (argc == 3 && std::wstring(argv[1]) == L"mkdir") return mkdir(argv[2]);
    if (argc < 3) throw Failure("invalidRequest", ERROR_INVALID_PARAMETER);
    id = argv[2]; validateID(id);
    auto mode = std::wstring(argv[1]);
    if (mode == L"launch" && argc == 4) return launch(id, argv[3]);
    if (mode == L"status" && argc == 3) { output(id, status(id)); return 0; }
    if (mode == L"cancel" && argc == 3) return cancel(id);
    if (mode == L"force-cancel" && argc == 3) return forceCancel(id);
    if (mode == L"relay" && argc == 6) {
      wchar_t* end = nullptr; unsigned long controller = wcstoul(argv[5], &end, 10);
      if (!controller || !end || *end) throw Failure("invalidRequest", ERROR_INVALID_PARAMETER);
      return relay(id, argv[3], argv[4], DWORD(controller));
    }
    throw Failure("invalidRequest", ERROR_INVALID_PARAMETER);
  } catch (const Failure& failure) {
    Record value; value.state = Failed; value.error = failure.code; value.win32 = failure.win32;
    try { output(id, value); } catch (...) { fputs("{\"schemaVersion\":1,\"state\":\"failed\",\"error\":\"invalidRequest\"}\n", stdout); }
    return 0;
  } catch (...) {
    fputs("{\"schemaVersion\":1,\"state\":\"failed\",\"error\":\"internalFailure\"}\n", stdout); return 0;
  }
}
