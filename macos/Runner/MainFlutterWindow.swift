import AVFoundation
import Cocoa
import CoreAudio
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow {
  private let launchAtStartupChannelName = "sfait/launch_at_startup"
  private let systemSettingsChannelName = "sfait/system_settings"
  private let ringtoneChannelName = "sfait/ringtone"
  private let updaterChannelName = "sfait/updater"
  private var ringtoneSound: NSSound?
  private var showMenuBarIcon = false
  private var showDockIcon = true
  private var standardStyleMask: NSWindow.StyleMask?
  private var standardTitleVisibility: NSWindow.TitleVisibility = .visible
  private var standardTitlebarAppearsTransparent = false
  private var standardIsMovable = true
  private var standardIsMovableByWindowBackground = false
  private var hasAppliedInitialPresentationOptions = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    let fixedSize = NSSize(width: 430, height: 760)
    self.title = "SFAIT Softphone"
    self.setContentSize(fixedSize)
    self.minSize = fixedSize
    self.maxSize = fixedSize
    self.styleMask.remove(.resizable)
    self.center()
    self.isReleasedWhenClosed = false
    standardStyleMask = self.styleMask
    standardTitleVisibility = self.titleVisibility
    standardTitlebarAppearsTransparent = self.titlebarAppearsTransparent
    standardIsMovable = self.isMovable
    standardIsMovableByWindowBackground = self.isMovableByWindowBackground

    configureLaunchAtStartupChannel(flutterViewController)
    configureSystemSettingsChannel(flutterViewController)
    configureRingtoneChannel(flutterViewController)
    configureUpdaterChannel(flutterViewController)
    SfaitPjsipBridge.shared().configure(
      with: flutterViewController.engine.binaryMessenger
    )

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  override func close() {
    if showMenuBarIcon || showDockIcon {
      orderOut(nil)
      return
    }

    super.close()
  }

  private func configureLaunchAtStartupChannel(_ flutterViewController: FlutterViewController) {
    FlutterMethodChannel(
      name: launchAtStartupChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "window_unavailable", message: nil, details: nil))
        return
      }

      switch call.method {
      case "launchAtStartupIsEnabled":
        result(self.isLaunchAtStartupEnabled())
      case "launchAtStartupSetEnabled":
        guard
          let arguments = call.arguments as? [String: Any],
          let enabled = arguments["setEnabledValue"] as? Bool
        else {
          result(
            FlutterError(
              code: "invalid_args",
              message: "setEnabledValue manquant",
              details: nil
            )
          )
          return
        }

        do {
          try self.setLaunchAtStartupEnabled(enabled)
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "launch_at_startup_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func configureSystemSettingsChannel(_ flutterViewController: FlutterViewController) {
    FlutterMethodChannel(
      name: systemSettingsChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "window_unavailable", message: nil, details: nil))
        return
      }

      switch call.method {
      case "listAudioInputs":
        self.requestMicrophoneAccessIfNeeded {
          result(self.audioDevices(for: kAudioObjectPropertyScopeInput))
        }
      case "listAudioOutputs":
        result(self.audioDevices(for: kAudioObjectPropertyScopeOutput))
      case "listPrivacyPermissions":
        self.refreshPrivacyPermissions {
          result($0)
        }
      case "showWindowForIncomingCall":
        self.showWindowForIncomingCall()
        result(nil)
      case "openPrivacyPermissionSettings":
        guard
          let arguments = call.arguments as? [String: Any],
          let kind = arguments["kind"] as? String
        else {
          result(
            FlutterError(
              code: "invalid_args",
              message: "kind manquant",
              details: nil
            )
          )
          return
        }
        self.openPrivacyPermissionSettings(kind: kind)
        result(nil)
      case "setWindowPresentationOptions":
        guard
          let arguments = call.arguments as? [String: Any],
          let showMenuBarIcon = arguments["showMenuBarIcon"] as? Bool,
          let showDockIcon = arguments["showDockIcon"] as? Bool
        else {
          result(
            FlutterError(
              code: "invalid_args",
              message: "showMenuBarIcon/showDockIcon manquant",
              details: nil
            )
          )
          return
        }
        self.setWindowPresentationOptions(
          showMenuBarIcon: showMenuBarIcon,
          showDockIcon: showDockIcon
        )
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func configureRingtoneChannel(_ flutterViewController: FlutterViewController) {
    FlutterMethodChannel(
      name: ringtoneChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "window_unavailable", message: nil, details: nil))
        return
      }

      switch call.method {
      case "playRingtone":
        let arguments = call.arguments as? [String: Any]
        let outputDeviceId = arguments?["outputDeviceId"] as? String ?? ""
        let filePath = arguments?["filePath"] as? String ?? ""
        let volume = arguments?["volume"] as? Double ?? 1.0
        self.playRingtone(
          outputDeviceId: outputDeviceId,
          filePath: filePath,
          volume: volume
        )
        result(nil)
      case "setRingtoneVolume":
        let arguments = call.arguments as? [String: Any]
        let volume = arguments?["volume"] as? Double ?? 1.0
        self.setRingtoneVolume(volume)
        result(nil)
      case "stopRingtone":
        self.stopRingtone()
        result(nil)
      case "importRingtone":
        self.importRingtone(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func configureUpdaterChannel(_ flutterViewController: FlutterViewController) {
    FlutterMethodChannel(
      name: updaterChannelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "installUpdateFromDmg":
        guard
          let arguments = call.arguments as? [String: Any],
          let dmgPath = arguments["dmgPath"] as? String,
          !dmgPath.isEmpty
        else {
          result(
            FlutterError(
              code: "invalid_args",
              message: "dmgPath manquant",
              details: nil
            )
          )
          return
        }

        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try Self.installUpdateFromDmg(at: dmgPath)
            DispatchQueue.main.async {
              result(nil)
              NSApp.terminate(nil)
            }
          } catch {
            DispatchQueue.main.async {
              result(
                FlutterError(
                  code: "update_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func requestMicrophoneAccessIfNeeded(_ completion: @escaping () -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized, .restricted, .denied:
      completion()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { _ in
        DispatchQueue.main.async {
          completion()
        }
      }
    @unknown default:
      completion()
    }
  }

  private func privacyPermissions() -> [[String: Any]] {
    [
      [
        "kind": "microphone",
        "label": "Microphone",
        "description": "Autorise la capture de votre voix pendant les appels.",
        "isActive": microphonePermissionIsActive()
      ],
      [
        "kind": "launchAtStartup",
        "label": "Ouverture au démarrage",
        "description": "Permet de lancer le softphone automatiquement.",
        "isActive": launchAtStartupPermissionIsActive()
      ]
    ]
  }

  private func refreshPrivacyPermissions(
    completion: @escaping ([[String: Any]]) -> Void
  ) {
    AVCaptureDevice.requestAccess(for: .audio) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        completion(self.privacyPermissions())
      }
    }
  }

  private func microphonePermissionIsActive() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  private func launchAtStartupPermissionIsActive() -> Bool {
    if #available(macOS 13.0, *) {
      return SMAppService.mainApp.status == .enabled
    }

    return isLaunchAtStartupEnabled()
  }

  private func openPrivacyPermissionSettings(kind: String) {
    let urlString: String
    switch kind {
    case "launchAtStartup":
      urlString = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    default:
      urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    }

    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
  }

  private func setWindowPresentationOptions(
    showMenuBarIcon: Bool,
    showDockIcon: Bool
  ) {
    let isInitialPresentation = !hasAppliedInitialPresentationOptions
    let hasAnyVisibleEntryPoint = showMenuBarIcon || showDockIcon
    self.showMenuBarIcon = showMenuBarIcon
    self.showDockIcon = hasAnyVisibleEntryPoint ? showDockIcon : true
    hasAppliedInitialPresentationOptions = true

    AppDelegate.menuBarModeIsEnabled = self.showMenuBarIcon
    SoftphoneMenuBarController.shared.setVisible(
      self.showMenuBarIcon,
      window: self
    )
    NSApp.setActivationPolicy(self.showDockIcon ? .regular : .accessory)

    if !self.showMenuBarIcon {
      setMenuBarWindowChromeEnabled(false)
    }

    if isInitialPresentation && self.showMenuBarIcon && !self.showDockIcon {
      setMenuBarWindowChromeEnabled(true)
      orderOut(nil)
    }
  }

  private func showWindowForIncomingCall() {
    if showMenuBarIcon {
      SoftphoneMenuBarController.shared.showWindowForIncomingCall()
    } else {
      setMenuBarWindowChromeEnabled(false)
      center()
      NSApp.unhide(nil)
      NSApp.activate(ignoringOtherApps: true)
      makeKeyAndOrderFront(nil)
      orderFrontRegardless()
    }

    NSApp.requestUserAttention(.criticalRequest)
  }

  func setMenuBarWindowChromeEnabled(_ enabled: Bool) {
    if enabled {
      styleMask.insert(.fullSizeContentView)
      titleVisibility = .hidden
      titlebarAppearsTransparent = true
      isMovable = false
      isMovableByWindowBackground = false
      standardWindowButton(.closeButton)?.isHidden = true
      standardWindowButton(.miniaturizeButton)?.isHidden = true
      standardWindowButton(.zoomButton)?.isHidden = true
      return
    }

    if let standardStyleMask {
      styleMask = standardStyleMask
    }
    titleVisibility = standardTitleVisibility
    titlebarAppearsTransparent = standardTitlebarAppearsTransparent
    isMovable = standardIsMovable
    isMovableByWindowBackground = standardIsMovableByWindowBackground
    standardWindowButton(.closeButton)?.isHidden = false
    standardWindowButton(.miniaturizeButton)?.isHidden = false
    standardWindowButton(.zoomButton)?.isHidden = false
  }

  private func audioDevices(for scope: AudioObjectPropertyScope) -> [[String: String]] {
    allAudioDeviceIDs()
      .filter { deviceHasStreams($0, scope: scope) }
      .map { deviceId in
        [
          "id": deviceUID(deviceId) ?? "\(deviceId)",
          "label": deviceName(deviceId) ?? "Périphérique audio"
        ]
      }
      .sorted { lhs, rhs in
        (lhs["label"] ?? "") < (rhs["label"] ?? "")
      }
  }

  private func allAudioDeviceIDs() -> [AudioDeviceID] {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      &dataSize
    )

    guard sizeStatus == noErr else {
      return []
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
    var deviceIDs = Array<AudioDeviceID>(repeating: 0, count: count)
    let dataStatus = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &propertyAddress,
      0,
      nil,
      &dataSize,
      &deviceIDs
    )

    guard dataStatus == noErr else {
      return []
    }

    return deviceIDs
  }

  private func deviceHasStreams(
    _ deviceId: AudioDeviceID,
    scope: AudioObjectPropertyScope
  ) -> Bool {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0

    let status = AudioObjectGetPropertyDataSize(
      deviceId,
      &propertyAddress,
      0,
      nil,
      &dataSize
    )

    return status == noErr && dataSize > 0
  }

  private func deviceName(_ deviceId: AudioDeviceID) -> String? {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var dataSize = UInt32(MemoryLayout<CFString>.size)

    let status = AudioObjectGetPropertyData(
      deviceId,
      &propertyAddress,
      0,
      nil,
      &dataSize,
      &name
    )

    guard status == noErr else {
      return nil
    }

    return name as String
  }

  private func deviceUID(_ deviceId: AudioDeviceID) -> String? {
    var propertyAddress = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString = "" as CFString
    var dataSize = UInt32(MemoryLayout<CFString>.size)

    let status = AudioObjectGetPropertyData(
      deviceId,
      &propertyAddress,
      0,
      nil,
      &dataSize,
      &uid
    )

    guard status == noErr else {
      return nil
    }

    return uid as String
  }

  private func playRingtone(
    outputDeviceId: String,
    filePath: String,
    volume: Double
  ) {
    stopRingtone()

    let fileURL: URL
    if !filePath.isEmpty && FileManager.default.fileExists(atPath: filePath) {
      fileURL = URL(fileURLWithPath: filePath)
    } else {
      fileURL = createRingtoneFile()
    }
    let sound = NSSound(contentsOf: fileURL, byReference: false)
    sound?.loops = true
    sound?.volume = ringtonePlaybackVolume(volume)

    if !outputDeviceId.isEmpty {
      sound?.playbackDeviceIdentifier = outputDeviceId
    }

    ringtoneSound = sound
    ringtoneSound?.play()
  }

  private func setRingtoneVolume(_ volume: Double) {
    ringtoneSound?.volume = ringtonePlaybackVolume(volume)
  }

  private func ringtonePlaybackVolume(_ volume: Double) -> Float {
    let clampedVolume = min(1.0, max(0.0, volume))
    return Float(pow(clampedVolume, 2.2))
  }

  private func importRingtone(result: @escaping FlutterResult) {
    NSApp.activate(ignoringOtherApps: true)
    self.makeKeyAndOrderFront(nil)

    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.prompt = "Importer"
    panel.message = "Choisissez une sonnerie audio pour SFAIT Softphone."
    panel.allowedFileTypes = ["mp3", "wav", "m4a", "aiff", "aif", "caf"]

    let response = panel.runModal()
    guard response == .OK, let sourceURL = panel.url else {
      result(nil)
      return
    }

    do {
      let destinationURL = try self.copyRingtoneToAppSupport(sourceURL)
      result([
        "path": destinationURL.path,
        "name": destinationURL.lastPathComponent
      ])
    } catch {
      result(
        FlutterError(
          code: "ringtone_import_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func copyRingtoneToAppSupport(_ sourceURL: URL) throws -> URL {
    let supportURL = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    .appendingPathComponent("SFAIT Softphone", isDirectory: true)
    .appendingPathComponent("Ringtones", isDirectory: true)

    try FileManager.default.createDirectory(
      at: supportURL,
      withIntermediateDirectories: true
    )

    let cleanedName = sourceURL.lastPathComponent
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
    let destinationURL = supportURL.appendingPathComponent(cleanedName)

    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private func stopRingtone() {
    ringtoneSound?.stop()
    ringtoneSound = nil
  }

  private func createRingtoneFile() -> URL {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("sfait_ringtone.wav")

    if FileManager.default.fileExists(atPath: fileURL.path) {
      return fileURL
    }

    let data = generateRingtoneWav()
    try? data.write(to: fileURL, options: .atomic)
    return fileURL
  }

  private func generateRingtoneWav() -> Data {
    let sampleRate = 16_000
    let segmentDuration = 0.18
    let silenceDuration = 0.08
    let totalDuration = 1.2
    let totalSamples = Int(Double(sampleRate) * totalDuration)
    var pcm = Data(capacity: totalSamples * 2)

    for sampleIndex in 0..<totalSamples {
      let time = Double(sampleIndex) / Double(sampleRate)
      let burstWindow = time.truncatingRemainder(dividingBy: 0.52)
      let isTone = burstWindow < segmentDuration || (burstWindow > 0.26 && burstWindow < 0.26 + segmentDuration)

      let sampleValue: Int16
      if isTone {
        let envelope = min(1.0, max(0.0, (segmentDuration - silenceDuration) > 0 ? (segmentDuration - abs((burstWindow.truncatingRemainder(dividingBy: 0.26)) - (segmentDuration / 2))) / segmentDuration : 1.0))
        let first = sin(2.0 * .pi * 880.0 * time)
        let second = sin(2.0 * .pi * 1320.0 * time)
        let mixed = ((first + second) / 2.0) * 0.35 * envelope
        sampleValue = Int16(max(-32768, min(32767, Int(mixed * 32767.0))))
      } else {
        sampleValue = 0
      }

      var littleEndian = sampleValue.littleEndian
      pcm.append(UnsafeBufferPointer(start: &littleEndian, count: 1))
    }

    let byteRate = sampleRate * 2
    let dataSize = pcm.count
    var wav = Data()
    wav.append("RIFF".data(using: .ascii)!)
    wav.append(UInt32(36 + dataSize).littleEndianData)
    wav.append("WAVE".data(using: .ascii)!)
    wav.append("fmt ".data(using: .ascii)!)
    wav.append(UInt32(16).littleEndianData)
    wav.append(UInt16(1).littleEndianData)
    wav.append(UInt16(1).littleEndianData)
    wav.append(UInt32(sampleRate).littleEndianData)
    wav.append(UInt32(byteRate).littleEndianData)
    wav.append(UInt16(2).littleEndianData)
    wav.append(UInt16(16).littleEndianData)
    wav.append("data".data(using: .ascii)!)
    wav.append(UInt32(dataSize).littleEndianData)
    wav.append(pcm)
    return wav
  }

  private var launchAgentIdentifier: String {
    "fr.sfait.sfait-softphone.loginitem"
  }

  private var launchAgentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent("\(launchAgentIdentifier).plist")
  }

  private func isLaunchAtStartupEnabled() -> Bool {
    if #available(macOS 13.0, *) {
      return SMAppService.mainApp.status == .enabled ||
        SMAppService.mainApp.status == .requiresApproval
    }

    return FileManager.default.fileExists(atPath: launchAgentURL.path)
  }

  private func setLaunchAtStartupEnabled(_ enabled: Bool) throws {
    if #available(macOS 13.0, *) {
      if enabled {
        if SMAppService.mainApp.status != .enabled {
          try SMAppService.mainApp.register()
        }
      } else {
        if SMAppService.mainApp.status != .notRegistered {
          try SMAppService.mainApp.unregister()
        }
      }
      return
    }

    let fileManager = FileManager.default
    let agentsDirectory = launchAgentURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: agentsDirectory,
      withIntermediateDirectories: true
    )

    if enabled {
      let executablePath = Bundle.main.executablePath ?? ""
      let plist: [String: Any] = [
        "Label": launchAgentIdentifier,
        "ProgramArguments": [executablePath],
        "ProcessType": "Interactive",
        "RunAtLoad": true,
        "KeepAlive": false
      ]

      let data = try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: .xml,
        options: 0
      )
      try data.write(to: launchAgentURL, options: .atomic)
      runLaunchCtl(arguments: ["bootstrap", "gui/\(getuid())", launchAgentURL.path])
      runLaunchCtl(arguments: ["enable", "gui/\(getuid())/\(launchAgentIdentifier)"])
      return
    }

    runLaunchCtl(arguments: ["bootout", "gui/\(getuid())", launchAgentURL.path])
    if fileManager.fileExists(atPath: launchAgentURL.path) {
      try fileManager.removeItem(at: launchAgentURL)
    }
  }

  private func runLaunchCtl(arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      // Best effort; persistence is handled by the plist file itself.
    }
  }

  private static func installUpdateFromDmg(at dmgPath: String) throws {
    let fileManager = FileManager.default
    let uniqueId = UUID().uuidString
    let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sfait-softphone-update-\(uniqueId)")
    let stagingDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sfait-softphone-staged-\(uniqueId)")

    try fileManager.createDirectory(
      at: mountPoint,
      withIntermediateDirectories: true
    )
    defer {
      try? fileManager.removeItem(at: mountPoint)
      try? fileManager.removeItem(at: stagingDirectory)
    }

    try runProcess(
      executablePath: "/usr/bin/hdiutil",
      arguments: [
        "attach",
        "-nobrowse",
        "-mountpoint",
        mountPoint.path,
        dmgPath
      ]
    )
    defer {
      try? runProcess(
        executablePath: "/usr/bin/hdiutil",
        arguments: ["detach", mountPoint.path, "-force"]
      )
    }

    let sourceApp = try findAppBundle(in: mountPoint)
    try fileManager.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true
    )
    let stagedApp = stagingDirectory.appendingPathComponent("SFAIT Softphone.app")
    try runProcess(
      executablePath: "/usr/bin/ditto",
      arguments: [sourceApp.path, stagedApp.path]
    )

    try installStagedApp(stagedApp)
  }

  private static func findAppBundle(in directory: URL) throws -> URL {
    let expected = directory.appendingPathComponent("SFAIT Softphone.app")
    if FileManager.default.fileExists(atPath: expected.path) {
      return expected
    }

    let contents = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    if let app = contents.first(where: { $0.pathExtension == "app" }) {
      return app
    }

    throw NSError(
      domain: "SFAITSoftphoneUpdater",
      code: 2,
      userInfo: [
        NSLocalizedDescriptionKey: "Aucune application trouvée dans le DMG."
      ]
    )
  }

  private static func installStagedApp(_ stagedApp: URL) throws {
    let appName = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleName"
    ) as? String ?? "SFAIT Softphone"
    let currentPid = ProcessInfo.processInfo.processIdentifier
    let currentBundle = Bundle.main.bundleURL
    let targetApp: URL
    if currentBundle.path.hasPrefix("/Applications/") {
      targetApp = currentBundle
    } else {
      targetApp = URL(fileURLWithPath: "/Applications/\(appName).app")
    }

    let command = """
set -e
test -d \(shellQuote(stagedApp.path))
pids=$(pgrep -x \(shellQuote(appName)) | grep -vx \(currentPid) || true)
if [ -n "$pids" ]; then echo "$pids" | xargs kill -TERM || true; sleep 0.8; fi
rm -rf \(shellQuote(targetApp.path))
ditto \(shellQuote(stagedApp.path)) \(shellQuote(targetApp.path))
xattr -r -d com.apple.quarantine \(shellQuote(targetApp.path)) >/dev/null 2>&1 || true
open -n \(shellQuote(targetApp.path))
"""

    do {
      try runShell(command)
    } catch {
      try runShellWithAdministratorPrivileges(
        command,
        prompt: "\(appName) veut installer une mise à jour."
      )
    }
  }

  private static func runShell(_ command: String) throws {
    try runProcess(
      executablePath: "/bin/zsh",
      arguments: ["-lc", command]
    )
  }

  private static func runShellWithAdministratorPrivileges(
    _ command: String,
    prompt: String
  ) throws {
    let script = """
on run {shell_command, prompt_text}
  do shell script shell_command with prompt prompt_text with administrator privileges
end run
"""
    try runProcess(
      executablePath: "/usr/bin/osascript",
      arguments: ["-e", script, command, prompt]
    )
  }

  private static func runProcess(
    executablePath: String,
    arguments: [String]
  ) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let errorMessage = String(data: errorData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw NSError(
        domain: "SFAITSoftphoneUpdater",
        code: Int(process.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey: errorMessage?.isEmpty == false
            ? errorMessage!
            : "La commande de mise à jour a échoué."
        ]
      )
    }
  }

  private static func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

private final class SoftphoneMenuBarController: NSObject {
  static let shared = SoftphoneMenuBarController()

  private weak var softphoneWindow: NSWindow?
  private var statusItem: NSStatusItem?

  func setVisible(_ visible: Bool, window: NSWindow) {
    softphoneWindow = window

    if visible {
      createStatusItemIfNeeded()
      return
    }

    if let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
  }

  private func createStatusItemIfNeeded() {
    guard statusItem == nil else {
      return
    }

    let item = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.squareLength
    )

    if let button = item.button {
      button.target = self
      button.action = #selector(handleStatusItemClick(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.toolTip = "SFAIT Softphone"

      if #available(macOS 11.0, *) {
        let image = NSImage(
          systemSymbolName: "phone.fill",
          accessibilityDescription: "SFAIT Softphone"
        )
        image?.isTemplate = true
        button.image = image
      } else {
        button.title = "☎"
      }
    }

    statusItem = item
  }

  @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp ||
        event?.modifierFlags.contains(.control) == true {
      showContextMenu()
      return
    }

    toggleWindowFromMenuBar()
  }

  private func showContextMenu() {
    guard let button = statusItem?.button else {
      return
    }

    let menu = NSMenu()
    let openItem = NSMenuItem(
      title: "Ouvrir",
      action: #selector(openWindowFromMenu(_:)),
      keyEquivalent: ""
    )
    openItem.target = self
    menu.addItem(openItem)
    menu.addItem(.separator())

    let quitItem = NSMenuItem(
      title: "Quitter",
      action: #selector(quitFromMenu(_:)),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)

    menu.popUp(
      positioning: nil,
      at: NSPoint(x: 0, y: button.bounds.minY),
      in: button
    )
  }

  @objc private func openWindowFromMenu(_ sender: Any?) {
    guard let window = softphoneWindow else {
      return
    }

    showWindow(window)
  }

  func showWindowForIncomingCall() {
    guard let window = softphoneWindow else {
      return
    }

    showWindow(window)
  }

  @objc private func quitFromMenu(_ sender: Any?) {
    NSApp.terminate(nil)
  }

  private func toggleWindowFromMenuBar() {
    guard let window = softphoneWindow else {
      return
    }

    if window.isVisible {
      window.orderOut(nil)
      return
    }

    showWindow(window)
  }

  private func showWindow(_ window: NSWindow) {
    if let softphoneWindow = window as? MainFlutterWindow {
      softphoneWindow.setMenuBarWindowChromeEnabled(true)
    }
    position(window)
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
  }

  private func position(_ window: NSWindow) {
    guard
      let button = statusItem?.button,
      let buttonWindow = button.window,
      let screen = buttonWindow.screen ?? NSScreen.main
    else {
      window.center()
      return
    }

    let buttonRectInWindow = button.convert(button.bounds, to: nil)
    let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
    let visibleFrame = screen.visibleFrame
    let windowFrame = window.frame
    let margin: CGFloat = 8

    let x = min(
      max(buttonRectOnScreen.midX - windowFrame.width / 2, visibleFrame.minX + margin),
      visibleFrame.maxX - windowFrame.width - margin
    )
    let preferredY = buttonRectOnScreen.minY - windowFrame.height - margin
    let y = max(preferredY, visibleFrame.minY + margin)

    window.setFrameOrigin(NSPoint(x: x, y: y))
  }
}

private extension UInt16 {
  var littleEndianData: Data {
    var value = self.littleEndian
    return Data(bytes: &value, count: MemoryLayout<Self>.size)
  }
}

private extension UInt32 {
  var littleEndianData: Data {
    var value = self.littleEndian
    return Data(bytes: &value, count: MemoryLayout<Self>.size)
  }
}
