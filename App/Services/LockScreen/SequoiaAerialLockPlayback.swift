import AppKit
import CryptoKit
import IOKit.pwr_mgt

/// Sequoia's manual-lock timeout sleeps the display even while an Aerial is playing.
@MainActor
final class SequoiaAerialLockPlayback {
  private let isLocked: @MainActor () -> Bool
  private let bridgeIsSelected: @MainActor () async -> Bool
  private let selectionMatches: @MainActor () -> Bool
  private let holdDisplay: @MainActor () -> (() -> Void)?
  private let listenForLock: @MainActor (@escaping @MainActor () -> Void) -> (() -> Void)?
  private let lockScreen: @MainActor (Bool) -> Void
  private var releaseDisplay: (() -> Void)?
  private var cancelShortcut: (() -> Void)?
  private var generation = 0
  private var stopped = false
  private static let validation = AssetValidation()
  private static let changedNotification = "app.wallpapermachine.sequoia-aerial.changed"
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  init(
    isLocked: @escaping @MainActor () -> Bool = SequoiaAerialLockPlayback.lockedConsoleSession,
    bridgeIsSelected: @escaping @MainActor () async -> Bool = SequoiaAerialLockPlayback.installedBridgeIsSelected,
    selectionMatches: @escaping @MainActor () -> Bool = SequoiaAerialLockPlayback.installedSelectionMatches,
    holdDisplay: @escaping @MainActor () -> (() -> Void)? = SequoiaAerialLockPlayback.holdDisplayAwake,
    listenForLock: @escaping @MainActor (@escaping @MainActor () -> Void) -> (() -> Void)? = SequoiaAerialLockShortcut.listen,
    lockScreen: (@MainActor (Bool) -> Void)? = nil,
    startScreenSaver: (@MainActor () -> Bool)? = nil
  ) {
    let fallbackLock: @MainActor (Bool) -> Void = { startsSaver in
      if startsSaver { ScreenLock.lockStartingScreenSaver() } else { ScreenLock.lock() }
    }
    self.isLocked = isLocked
    self.bridgeIsSelected = bridgeIsSelected
    self.selectionMatches = selectionMatches
    self.holdDisplay = holdDisplay
    self.listenForLock = listenForLock
    self.lockScreen = lockScreen ?? { startsSaver in
      if let startScreenSaver, startsSaver { _ = startScreenSaver() }
      else { fallbackLock(startsSaver) }
    }
  }

  func start() {
    guard observers.isEmpty, ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 else { return }
    stopped = false
    let lockCenter = DistributedNotificationCenter.default()
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    let events: [(NotificationCenter, Notification.Name)] = [
      (lockCenter, .init("com.apple.screenIsLocked")),
      (lockCenter, .init("com.apple.screenIsUnlocked")),
      (workspaceCenter, NSWorkspace.screensDidWakeNotification),
      (workspaceCenter, NSWorkspace.didWakeNotification),
      (workspaceCenter, NSWorkspace.sessionDidBecomeActiveNotification),
    ]
    for (center, name) in events {
      observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in await self?.refresh() }
      }))
    }
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                 NSWorkspace.sessionDidResignActiveNotification] {
      observers.append((workspaceCenter, workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.release() }
      }))
    }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let playback = Unmanaged<SequoiaAerialLockPlayback>.fromOpaque(observer).takeUnretainedValue()
        Task { @MainActor [weak playback] in await playback?.refresh() }
      }, Self.changedNotification as CFString, nil, .deliverImmediately)
    Task { @MainActor [weak self] in await self?.refresh() }
  }

  func refresh() async {
    guard !stopped else { return }
    if !isLocked() {
      release()
      return
    }
    else if releaseDisplay == nil {
      guard let release = holdDisplay() else {
        AppLog.warn("Sequoia Aerial: could not hold the locked display awake")
        return
      }
      releaseDisplay = release
    }
    let attempt = generation
    let selected = await bridgeIsSelected()
    guard generation == attempt, !stopped else { return }
    if selected, cancelShortcut == nil {
      cancelShortcut = listenForLock { [weak self] in self?.lock() }
    } else if !selected {
      cancelShortcut?()
      cancelShortcut = nil
    }
    if !selected || !isLocked() { release() }
  }

  func lock() {
    // A saver started after the ordinary lock only shows Sequoia's cached picture.
    let startsSaver = !stopped && cancelShortcut != nil && selectionMatches()
    if !startsSaver {
      cancelShortcut?()
      cancelShortcut = nil
    }
    lockScreen(startsSaver)
  }

  func stop() {
    stopped = true
    for (center, observer) in observers { center.removeObserver(observer) }
    observers.removeAll()
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(Self.changedNotification as CFString), nil)
    cancelShortcut?()
    cancelShortcut = nil
    release()
  }

  private func release() {
    generation += 1
    releaseDisplay?()
    releaseDisplay = nil
  }

  private static func lockedConsoleSession() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    return session?["CGSSessionScreenIsLocked"] as? Bool == true
      && session?["kCGSSessionOnConsoleKey"] as? Bool == true
  }

  private static func holdDisplayAwake() -> (() -> Void)? {
    var assertion: IOPMAssertionID = 0
    // The installed clip is finite; never hold a black screen awake after its repeat budget.
    let properties: [String: Any] = [
      kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleDisplaySleep,
      kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
      kIOPMAssertionNameKey as String: "WallpaperMachine Sequoia lock-screen video",
      kIOPMAssertionTimeoutKey as String: 15 * 60,
      kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionTurnOff,
    ]
    let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &assertion)
    guard result == kIOReturnSuccess else { return nil }
    return { IOPMAssertionRelease(assertion) }
  }

  private static func installedSelectionMatches() -> Bool {
    let manifestURL = ClientPaths.supportURL.appendingPathComponent("SequoiaAerialBridge/manifest.json")
    let indexURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    guard let manifest = try? Data(contentsOf: manifestURL),
          let index = try? Data(contentsOf: indexURL) else { return false }
    return bridgeIsSelected(manifest: manifest, index: index)
  }

  private static func installedBridgeIsSelected() async -> Bool {
    await validation.isSelected()
  }

  private actor AssetValidation {
    private struct Fingerprint: Equatable {
      let path: String
      let size: UInt64
      let modified: Date
      let inode: UInt64
      let hash: String
    }
    private var validated: Fingerprint?

    func isSelected() -> Bool {
      let manifestURL = ClientPaths.supportURL.appendingPathComponent("SequoiaAerialBridge/manifest.json")
      let indexURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
      guard let manifest = try? Data(contentsOf: manifestURL),
            let index = try? Data(contentsOf: indexURL) else { return false }
      guard SequoiaAerialLockPlayback.bridgeIsSelected(manifest: manifest, index: index),
            let record = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
            let id = record["asset_id"] as? String, let assetID = UUID(uuidString: id),
            let expected = record["installed_sha256"] as? String else { return false }
      let target = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS")
        .appendingPathComponent("\(assetID.uuidString).mov")
      guard record["target"] as? String == target.path,
            let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
            let size = attributes[.size] as? UInt64,
            let modified = attributes[.modificationDate] as? Date,
            let inode = attributes[.systemFileNumber] as? UInt64 else { return false }
      let fingerprint = Fingerprint(path: target.path, size: size, modified: modified, inode: inode, hash: expected)
      if validated == fingerprint { return true }
      guard let file = try? FileHandle(forReadingFrom: target) else { return false }
      defer { try? file.close() }
      var hash = SHA256()
      do {
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { return false }
        validated = fingerprint
        return true
      } catch { return false }
    }
  }

  nonisolated static func bridgeIsSelected(manifest: Data, index: Data) -> Bool {
    guard let record = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
          record["version"] as? Int == 1,
          let id = record["asset_id"] as? String, let assetID = UUID(uuidString: id),
          let installed = record["installed_sha256"] as? String, installed.count == 64,
          let selections = try? PropertyListSerialization.propertyList(from: index, options: [], format: nil)
    else { return false }
    var ids: Set<UUID> = []
    var valid = true
    func visit(_ value: Any) {
      if let dictionary = value as? [String: Any] {
        if let provider = dictionary["Provider"] as? String {
          if provider == "com.apple.wallpaper.choice.aerials", let configuration = dictionary["Configuration"] as? Data,
             let decoded = try? PropertyListSerialization.propertyList(from: configuration, options: [], format: nil) as? [String: Any],
             let rawID = decoded["assetID"] as? String, let id = UUID(uuidString: rawID) {
            ids.insert(id)
          } else { valid = false }
        }
        for child in dictionary.values { visit(child) }
      } else if let array = value as? [Any] {
        for child in array { visit(child) }
      }
    }
    func visitIdle(_ value: Any) {
      if let dictionary = value as? [String: Any] {
        for (key, child) in dictionary {
          if key == "Idle" || key == "Linked" { visit(child) }
          else if key != "Desktop" { visitIdle(child) }
        }
      } else if let array = value as? [Any] {
        for child in array { visitIdle(child) }
      }
    }
    visitIdle(selections)
    return valid && ids == [assetID]
  }
}
