import Carbon.HIToolbox

@MainActor
private func hotKeyCarbonEventHandler(
    _: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let error = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard error == noErr else { return error }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    let kind = GetEventKind(event)
    return center.handle(hotKeyID, kind: kind)
}

/// The Carbon layer only; which shortcuts exist is `HotKeyManager`'s business.
@MainActor
final class HotKeyCenter {
    private struct Entry {
        let shortcut: KeyShortcut
        let onKeyDown: () -> Void
        let onKeyUp: (() -> Void)?
        let carbonID: UInt32
        var ref: EventHotKeyRef?
    }

    /// Live registrations by stable id, plus the reverse lookup the Carbon callback needs.
    private var entries: [String: Entry] = [:]
    private var idToKey: [UInt32: String] = [:]
    private var nextCarbonID: UInt32 = 0
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x5459_4354  // FourCC "TYCT"
    /// Persisted, so a launch after a crash can hand back what the crashed process switched off.
    private var disabledSwitcherKeys: Set<SystemSwitcherHotKeys.HotKey> {
        didSet {
            UserDefaults.standard.set(
                disabledSwitcherKeys.map(\.rawValue).sorted(), forKey: Self.disabledSwitcherKey)
        }
    }
    private static let disabledSwitcherKey = "systemSwitcherHotKeysDisabled"

    /// While true every hotkey is soft-unregistered, so a recorder can capture combos.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            for key in entries.keys {
                if isPaused { deactivate(key) } else { activate(key) }
            }
            syncSystemSwitcher()
        }
    }

    init() {
        let stored = UserDefaults.standard.array(forKey: Self.disabledSwitcherKey) as? [Int32] ?? []
        disabledSwitcherKeys = Set(stored.compactMap(SystemSwitcherHotKeys.HotKey.init(rawValue:)))
        restoreSystemSwitcher()
    }

    /// Registers `shortcut` under `id`, dropping any previous one so no combo leaks.
    func register(
        id: String, shortcut: KeyShortcut, onKeyDown: @escaping () -> Void,
        onKeyUp: (() -> Void)? = nil
    ) {
        unregister(id: id)
        nextCarbonID += 1
        entries[id] = Entry(
            shortcut: shortcut, onKeyDown: onKeyDown, onKeyUp: onKeyUp,
            carbonID: nextCarbonID, ref: nil)
        idToKey[nextCarbonID] = id
        if !isPaused { activate(id) }
        syncSystemSwitcher()
    }

    func unregister(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
        idToKey.removeValue(forKey: entry.carbonID)
        syncSystemSwitcher()
    }

    /// Hands ⌘⇥ and ⌘⇧⇥ back to the Dock; called at quit, since the switch outlives the process.
    func restoreSystemSwitcher() {
        for hotKey in disabledSwitcherKeys { SystemSwitcherHotKeys.setEnabled(hotKey, true) }
        disabledSwitcherKeys = []
    }

    /// The Dock's switcher is off exactly while a live binding claims its chord, or a recorder runs.
    private func syncSystemSwitcher() {
        let claimed: Set<SystemSwitcherHotKeys.HotKey> =
            isPaused
            ? Set(SystemSwitcherHotKeys.HotKey.allCases)
            : Set(entries.values.compactMap { $0.ref == nil ? nil : Self.switcherKey(for: $0.shortcut) })
        guard claimed != disabledSwitcherKeys else { return }
        for hotKey in SystemSwitcherHotKeys.HotKey.allCases {
            let claim = claimed.contains(hotKey)
            guard claim != disabledSwitcherKeys.contains(hotKey) else { continue }
            SystemSwitcherHotKeys.setEnabled(hotKey, !claim)
        }
        disabledSwitcherKeys = claimed
    }

    private static func switcherKey(for shortcut: KeyShortcut) -> SystemSwitcherHotKeys.HotKey? {
        guard shortcut.carbonKeyCode == kVK_Tab else { return nil }
        switch shortcut.carbonModifiers {
        case cmdKey: return .commandTab
        case cmdKey | shiftKey: return .commandShiftTab
        default: return nil
        }
    }

    private func activate(_ id: String) {
        guard var entry = entries[id], entry.ref == nil else { return }
        installEventHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let error = RegisterEventHotKey(
            UInt32(entry.shortcut.carbonKeyCode),
            UInt32(entry.shortcut.carbonModifiers),
            EventHotKeyID(signature: signature, id: entry.carbonID),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        // Another app may own the combo; the binding stays visible but doesn't fire.
        guard error == noErr, let ref else {
            NSLog("Tinycast: could not register hotkey for %@ (OSStatus %d)", id, error)
            return
        }
        entry.ref = ref
        entries[id] = entry
    }

    private func deactivate(_ id: String) {
        guard var entry = entries[id], let ref = entry.ref else { return }
        UnregisterEventHotKey(ref)
        entry.ref = nil
        entries[id] = entry
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil, let dispatcher = GetEventDispatcherTarget() else { return }
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(
            dispatcher,
            { @MainActor call, event, userData in
                hotKeyCarbonEventHandler(call, event: event, userData: userData)
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    fileprivate func handle(_ hotKeyID: EventHotKeyID, kind: UInt32) -> OSStatus {
        guard
            hotKeyID.signature == signature,
            let key = idToKey[hotKeyID.id],
            let entry = entries[key]
        else { return OSStatus(eventNotHandledErr) }
        if kind == kEventHotKeyPressed {
            entry.onKeyDown()
        } else if kind == kEventHotKeyReleased {
            guard let onKeyUp = entry.onKeyUp else { return OSStatus(eventNotHandledErr) }
            onKeyUp()
        } else {
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}
