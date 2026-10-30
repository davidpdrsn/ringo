import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, parsed from strings like `"option+space"` or `"cmd+shift+k"`.
///
/// Letter and punctuation keys refer to their position on an ANSI (US) keyboard.
struct KeyCombo: Equatable, CustomStringConvertible {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: UInt8
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        var flags: NSEvent.ModifierFlags {
            var result: NSEvent.ModifierFlags = []
            if contains(.control) { result.insert(.control) }
            if contains(.option) { result.insert(.option) }
            if contains(.shift) { result.insert(.shift) }
            if contains(.command) { result.insert(.command) }
            return result
        }

        /// In the order macOS menus show them, e.g. `⌃⌥⇧⌘`.
        var symbols: String {
            var result = ""
            if contains(.control) { result += "⌃" }
            if contains(.option) { result += "⌥" }
            if contains(.shift) { result += "⇧" }
            if contains(.command) { result += "⌘" }
            return result
        }
    }

    var keyCode: UInt32
    var keyName: String
    var modifiers: Modifiers

    init(keyCode: UInt32, keyName: String, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.keyName = keyName
        self.modifiers = modifiers
    }

    init(parsing string: String) throws(KeyComboError) {
        let parts = string.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !parts.contains("") else { throw .malformed(string) }

        var modifiers: Modifiers = []
        var key: (code: Int, name: String)?
        for part in parts {
            if let modifier = Self.modifierNames[part] {
                modifiers.insert(modifier)
            } else if let code = Self.keyCodes[part] {
                guard key == nil else { throw .multipleKeys(string) }
                key = (code, part)
            } else {
                throw .unknownKey(part)
            }
        }
        guard let key else { throw .missingKey(string) }
        self.init(keyCode: UInt32(key.code), keyName: key.name, modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        var result = 0
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }

    var modifierFlags: NSEvent.ModifierFlags { modifiers.flags }

    /// Rendered the way macOS menus show shortcuts, e.g. `⌥Space`.
    var description: String {
        modifiers.symbols + (Self.displayNames[keyName] ?? keyName.uppercased())
    }

    fileprivate static let modifierNames: [String: Modifiers] = [
        "ctrl": .control, "control": .control, "⌃": .control,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "cmd": .command, "command": .command, "⌘": .command,
    ]

    private static let displayNames: [String: String] = [
        "space": "Space", "tab": "⇥", "return": "↩", "enter": "↩", "escape": "⎋", "esc": "⎋",
        "delete": "⌫", "backspace": "⌫", "forwarddelete": "⌦",
        "left": "←", "right": "→", "up": "↑", "down": "↓",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    private static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave,
            "-": kVK_ANSI_Minus, "minus": kVK_ANSI_Minus,
            "=": kVK_ANSI_Equal, "equal": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket, "leftbracket": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "rightbracket": kVK_ANSI_RightBracket,
            "\\": kVK_ANSI_Backslash, "backslash": kVK_ANSI_Backslash,
            ";": kVK_ANSI_Semicolon, "semicolon": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, "quote": kVK_ANSI_Quote,
            ",": kVK_ANSI_Comma, "comma": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period, "period": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "slash": kVK_ANSI_Slash,
            "space": kVK_Space, "tab": kVK_Tab,
            "return": kVK_Return, "enter": kVK_Return,
            "escape": kVK_Escape, "esc": kVK_Escape,
            "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() {
            codes["f\(index + 1)"] = code
        }
        return codes
    }()
}

/// The config's `hotkey`: a key with modifiers, or a modifier held on its own.
enum Hotkey: Equatable, CustomStringConvertible {
    case combo(KeyCombo)
    case modifier(ModifierKey)

    init(parsing string: String) throws(KeyComboError) {
        let parts = string.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if parts.count == 1, let key = ModifierKey(name: parts[0]) {
            self = .modifier(key)
            return
        }
        // Carbon hotkeys can't tell left from right.
        if parts.contains(where: { ModifierKey(name: $0).map { $0.side != .either } ?? false }) {
            throw .sidedModifierInCombo(string)
        }
        self = .combo(try KeyCombo(parsing: string))
    }

    /// The modifiers that have to stay down while the menu is held open.
    var modifiers: KeyCombo.Modifiers {
        switch self {
        case .combo(let combo): combo.modifiers
        case .modifier(let key): key.modifier
        }
    }

    var modifierFlags: NSEvent.ModifierFlags { modifiers.flags }

    var description: String {
        switch self {
        case .combo(let combo): combo.description
        case .modifier(let key): key.description
        }
    }
}

/// A single modifier key, optionally on one side of the keyboard.
struct ModifierKey: Equatable, CustomStringConvertible {
    enum Side {
        case either
        case left
        case right
    }

    var modifier: KeyCombo.Modifiers
    var side: Side

    /// Parses names like `option`, `left-option`, `right_cmd` or `leftshift`.
    init?(name: String) {
        var rest = Substring(name)
        var side = Side.either
        if rest.hasPrefix("left") {
            side = .left
            rest = rest.dropFirst("left".count)
        } else if rest.hasPrefix("right") {
            side = .right
            rest = rest.dropFirst("right".count)
        }
        if side != .either {
            rest = rest.drop(while: { "-_ ".contains($0) })
        }
        // A bare "right" stays the arrow key.
        guard let modifier = KeyCombo.modifierNames[String(rest)] else { return nil }
        self.init(modifier: modifier, side: side)
    }

    init(modifier: KeyCombo.Modifiers, side: Side) {
        self.modifier = modifier
        self.side = side
    }

    /// Whether this key is down, given the flags of a `flagsChanged` event.
    func isDown(in flags: CGEventFlags) -> Bool {
        let masks = self.masks
        switch side {
        case .either: return flags.contains(masks.flag)
        case .left: return flags.rawValue & masks.left != 0
        case .right: return flags.rawValue & masks.right != 0
        }
    }

    /// Whether any other kind of modifier is down, on either side.
    func othersDown(in flags: CGEventFlags) -> Bool {
        let all: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        return !flags.intersection(all.subtracting(masks.flag)).isEmpty
    }

    var modifierFlags: NSEvent.ModifierFlags { modifier.flags }

    var description: String {
        switch side {
        case .either: modifier.symbols
        case .left: "Left \(modifier.symbols)"
        case .right: "Right \(modifier.symbols)"
        }
    }

    /// The device-independent flag, plus the device-dependent bits for each side
    /// (`NX_DEVICEL*KEYMASK` / `NX_DEVICER*KEYMASK` in IOLLEvent.h).
    private var masks: (flag: CGEventFlags, left: UInt64, right: UInt64) {
        if modifier == .control { return (.maskControl, 0x0001, 0x2000) }
        if modifier == .shift { return (.maskShift, 0x0002, 0x0004) }
        if modifier == .command { return (.maskCommand, 0x0008, 0x0010) }
        return (.maskAlternate, 0x0020, 0x0040)
    }
}

enum KeyComboError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unknownKey(String)
    case missingKey(String)
    case multipleKeys(String)
    case sidedModifierInCombo(String)

    var description: String {
        switch self {
        case .malformed(let string): "`\(string)` is malformed, expected something like \"option+space\""
        case .unknownKey(let key): "unknown key or modifier `\(key)`"
        case .missingKey(let string): "`\(string)` has no key, only modifiers"
        case .multipleKeys(let string): "`\(string)` has more than one non-modifier key"
        case .sidedModifierInCombo(let string):
            "`\(string)`: left and right modifiers only work on their own, like \"left-option\""
        }
    }
}
