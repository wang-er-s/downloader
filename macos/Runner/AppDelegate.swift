import Cocoa
import CoreFoundation
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var exitChannel: FlutterMethodChannel?
  private var windowProxy: ExitWindowDelegate?
  private var exitPending = false
  private var terminatePending = false
  private var allowTerminate = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    guard let window = mainFlutterWindow,
          let controller = window.contentViewController as? FlutterViewController else { return }
    exitChannel = FlutterMethodChannel(name: "downloader/app_lifecycle", binaryMessenger: controller.engine.binaryMessenger)
    // Retain a forwarding proxy; preserve the Flutter/controller delegate.
    let proxy = ExitWindowDelegate(original: window.delegate) { [weak self] in self?.requestExit() }
    windowProxy = proxy
    window.delegate = proxy
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if allowTerminate { return super.applicationShouldTerminate(sender) }
    terminatePending = true
    requestExit()
    return .terminateLater
  }

  private func requestExit() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !exitPending else { return }
    guard let channel = exitChannel else {
      if terminatePending { terminatePending = false; NSApp.reply(toApplicationShouldTerminate: false) }
      return
    }
    exitPending = true
    channel.invokeMethod("requestExit", arguments: nil) { [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard self.exitPending else { return }
        self.exitPending = false
        let boolean = result as? NSNumber
        let approved = boolean.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        if self.terminatePending {
          self.terminatePending = false
          self.allowTerminate = approved
          NSApp.reply(toApplicationShouldTerminate: approved)
        } else if approved {
          // A window close means application exit; no hidden transfer survives.
          self.allowTerminate = true
          NSApp.terminate(nil)
        }
      }
    }
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Forwards all existing delegate callbacks except the coordinated close.
private final class ExitWindowDelegate: NSObject, NSWindowDelegate {
  private weak var original: NSWindowDelegate?
  private let request: () -> Void
  init(original: NSWindowDelegate?, request: @escaping () -> Void) {
    self.original = original
    self.request = request
    super.init()
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if original?.windowShouldClose?(sender) == false { return false }
    request()
    return false
  }
  override func responds(to selector: Selector!) -> Bool {
    return super.responds(to: selector) || (original?.responds(to: selector) ?? false)
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    if original?.responds(to: selector) == true { return original }
    return super.forwardingTarget(for: selector)
  }
}
