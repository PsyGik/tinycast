import Darwin

/// The Dock's ⌘⇥ and ⌘⇧⇥, matched in the WindowServer ahead of any Carbon hotkey.
enum SystemSwitcherHotKeys {
    /// SkyLight's symbolic-hotkey ids; the switch outlives the process, so a disable needs a restore.
    enum HotKey: Int32, CaseIterable, Sendable {
        case commandTab = 1
        case commandShiftTab = 2
    }

    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

    /// Private SPI, resolved at runtime: a macOS without it leaves the chord unclaimed, not a crash.
    @discardableResult
    static func setEnabled(_ hotKey: HotKey, _ enabled: Bool) -> Bool {
        guard
            let skyLight = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let symbol = dlsym(skyLight, "CGSSetSymbolicHotKeyEnabled")
        else { return false }
        let setEnabled = unsafeBitCast(symbol, to: SetEnabled.self)
        return setEnabled(hotKey.rawValue, enabled) == 0
    }
}
