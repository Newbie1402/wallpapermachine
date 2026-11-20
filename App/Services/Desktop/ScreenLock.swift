import Darwin

/// Locks the screen the way the system's Lock Screen command (⌃⌘Q) does, through
/// the private `SACLockScreenImmediate` in login.framework. Nil-safe: when a macOS
/// release drops the symbol, the menu leaves the command out.
enum ScreenLock {
    private typealias LockNow = @convention(c) () -> Int32

    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)

    private static let lockNow: LockNow? = {
        guard let framework, let symbol = dlsym(framework, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockNow.self)
    }()

    private static let screenSaverNow: LockNow? = {
        guard let framework, let symbol = dlsym(framework, "SACScreenSaverStartNow") else { return nil }
        return unsafeBitCast(symbol, to: LockNow.self)
    }()

    static var isAvailable: Bool { lockNow != nil }

    static func lock() {
        _ = lockNow?()
    }

    static func lockStartingScreenSaver() {
        guard let lockNow else {
            AppLog.error("Sequoia Aerial: the system lock action is unavailable")
            return
        }
        // Establish Idle before locking; starting a saver after lock leaves Sequoia on its still frame.
        if let screenSaverNow {
            let status = screenSaverNow()
            if status != 0 { AppLog.warn("Sequoia Aerial: screen saver start failed (\(status)); locking normally") }
        } else {
            AppLog.warn("Sequoia Aerial: screen saver start is unavailable; locking normally")
        }
        let status = lockNow()
        if status != 0 { AppLog.error("Sequoia Aerial: system lock failed (\(status))") }
    }
}
