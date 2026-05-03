import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  static var menuBarModeIsEnabled = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let icon = NSImage(contentsOf: iconURL) {
      NSApplication.shared.applicationIconImage = icon
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !Self.menuBarModeIsEnabled
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard
      let window = sender.windows.first(where: { $0 is MainFlutterWindow }) as? MainFlutterWindow
    else {
      return true
    }

    window.setMenuBarWindowChromeEnabled(false)
    window.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    return true
  }
}
