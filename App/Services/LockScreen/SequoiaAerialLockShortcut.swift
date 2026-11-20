import Carbon

/// Takes ⌃⌘Q while the Sequoia bridge is active; cancellation restores the system's shortcut.
@MainActor
final class SequoiaAerialLockShortcut {
  private static let signature: OSType = 0x574D_4C4B
  private let action: @MainActor () -> Void
  private var handler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?

  private init(action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  static func listen(action: @escaping @MainActor () -> Void) -> (() -> Void)? {
    // Unit tests must not install a process-wide Carbon shortcut.
    if NSClassFromString("XCTestCase") != nil { return nil }
    guard ScreenLock.isAvailable else { return nil }
    let listener = SequoiaAerialLockShortcut(action: action)
    guard listener.register() else { return nil }
    return { listener.stop() }
  }

  deinit {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
  }

  private func register() -> Bool {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, userData -> OSStatus in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        guard status == noErr else { return status }
        let listener = Unmanaged<SequoiaAerialLockShortcut>.fromOpaque(userData).takeUnretainedValue()
        return MainActor.assumeIsolated { listener.fire(pressed) }
      },
      1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard status == noErr else {
      AppLog.warn("Sequoia Aerial: could not listen for the lock shortcut (\(status))")
      return false
    }
    let registration = RegisterEventHotKey(
      UInt32(kVK_ANSI_Q), UInt32(controlKey | cmdKey),
      EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive), &hotKey)
    if registration != noErr {
      AppLog.warn("Sequoia Aerial: lock shortcut was refused (\(registration)); the system shortcut remains active")
      return false
    }
    return true
  }

  private func fire(_ pressed: EventHotKeyID) -> OSStatus {
    guard pressed.signature == Self.signature, pressed.id == 1 else { return OSStatus(eventNotHandledErr) }
    action()
    return noErr
  }

  private func stop() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    hotKey = nil
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
}
