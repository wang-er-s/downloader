import Flutter
import UIKit
import Darwin
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var fileStorage: DownloaderFileStorage?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DownloaderFileStorage") {
      fileStorage = DownloaderFileStorage(messenger: registrar.messenger(), platform: "ios")
    }
  }
}

// Handle-based local publication. This channel does not schedule downloads.
private final class DownloaderFileStorage: NSObject {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "downloader.file-storage")
  private let platform: String
  private var pendingPicker: FlutterResult?
  private var preview: UIDocumentInteractionController?
  init(messenger: FlutterBinaryMessenger, platform: String) {
    self.platform = platform
    channel = FlutterMethodChannel(name: "downloader/file_storage", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "pickDirectory" { self.pick(result); return }
      self.queue.async {
        do {
          let value = try self.handle(call.method, call.arguments as? [String: Any] ?? [:])
          DispatchQueue.main.async { result(value) }
        } catch let error as StorageError {
          DispatchQueue.main.async { result(FlutterError(code: error.code, message: "文件操作未完成", details: nil)) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "fileWriteFailure", message: "文件操作未完成", details: nil)) }
        }
      }
    }
  }
  private struct StorageError: Error { let code: String }
  private func fail(_ code: String) throws -> Never { throw StorageError(code: code) }
  private func check(_ value: Bool) throws {
    if !value {
      switch errno {
      case EACCES, EPERM: try fail("permissionDenied")
      case ENOENT: try fail("fileMissing")
      case ELOOP: try fail("publicationUncertain")
      case ENOSPC, EDQUOT: try fail("insufficientSpace")
      default: try fail("fileWriteFailure")
      }
    }
  }
  private func identity(_ info: stat) -> String {
    return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
  }
  private func info(_ fd: Int32) throws -> stat {
    var value = stat()
    try check(fstat(fd, &value) == 0)
    return value
  }
  private func file(_ parent: Int32, _ name: String) throws -> stat? {
    var value = stat()
    if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return nil }
      try check(false)
    }
    if value.st_mode & S_IFMT != S_IFREG { try fail("publicationUncertain") }
    return value
  }
  private func name(_ args: [String: Any], _ key: String) throws -> String {
    guard let value = args[key] as? String, !value.isEmpty, value != ".", value != "..",
          !value.contains("/"), !value.contains("\\"), !value.contains("\0") else { try fail("invalidInput") }
    return value
  }
  private func directory(_ args: [String: Any]) throws -> (URL, Bool) {
    guard let location = args["directory"] as? [String: Any], location["platform"] as? String == platform else { try fail("invalidInput") }
    var url: URL
    var scoped = false
    if location["kind"] as? String == "userSelected" {
      guard let text = location["locator"] as? String, let data = Data(base64Encoded: text) else { try fail("permissionDenied") }
      var stale = false
      #if os(macOS)
      url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
      #else
      url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
      #endif
      if stale { try fail("permissionDenied") }
      scoped = url.startAccessingSecurityScopedResource()
      if !scoped { try fail("permissionDenied") }
    } else {
      let kind = location["kind"] as? String
      if (platform == "macos" && kind != "systemDownloads") || (platform == "ios" && kind != "appDocuments") { try fail("invalidInput") }
      let base: FileManager.SearchPathDirectory = platform == "macos" ? .downloadsDirectory : .documentDirectory
      guard let root = FileManager.default.urls(for: base, in: .userDomainMask).first else { try fail("directoryUnavailable") }
      url = root.appendingPathComponent(platform == "macos" ? "Downloader" : "Downloads", isDirectory: true)
    }
    if let sub = location["subdirectory"] as? String {
      _ = try name(["sub": sub], "sub")
      url.appendPathComponent(sub, isDirectory: true)
    }
    return (url, scoped)
  }
  private func handle(_ method: String, _ args: [String: Any]) throws -> Any {
    if method == "sourceInfo" {
      guard let source = args["source"] as? String, let length = args["sourceLength"] as? NSNumber else { try fail("invalidInput") }
      let fd = Darwin.open(source, O_RDONLY | O_NOFOLLOW)
      try check(fd >= 0)
      defer { Darwin.close(fd) }
      let value = try info(fd)
      guard value.st_mode & S_IFMT == S_IFREG, value.st_size == length.int64Value else { try fail("fileWriteFailure") }
      return ["identity": identity(value)]
    }
    let (url, scoped) = try directory(args)
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    // Coordination ensures external Apple file providers participate in access.
    var coordinationError: NSError?
    var outcome: Result<Any, Error>?
    let coordinator = NSFileCoordinator()
    if method == "recover" || method == "open" {
      coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
        outcome = Result { try self.atDirectory(method, args, coordinated) }
      }
    } else {
      coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinated in
        outcome = Result { try self.atDirectory(method, args, coordinated) }
      }
    }
    if coordinationError != nil { try fail("directoryUnavailable") }
    guard let outcome = outcome else { try fail("directoryUnavailable") }
    return try outcome.get()
  }
  private func atDirectory(_ method: String, _ args: [String: Any], _ url: URL) throws -> Any {
    if method == "resolveDirectory" { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    try check(fd >= 0)
    defer { Darwin.close(fd) }
    let parentIdentity = identity(try info(fd))
    if method == "resolveDirectory" { return ["locator": url.path, "identity": parentIdentity] }
    guard let parent = args["parent"] as? [String: Any], parent["identity"] as? String == parentIdentity else { try fail("publicationUncertain") }
    let temporary = try name(args, "temporaryName")
    let candidate = try name(args, "candidateName")
    let expected = args["identity"] as? String
    let length = (args["sourceLength"] as? NSNumber)?.int64Value ?? -1
    let temporaryIdentity = args["temporaryIdentity"] as? String ?? expected
    func owned(_ value: stat?) -> Bool { value != nil && expected != nil && identity(value!) == expected }
    func staged(_ value: stat?) -> Bool { value != nil && temporaryIdentity != nil && identity(value!) == temporaryIdentity }
    func location() -> [String: Any] { ["version": 1, "platform": platform, "kind": "path", "locator": url.appendingPathComponent(candidate).path, "identity": expected!] }
    if method == "recover" {
      let temp = try file(fd, temporary)
      let final: stat?
      if args["publishAttempt"] as? Bool == true { final = try file(fd, candidate) }
      else { final = try? file(fd, candidate) }
      let phase = args["phase"] as? String
      var disposition = "uncertain"
      var result: [String: Any] = ["version": 1]
      if owned(final) && final!.st_size == length && ["finalizing", "published", "cleaning"].contains(phase ?? "") {
        disposition = "published"; result["ownedLocation"] = location()
      } else if args["publishAttempt"] as? Bool == true && final != nil {
        disposition = "uncertain"
      } else if staged(temp) && phase != "published" {
        disposition = "staged"
        result["ownedLocation"] = ["version": 1, "platform": platform, "kind": "path", "locator": url.appendingPathComponent(temporary).path, "identity": temporaryIdentity!]
      } else if temp == nil && ["prepared", "cleaning"].contains(phase ?? "") { disposition = "notCreated" }
      result["disposition"] = disposition
      return result
    }
    if method == "create" {
      let target = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      try check(target >= 0)
      let value = try info(target)
      try check(Darwin.close(target) == 0)
      try check(fsync(fd) == 0)
      return ["identity": identity(value)]
    }
    if method == "copy" {
      guard let source = args["source"] as? String else { try fail("invalidInput") }
      let sourceFD = Darwin.open(source, O_RDONLY | O_NOFOLLOW)
      try check(sourceFD >= 0)
      defer { Darwin.close(sourceFD) }
      let original = try info(sourceFD)
      guard original.st_mode & S_IFMT == S_IFREG, identity(original) == args["sourceIdentity"] as? String, original.st_size == length else { try fail("fileWriteFailure") }
      let target = openat(fd, temporary, O_WRONLY | O_NOFOLLOW)
      try check(target >= 0)
      var closed = false
      defer { if !closed { Darwin.close(target) } }
      guard owned(try info(target)) else { try fail("publicationUncertain") }
      try check(ftruncate(target, 0) == 0)
      var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
      var copied: Int64 = 0
      while true {
        let count = Darwin.read(sourceFD, &buffer, buffer.count)
        if count < 0 { if errno == EINTR { continue }; try check(false) }
        if count == 0 { break }
        var offset = 0
        while offset < count {
          let written = buffer.withUnsafeBytes { Darwin.write(target, $0.baseAddress!.advanced(by: offset), count - offset) }
          if written < 0 && errno == EINTR { continue }
          try check(written > 0); offset += written
        }
        copied += Int64(count)
        if copied > length { try fail("fileWriteFailure") }
      }
      let after = try info(sourceFD)
      guard copied == length, after.st_size == length, after.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec, try info(target).st_size == length else { try fail("fileWriteFailure") }
      try check(fsync(target) == 0)
      closed = true
      try check(Darwin.close(target) == 0)
      return [:] as [String: Any]
    }
    if method == "publish" {
      // Verified descriptors plus exclusive creation avoid path-link races.
      let source = openat(fd, temporary, O_RDONLY | O_NOFOLLOW)
      try check(source >= 0)
      defer { Darwin.close(source) }
      let value = try info(source)
      guard staged(value), value.st_size == length else { try fail("publicationUncertain") }
      let target = openat(fd, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
      if target < 0 && errno == EEXIST { return ["conflict": true] }
      try check(target >= 0)
      var closed = false
      defer { if !closed { Darwin.close(target) } }
      let createdIdentity = identity(try info(target))
      var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
      var copied: Int64 = 0
      while true {
        let count = Darwin.read(source, &buffer, buffer.count)
        if count < 0 { if errno == EINTR { continue }; try check(false) }
        if count == 0 { break }
        var offset = 0
        while offset < count {
          let written = buffer.withUnsafeBytes { Darwin.write(target, $0.baseAddress!.advanced(by: offset), count - offset) }
          if written < 0 && errno == EINTR { continue }
          try check(written > 0); offset += written
        }
        copied += Int64(count)
        if copied > length { try fail("fileWriteFailure") }
      }
      guard copied == length, try info(target).st_size == length else { try fail("fileWriteFailure") }
      try check(fsync(target) == 0)
      closed = true; try check(Darwin.close(target) == 0)
      try check(fsync(fd) == 0)
      return ["identity": createdIdentity, "keepTemporary": true] as [String: Any]
    }
    if method == "cleanup" || method == "delete" {
      // No conditional unlink-by-identity is available. Preserve existing
      // files rather than deleting a replacement after a pathname check.
      if try file(fd, temporary) != nil { try fail("cleanupFailure") }
      if method == "delete", try file(fd, candidate) != nil { try fail("cleanupFailure") }
      return [:] as [String: Any]
    }
    if method == "open" {
      guard let value = try file(fd, candidate) else { try fail("fileMissing") }
      guard owned(value), value.st_size == length else { try fail("publicationUncertain") }
      #if os(macOS)
      var success = false
      DispatchQueue.main.sync { success = NSWorkspace.shared.open(url.appendingPathComponent(candidate)) }
      if !success { try fail("noHandler") }
      #else
      var success = false
      DispatchQueue.main.sync {
        let controller = UIDocumentInteractionController(url: url.appendingPathComponent(candidate))
        controller.delegate = self
        self.preview = controller
        success = controller.presentPreview(animated: true)
      }
      if !success { try fail("noHandler") }
      #endif
      return [:] as [String: Any]
    }
    try fail("protocolMismatch")
  }
  private func pick(_ result: @escaping FlutterResult) {
    #if os(macOS)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else { result(nil); return }
      do {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        result(["version": 1, "platform": "macos", "kind": "userSelected", "locator": data.base64EncodedString(), "displayName": url.lastPathComponent])
      } catch { result(FlutterError(code: "permissionDenied", message: "无法保存目录授权", details: nil)) }
    }
    #else
    guard pendingPicker == nil, let presenter = presenter() else {
      result(FlutterError(code: "directoryUnavailable", message: "无法打开目录选择器", details: nil)); return
    }
    pendingPicker = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.allowsMultipleSelection = false
    picker.delegate = self
    presenter.present(picker, animated: true)
    #endif
  }
}


extension DownloaderFileStorage: UIDocumentPickerDelegate, UIDocumentInteractionControllerDelegate {
  fileprivate func presenter() -> UIViewController? {
    var current = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = current?.presentedViewController { current = presented }
    return current
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let reply = pendingPicker; pendingPicker = nil; reply?(nil)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let reply = pendingPicker; pendingPicker = nil
    guard let url = urls.first, url.startAccessingSecurityScopedResource() else {
      reply?(FlutterError(code: "permissionDenied", message: "目录授权不可用", details: nil)); return
    }
    defer { url.stopAccessingSecurityScopedResource() }
    do {
      let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      reply?(["version": 1, "platform": "ios", "kind": "userSelected", "locator": data.base64EncodedString(), "displayName": url.lastPathComponent])
    } catch { reply?(FlutterError(code: "permissionDenied", message: "无法保存目录授权", details: nil)) }
  }
  func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
    return presenter()!
  }
  func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) { preview = nil }
}
