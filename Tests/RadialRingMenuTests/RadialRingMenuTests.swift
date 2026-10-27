import Carbon.HIToolbox
import CoreGraphics
import Testing

@testable import RadialRingMenu

@Suite struct KeyComboTests {
    @Test func parsesModifiersAndKey() throws {
        let combo = try KeyCombo(parsing: "Option + Space")
        #expect(combo.keyCode == UInt32(kVK_Space))
        #expect(combo.modifiers == [.option])
        #expect(combo.carbonModifiers == UInt32(optionKey))
        #expect(combo.description == "⌥Space")
    }

    @Test func acceptsAliases() throws {
        let combo = try KeyCombo(parsing: "cmd+alt+ctrl+shift+f13")
        #expect(combo.keyCode == UInt32(kVK_F13))
        #expect(combo.modifiers == [.command, .option, .control, .shift])
        #expect(combo.description == "⌃⌥⇧⌘F13")
    }

    @Test func rejectsBadCombos() {
        #expect(throws: KeyComboError.missingKey("option+shift")) { try KeyCombo(parsing: "option+shift") }
        #expect(throws: KeyComboError.multipleKeys("a+b")) { try KeyCombo(parsing: "a+b") }
        #expect(throws: KeyComboError.unknownKey("hyper")) { try KeyCombo(parsing: "hyper+a") }
        #expect(throws: KeyComboError.malformed("option+")) { try KeyCombo(parsing: "option+") }
    }
}

@Suite struct HotkeyTests {
    @Test func parsesSidedModifiers() throws {
        #expect(try Hotkey(parsing: "left-option") == .modifier(ModifierKey(modifier: .option, side: .left)))
        #expect(try Hotkey(parsing: "Right_Cmd") == .modifier(ModifierKey(modifier: .command, side: .right)))
        #expect(try Hotkey(parsing: "leftshift") == .modifier(ModifierKey(modifier: .shift, side: .left)))
        #expect(try Hotkey(parsing: "right-ctrl") == .modifier(ModifierKey(modifier: .control, side: .right)))
        #expect(try Hotkey(parsing: "alt") == .modifier(ModifierKey(modifier: .option, side: .either)))
        #expect(try Hotkey(parsing: "left-option").description == "Left ⌥")
    }

    @Test func bareRightIsTheArrowKey() throws {
        #expect(try Hotkey(parsing: "right") == .combo(KeyCombo(keyCode: UInt32(kVK_RightArrow), keyName: "right", modifiers: [])))
    }

    @Test func parsesCombos() throws {
        #expect(try Hotkey(parsing: "option+space") == .combo(try KeyCombo(parsing: "option+space")))
    }

    @Test func rejectsSidedModifiersInCombos() {
        #expect(throws: KeyComboError.sidedModifierInCombo("left-option+space")) {
            try Hotkey(parsing: "left-option+space")
        }
        #expect(throws: KeyComboError.missingKey("option+shift")) { try Hotkey(parsing: "option+shift") }
    }

    @Test func detectsSides() {
        let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        let left = ModifierKey(modifier: .option, side: .left)
        let right = ModifierKey(modifier: .option, side: .right)
        let either = ModifierKey(modifier: .option, side: .either)

        #expect(left.isDown(in: leftOption))
        #expect(!left.isDown(in: rightOption))
        #expect(right.isDown(in: rightOption))
        #expect(!right.isDown(in: leftOption))
        #expect(either.isDown(in: leftOption) && either.isDown(in: rightOption))
        #expect(!left.isDown(in: []))
    }

    @Test func detectsOtherModifiers() {
        let key = ModifierKey(modifier: .option, side: .left)
        let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        #expect(!key.othersDown(in: leftOption))
        #expect(key.othersDown(in: leftOption.union(.maskCommand)))
        #expect(key.othersDown(in: leftOption.union(.maskShift)))
    }
}

@Suite struct RadialLayoutTests {
    let layout = RadialLayout(count: 4, radius: 100, iconSize: 64)

    @Test func startsAtTopAndGoesClockwise() {
        #expect(layout.selection(for: CGPoint(x: 0, y: 50)) == 0)
        #expect(layout.selection(for: CGPoint(x: 50, y: 0)) == 1)
        #expect(layout.selection(for: CGPoint(x: 0, y: -50)) == 2)
        #expect(layout.selection(for: CGPoint(x: -50, y: 0)) == 3)

        let top = layout.offset(of: 0)
        #expect(abs(top.x) < 0.001 && abs(top.y - 100) < 0.001)
        let right = layout.offset(of: 1)
        #expect(abs(right.x - 100) < 0.001 && abs(right.y) < 0.001)
    }

    @Test func picksNearestSector() {
        // Just left of 12 o'clock is still the top item, not the left one.
        #expect(layout.selection(for: CGPoint(x: -30, y: 40)) == 0)
        #expect(layout.selection(for: CGPoint(x: -40, y: 30)) == 3)
    }

    @Test func deadZoneSelectsNothing() {
        #expect(layout.selection(for: .zero) == nil)
        #expect(layout.selection(for: CGPoint(x: 5, y: 5)) == nil)
    }

    @Test func singleItemIsSelectedInAnyDirection() {
        let single = RadialLayout(count: 1, radius: 100, iconSize: 64)
        #expect(single.selection(for: CGPoint(x: 0, y: -80)) == 0)
        #expect(single.selection(for: CGPoint(x: -80, y: 3)) == 0)
    }

    @Test func growsRadiusSoIconsDontOverlap() {
        let crowded = RadialLayout(count: 16, radius: 50, iconSize: 64)
        let a = crowded.offset(of: 0)
        let b = crowded.offset(of: 1)
        #expect(hypot(a.x - b.x, a.y - b.y) >= 64)
    }
}

@Suite struct ConfigTests {
    @Test func parsesFullConfig() throws {
        let config = try Config.parse("""
            hotkey = "cmd+shift+k"
            radius = 140
            icon_size = 48.5

            [[apps]]
            name = "Safari"

            [[apps]]
            bundle_id = "com.apple.Terminal"
            name = "Shell"

            [[apps]]
            path = "~/Applications/Foo.app"
            """)
        #expect(config.hotkey == .combo(try KeyCombo(parsing: "cmd+shift+k")))
        #expect(config.radius == 140)
        #expect(config.iconSize == 48.5)
        #expect(config.apps == [
            AppSpec(name: "Safari"),
            AppSpec(name: "Shell", bundleID: "com.apple.Terminal"),
            AppSpec(path: "~/Applications/Foo.app"),
        ])
    }

    @Test func fillsInDefaults() throws {
        let config = try Config.parse("")
        #expect(config.hotkey == (try Hotkey(parsing: Config.defaultHotkey)))
        #expect(config.radius == Config.defaultRadius)
        #expect(config.iconSize == Config.defaultIconSize)
        #expect(config.apps.isEmpty)
    }

    @Test func templateIsValid() throws {
        let config = try Config.parse(Config.template)
        #expect(!config.apps.isEmpty)
    }

    @Test func rejectsUnknownKeys() {
        #expect(throws: ConfigError.self) { try Config.parse("icon_szie = 10") }
        #expect(throws: ConfigError.self) { try Config.parse("[[apps]]\nnmae = \"Safari\"") }
    }

    @Test func rejectsEmptyAppEntries() {
        #expect(throws: ConfigError.self) { try Config.parse("[[apps]]\nname = \"Safari\"\n\n[[apps]]\n") }
    }

    @Test func rejectsBadHotkey() {
        #expect(throws: ConfigError.self) { try Config.parse("hotkey = \"option+shift\"") }
        #expect(throws: ConfigError.self) { try Config.parse("hotkey = \"left-option+k\"") }
    }

    @Test func rejectsInvalidToml() {
        #expect(throws: ConfigError.self) { try Config.parse("hotkey = ") }
    }
}
