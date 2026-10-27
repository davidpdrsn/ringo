import Carbon.HIToolbox

/// A registered hotkey of either kind, kept until `unregister()` is called.
@MainActor
protocol HotKeyHandle: AnyObject {
    func unregister()
}

extension Hotkey {
    @MainActor
    func register(handler: @escaping (HotKeyCenter.Event) -> Void) throws(HotKeyError) -> any HotKeyHandle {
        switch self {
        case .combo(let combo): try HotKeyCenter.shared.register(combo, handler: handler)
        case .modifier(let key): ModifierKeyMonitor(key: key, handler: handler)
        }
    }
}

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Unlike event taps this needs no Accessibility or Input Monitoring permission,
/// and it reports both press and release, which the hold-to-open menu relies on.
@MainActor
final class HotKeyCenter {
    enum Event {
        case pressed
        case released
    }

    static let shared = HotKeyCenter()

    private var handlers: [UInt32: (Event) -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    func register(_ combo: KeyCombo, handler: @escaping (Event) -> Void) throws(HotKeyError) -> HotKeyRegistration {
        try installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            EventHotKeyID(signature: hotKeySignature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            if status == eventHotKeyExistsErr {
                throw HotKeyError("Couldn't register the hotkey \(combo): it's already in use.")
            }
            throw HotKeyError("Couldn't register the hotkey \(combo) (OSStatus \(status)).")
        }
        handlers[id] = handler
        return HotKeyRegistration(id: id, ref: ref)
    }

    fileprivate func unregister(_ registration: HotKeyRegistration) {
        UnregisterEventHotKey(registration.ref)
        handlers[registration.id] = nil
    }

    fileprivate func dispatch(id: UInt32, event: Event) {
        handlers[id]?(event)
    }

    private func installEventHandlerIfNeeded() throws(HotKeyError) {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
        guard status == noErr else {
            throw HotKeyError("Couldn't set up hotkeys (OSStatus \(status)).")
        }
    }
}

@MainActor
final class HotKeyRegistration: HotKeyHandle {
    fileprivate let id: UInt32
    fileprivate let ref: EventHotKeyRef
    private var isRegistered = true

    fileprivate init(id: UInt32, ref: EventHotKeyRef) {
        self.id = id
        self.ref = ref
    }

    func unregister() {
        guard isRegistered else { return }
        isRegistered = false
        HotKeyCenter.shared.unregister(self)
    }
}

struct HotKeyError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// 'RRMn'
private let hotKeySignature: OSType = 0x5252_4D6E

private func hotKeyEventHandler(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let kind: HotKeyCenter.Event = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .pressed : .released
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        HotKeyCenter.shared.dispatch(id: id, event: kind)
    }
    return noErr
}
