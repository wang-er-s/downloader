#ifndef DOWNLOADER_FILE_STORAGE_H_
#define DOWNLOADER_FILE_STORAGE_H_
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shlobj.h>
#include <shellapi.h>
#include <filesystem>
#include <string>
#include <vector>
#include <stdexcept>
#include <optional>
#include <memory>
#include <cstdint>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <cstring>

// Execution journal and phase decisions live in Dart. This boundary performs
// handle-verified filesystem operations and atomic no-replace publication.
namespace downloader_storage {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
inline const Value& At(const Map& map, const char* key) {
  static const Value empty;
  auto found = map.find(Value(key));
  return found == map.end() ? empty : found->second;
}
inline std::string Text(const Value& value) {
  auto text = std::get_if<std::string>(&value);
  if (!text) throw std::runtime_error("invalidInput");
  return *text;
}
inline int64_t Integer(const Value& value) {
  if (auto n = std::get_if<int64_t>(&value)) return *n;
  if (auto n = std::get_if<int32_t>(&value)) return *n;
  throw std::runtime_error("invalidInput");
}
inline std::wstring Wide(const std::string& text) {
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) throw std::runtime_error("invalidInput");
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}
inline std::string Utf8(const std::wstring& text) {
  int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size, nullptr, nullptr);
  return result;
}
[[noreturn]] inline void WinError() {
  switch (GetLastError()) {
    case ERROR_FILE_NOT_FOUND: case ERROR_PATH_NOT_FOUND: throw std::runtime_error("fileMissing");
    case ERROR_ACCESS_DENIED: throw std::runtime_error("permissionDenied");
    case ERROR_DISK_FULL: case ERROR_HANDLE_DISK_FULL: throw std::runtime_error("insufficientSpace");
    default: throw std::runtime_error("fileWriteFailure");
  }
}
struct Handle {
  HANDLE value;
  explicit Handle(HANDLE handle) : value(handle) { if (handle == INVALID_HANDLE_VALUE) WinError(); }
  ~Handle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  void Close() { auto handle = value; value = INVALID_HANDLE_VALUE; if (!CloseHandle(handle)) WinError(); }
};
struct Info { std::string identity; int64_t size; };
inline Info Inspect(HANDLE handle, bool directory = false) {
  BY_HANDLE_FILE_INFORMATION info{};
  if (!GetFileInformationByHandle(handle, &info)) WinError();
  if ((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) ||
      !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != directory) throw std::runtime_error("publicationUncertain");
  return {std::to_string(info.dwVolumeSerialNumber) + ":" + std::to_string(info.nFileIndexHigh) + ":" + std::to_string(info.nFileIndexLow) + ":" + std::to_string(info.ftCreationTime.dwHighDateTime) + ":" + std::to_string(info.ftCreationTime.dwLowDateTime),
      static_cast<int64_t>((static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow)};
}
inline Handle ReadHandle(const std::wstring& path, bool directory = false) {
  return Handle(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), nullptr));
}
inline std::optional<Info> Existing(const std::wstring& path) {
  auto raw = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (raw == INVALID_HANDLE_VALUE) {
    if (GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND) return std::nullopt;
    WinError();
  }
  Handle handle(raw); return Inspect(handle.value);
}
inline std::wstring Name(const Map& args, const char* key) {
  auto name = Text(At(args, key));
  if (name.empty() || name == "." || name == ".." || name.find_first_of("/\\:\0") != std::string::npos || name.back() == '.' || name.back() == ' ') throw std::runtime_error("invalidInput");
  return Wide(name);
}
inline Map Location(const std::wstring& path, const std::string& identity) {
  return {{Value("version"), Value(1)}, {Value("platform"), Value("windows")}, {Value("kind"), Value("path")}, {Value("locator"), Value(Utf8(path))}, {Value("identity"), Value(identity)}};
}
inline Value Pick(HWND window) {
  IFileOpenDialog* dialog = nullptr;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) throw std::runtime_error("directoryUnavailable");
  DWORD options = 0; dialog->GetOptions(&options); dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
  HRESULT shown = dialog->Show(window);
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { dialog->Release(); return Value(); }
  if (FAILED(shown)) { dialog->Release(); throw std::runtime_error("directoryUnavailable"); }
  IShellItem* item = nullptr; HRESULT selected = dialog->GetResult(&item); dialog->Release();
  if (FAILED(selected)) throw std::runtime_error("directoryUnavailable");
  PWSTR path = nullptr; HRESULT located = item->GetDisplayName(SIGDN_FILESYSPATH, &path); item->Release();
  if (FAILED(located)) throw std::runtime_error("directoryUnavailable");
  std::wstring directory(path); CoTaskMemFree(path);
  auto handle = ReadHandle(directory, true); Inspect(handle.value, true);
  return Value(Map{{Value("version"), Value(1)}, {Value("platform"), Value("windows")}, {Value("kind"), Value("userSelected")}, {Value("locator"), Value(Utf8(directory))}, {Value("displayName"), Value(Utf8(std::filesystem::path(directory).filename().wstring()))}});
}
inline Value HandleCall(const std::string& method, const Map& args, HWND window) {
  if (method == "pickDirectory") return Pick(window);
  if (method == "sourceInfo") {
    auto source = Wide(Text(At(args, "source")));
    auto handle = ReadHandle(source); auto info = Inspect(handle.value);
    if (info.size != Integer(At(args, "sourceLength"))) throw std::runtime_error("fileWriteFailure");
    return Value(Map{{Value("identity"), Value(info.identity)}});
  }
  auto location = std::get<Map>(At(args, "directory"));
  if (Text(At(location, "platform")) != "windows") throw std::runtime_error("invalidInput");
  std::wstring directory;
  auto kind = Text(At(location, "kind"));
  if (kind == "systemDownloads") {
    PWSTR known = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_Downloads, KF_FLAG_DEFAULT, nullptr, &known))) throw std::runtime_error("directoryUnavailable");
    directory = known; CoTaskMemFree(known); directory += L"\\Downloader";
  } else if (kind == "userSelected") { directory = Wide(Text(At(location, "locator"))); }
  else { throw std::runtime_error("invalidInput"); }
  if (!std::holds_alternative<std::monostate>(At(location, "subdirectory"))) directory += L"\\" + Name(location, "subdirectory");
  if (method == "resolveDirectory") {
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    if (error) throw std::runtime_error("directoryUnavailable");
  }
  // Hold the directory open without FILE_SHARE_DELETE while using child names;
  // an external rename cannot switch the verified parent underneath the call.
  Handle parent(CreateFileW(directory.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  auto parentInfo = Inspect(parent.value, true);
  if (method == "resolveDirectory") return Value(Map{{Value("locator"), Value(Utf8(directory))}, {Value("identity"), Value(parentInfo.identity)}});
  auto registered = std::get<Map>(At(args, "parent"));
  if (Text(At(registered, "identity")) != parentInfo.identity) throw std::runtime_error("publicationUncertain");
  auto temp = directory + L"\\" + Name(args, "temporaryName");
  auto final = directory + L"\\" + Name(args, "candidateName");
  auto expected = std::get_if<std::string>(&At(args, "identity"));
  auto length = Integer(At(args, "sourceLength"));
  auto owned = [&](const std::optional<Info>& value) { return value && expected && value->identity == *expected; };
  if (method == "recover") {
    auto temporary = Existing(temp); auto published = Existing(final); auto phase = Text(At(args, "phase"));
    std::string disposition = "uncertain"; Map result{{Value("version"), Value(1)}};
    if (owned(published) && published->size == length && (phase == "finalizing" || phase == "published" || phase == "cleaning")) {
      disposition = "published"; result[Value("ownedLocation")] = Value(Location(final, *expected));
    } else if (owned(temporary) && phase != "published") {
      disposition = "staged"; result[Value("ownedLocation")] = Value(Location(temp, *expected));
    } else if (!temporary && (phase == "prepared" || phase == "cleaning")) { disposition = "notCreated"; }
    result[Value("disposition")] = Value(disposition); return Value(result);
  }
  if (method == "create") {
    Handle target(CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    auto info = Inspect(target.value); if (!FlushFileBuffers(target.value)) WinError(); target.Close();
    return Value(Map{{Value("identity"), Value(info.identity)}});
  }
  if (method == "copy") {
    auto source = Wide(Text(At(args, "source")));
    Handle input(CreateFileW(source.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    auto sourceInfo = Inspect(input.value);
    if (sourceInfo.identity != Text(At(args, "sourceIdentity")) || sourceInfo.size != length) throw std::runtime_error("fileWriteFailure");
    Handle output(CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!owned(Inspect(output.value))) throw std::runtime_error("publicationUncertain");
    if (!SetEndOfFile(output.value)) WinError();
    std::vector<char> bytes(1024 * 1024); int64_t copied = 0;
    while (true) {
      DWORD count = 0; if (!ReadFile(input.value, bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr)) WinError();
      if (!count) break;
      DWORD offset = 0;
      while (offset < count) { DWORD written = 0; if (!WriteFile(output.value, bytes.data() + offset, count - offset, &written, nullptr) || !written) WinError(); offset += written; }
      copied += count; if (copied > length) throw std::runtime_error("fileWriteFailure");
    }
    if (copied != length || Inspect(output.value).size != length) throw std::runtime_error("fileWriteFailure");
    if (!FlushFileBuffers(output.value)) WinError(); output.Close(); input.Close();
    return Value(Map{});
  }
  if (method == "publish") {
    // Bind the source to an open handle; a path replacement cannot change
    // which file is renamed. RootDirectory binds the verified destination parent.
    Handle source(CreateFileW(temp.c_str(), DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
        nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    auto temporary = Inspect(source.value);
    if (!owned(temporary) || temporary.size != length) throw std::runtime_error("publicationUncertain");
    auto child = Name(args, "candidateName");
    std::vector<unsigned char> buffer(sizeof(FILE_RENAME_INFO) + child.size() * sizeof(wchar_t));
    auto rename = reinterpret_cast<FILE_RENAME_INFO*>(buffer.data());
    rename->ReplaceIfExists = FALSE; rename->RootDirectory = parent.value;
    rename->FileNameLength = static_cast<DWORD>(child.size() * sizeof(wchar_t));
    std::memcpy(rename->FileName, child.data(), rename->FileNameLength);
    if (!SetFileInformationByHandle(source.value, FileRenameInfo, rename, static_cast<DWORD>(buffer.size()))) {
      auto error = GetLastError();
      if (error == ERROR_ALREADY_EXISTS || error == ERROR_FILE_EXISTS) return Value(Map{{Value("conflict"), Value(!owned(Existing(final)))}});
      if (error == ERROR_NOT_SUPPORTED || error == ERROR_INVALID_FUNCTION) throw std::runtime_error("directoryUnsupported");
      WinError();
    }
    return Value(Map{});
  }
  if (method == "delete" || method == "cleanup") {
    // DELETE on a verified handle addresses the file opened, not a subsequent
    // foreign replacement at the same name. Windows locks are reported intact.
    std::vector<std::wstring> paths = method == "cleanup" ? std::vector<std::wstring>{temp} : std::vector<std::wstring>{final, temp};
    for (const auto& path : paths) {
      auto current = Existing(path); if (!current) continue;
      Handle target(CreateFileW(path.c_str(), DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
          nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
      if (!owned(Inspect(target.value))) throw std::runtime_error("cleanupFailure");
      FILE_DISPOSITION_INFO disposition{TRUE};
      if (!SetFileInformationByHandle(target.value, FileDispositionInfo, &disposition, sizeof(disposition))) WinError();
      target.Close();
    }
    return Value(Map{});
  }
  if (method == "open") {
    auto current = Existing(final); if (!current) throw std::runtime_error("fileMissing");
    if (!owned(current) || current->size != length) throw std::runtime_error("publicationUncertain");
    SHELLEXECUTEINFOW execute{}; execute.cbSize = sizeof(execute); execute.fMask = SEE_MASK_FLAG_NO_UI;
    execute.hwnd = window; execute.lpVerb = L"open"; execute.lpFile = final.c_str(); execute.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&execute)) throw std::runtime_error("noHandler");
    return Value(Map{});
  }
  throw std::runtime_error("protocolMismatch");
}
// The window owns this worker and drains replies on its platform thread.
// Shutdown joins the active operation before releasing channel/messenger state.
class StorageChannel {
 public:
  static constexpr UINT kReply = WM_APP + 0x351;
  StorageChannel(flutter::BinaryMessenger* messenger, HWND window) : window_(window),
      channel_(messenger, "downloader/file_storage", &flutter::StandardMethodCodec::GetInstance()),
      worker_([this] { Run(); }) {
    channel_.SetMethodCallHandler([this](const auto& call, auto result) {
      Map empty; auto args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
      // Dialogs and ShellExecute use the owning platform apartment.
      if (call.method_name() == "pickDirectory" || call.method_name() == "open") {
        Reply reply{std::move(result), Value(), {}};
        Execute(call.method_name(), args ? *args : empty, reply); Deliver(reply); return;
      }
      { std::lock_guard<std::mutex> lock(mutex_);
        jobs_.push_back(Job{call.method_name(), args ? *args : empty, std::move(result)}); }
      ready_.notify_one();
    });
  }
  ~StorageChannel() {
    channel_.SetMethodCallHandler(nullptr);
    { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; }
    ready_.notify_one(); worker_.join();
    // Undelivered results are destroyed here, while the messenger is alive.
  }
  void Drain() {
    std::deque<Reply> replies;
    { std::lock_guard<std::mutex> lock(mutex_); replies.swap(replies_); }
    for (auto& reply : replies) Deliver(reply);
  }
 private:
  using Result = std::unique_ptr<flutter::MethodResult<Value>>;
  struct Job { std::string method; Map args; Result result; };
  struct Reply { Result result; Value value; std::string error; };
  void Execute(const std::string& method, const Map& args, Reply& reply) {
    try { reply.value = HandleCall(method, args, window_); }
    catch (const std::runtime_error& error) { reply.error = error.what(); }
    catch (...) { reply.error = "fileWriteFailure"; }
  }
  static void Deliver(Reply& reply) {
    if (reply.error.empty()) reply.result->Success(reply.value);
    else reply.result->Error(reply.error, "文件操作未完成");
  }
  void Run() {
    while (true) {
      std::optional<Job> job;
      { std::unique_lock<std::mutex> lock(mutex_);
        ready_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
        if (stopping_) return;
        job.emplace(std::move(jobs_.front())); jobs_.pop_front(); }
      Reply reply{std::move(job->result), Value(), {}}; Execute(job->method, job->args, reply);
      { std::lock_guard<std::mutex> lock(mutex_); replies_.push_back(std::move(reply)); }
      PostMessageW(window_, kReply, 0, 0);
    }
  }
  HWND window_;
  flutter::MethodChannel<Value> channel_;
  std::mutex mutex_;
  std::condition_variable ready_;
  bool stopping_ = false;
  std::deque<Job> jobs_;
  std::deque<Reply> replies_;
  std::thread worker_;
};
inline std::unique_ptr<StorageChannel> Register(flutter::BinaryMessenger* messenger, HWND window) {
  return std::make_unique<StorageChannel>(messenger, window);
}
}  // namespace downloader_storage
#endif
