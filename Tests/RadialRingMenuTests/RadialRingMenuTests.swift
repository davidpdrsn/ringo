import AppKit
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

    @Test func parsesProcessEntries() throws {
        let config = try Config.parse("""
            [[apps]]
            process = "gitbutler-gpui"
            name = "GitButler"
            icon = "~/icon.png"
            """)
        #expect(config.apps == [AppSpec(name: "GitButler", process: "gitbutler-gpui", icon: "~/icon.png")])
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

@Suite struct AppResolverTests {
    @Test func resolvesProcessesWithoutLookingThemUp() throws {
        let item = try AppResolver.resolve(AppSpec(process: "definitely-not-running"))
        #expect(item.title == "definitely-not-running")
        guard case .process(let name) = item.target else {
            Issue.record("expected a process target, got \(item.target)")
            return
        }
        #expect(name == "definitely-not-running")
        #expect(item.runningApplication(in: NSWorkspace.shared.runningApplications) == nil)
    }

    @Test func usesNameAsProcessLabel() throws {
        let item = try AppResolver.resolve(AppSpec(name: "GitButler", process: "gitbutler-gpui"))
        #expect(item.title == "GitButler")
    }

    @Test func loadsCustomIcons() throws {
        let png = FileManager.default.temporaryDirectory.appending(path: "radial-ring-menu-test-icon.png")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }

        let item = try AppResolver.resolve(AppSpec(process: "some-process", icon: png.path))
        #expect(item.icon.size == CGSize(width: 4, height: 2))

        // An app's icon can be borrowed too.
        let borrowed = try AppResolver.resolve(AppSpec(process: "some-process", icon: "/System/Applications/Calculator.app"))
        #expect(borrowed.icon.isValid)
    }

    @Test func rejectsBadIcons() {
        #expect(throws: AppResolutionError.self) {
            try AppResolver.resolve(AppSpec(process: "some-process", icon: "/no/such/icon.png"))
        }
        #expect(throws: AppResolutionError.self) {
            try AppResolver.resolve(AppSpec(process: "some-process", icon: "/bin/ls"))
        }
    }

    @Test func rejectsExecutablesThatArentApps() {
        #expect(throws: AppResolutionError.self) { try AppResolver.resolve(AppSpec(path: "/bin/ls")) }
    }
}

@Suite struct TrackpadGestureTests {
    let surface = CGSize(width: 100, height: 50)

    func frame(_ fingers: Int, at centroid: CGPoint = CGPoint(x: 0.5, y: 0.5), device: UInt = 1) -> TouchFrame {
        TouchFrame(device: device, fingers: fingers, centroid: centroid)
    }

    @Test func matchesMultitouchSupportsLayout() {
        #expect(MemoryLayout<MTTouch>.size == 96)
        #expect(MemoryLayout<MTTouch>.offset(of: \.timestamp) == 8)
        #expect(MemoryLayout<MTTouch>.offset(of: \.normalized) == 32)
        #expect(MemoryLayout<MTTouch>.offset(of: \.absolute) == 68)
        #expect(MemoryLayout<MTTouch>.offset(of: \.zDensity) == 92)
    }

    @Test func beginsAfterSettlingMovesAndEnds() {
        var gesture = TrackpadGesture(fingers: 3)
        #expect(gesture.process(frame(1), surfaceSize: surface, at: 0).isEmpty)
        #expect(gesture.process(frame(3), surfaceSize: surface, at: 0.01).isEmpty)
        #expect(gesture.process(frame(3), surfaceSize: surface, at: 0.03).isEmpty)
        #expect(gesture.process(frame(3), surfaceSize: surface, at: 0.07) == [.began, .moved(.zero)])

        // 0.1 of a 100 mm wide surface to the right, 0.2 of 50 mm up: 10 mm and 10 mm.
        let moved = gesture.process(frame(3, at: CGPoint(x: 0.6, y: 0.7)), surfaceSize: surface, at: 0.1)
        let points = 10 * TrackpadGesture.pointsPerMillimeter
        guard case .moved(let offset) = moved.first else {
            Issue.record("expected a move, got \(moved)")
            return
        }
        #expect(abs(offset.x - points) < 0.01 && abs(offset.y - points) < 0.01)

        #expect(gesture.process(frame(2), surfaceSize: surface, at: 0.2) == [.ended])
        // Lifting the rest doesn't start anything new.
        #expect(gesture.process(frame(1), surfaceSize: surface, at: 0.21).isEmpty)
        #expect(gesture.process(frame(0), surfaceSize: surface, at: 0.22).isEmpty)
    }

    @Test func passingThroughOnTheWayToMoreFingersDoesNothing() {
        var gesture = TrackpadGesture(fingers: 3)
        _ = gesture.process(frame(3), surfaceSize: surface, at: 0)
        #expect(gesture.process(frame(4), surfaceSize: surface, at: 0.02).isEmpty)
        // Still blocked when lifting back down through three.
        #expect(gesture.process(frame(3), surfaceSize: surface, at: 0.5).isEmpty)
        #expect(gesture.process(frame(3), surfaceSize: surface, at: 0.6).isEmpty)
        #expect(gesture.process(frame(0), surfaceSize: surface, at: 0.7).isEmpty)
        // And works again once all fingers are up.
        _ = gesture.process(frame(3), surfaceSize: surface, at: 1)
        #expect(gesture.process(frame(3), surfaceSize: surface, at: 1.1).first == .began)
    }

    @Test func addingAFingerCancels() {
        var gesture = TrackpadGesture(fingers: 3)
        _ = gesture.process(frame(3), surfaceSize: surface, at: 0)
        _ = gesture.process(frame(3), surfaceSize: surface, at: 0.1)
        #expect(gesture.process(frame(4), surfaceSize: surface, at: 0.2) == [.cancelled])
    }

    @Test func ignoresOtherTrackpadsWhileActive() {
        var gesture = TrackpadGesture(fingers: 3)
        _ = gesture.process(frame(3, device: 1), surfaceSize: surface, at: 0)
        _ = gesture.process(frame(3, device: 1), surfaceSize: surface, at: 0.1)
        #expect(gesture.process(frame(0, device: 2), surfaceSize: surface, at: 0.2).isEmpty)
        #expect(gesture.process(frame(0, device: 1), surfaceSize: surface, at: 0.3) == [.ended])
    }

    @Test func parsesTrackpadFingers() throws {
        #expect(try Config.parse("trackpad_fingers = 3").trackpadFingers == 3)
        #expect(try Config.parse("").trackpadFingers == nil)
        #expect(throws: ConfigError.self) { try Config.parse("trackpad_fingers = 2") }
    }
}

@Suite struct ScrollSuppressionTests {
    @Test func dropsNothingWhenOff() {
        var suppression = ScrollSuppression()
        #expect(suppression.shouldDrop(scrollAt: 0) == false)
    }

    @Test func dropsDuringTheGestureAndWhileLifting() {
        var suppression = ScrollSuppression()
        suppression.gestureBegan()
        #expect(suppression.shouldDrop(scrollAt: 0) == true)
        suppression.gestureEnded(at: 1)
        suppression.fingersChanged(to: 2, at: 1.1)
        #expect(suppression.shouldDrop(scrollAt: 1.5) == true)
    }

    @Test func dropsCoastingUntilItGoesQuiet() {
        var suppression = ScrollSuppression()
        suppression.gestureBegan()
        suppression.gestureEnded(at: 1)
        // Lifting took longer than the quiet period; coasting starts from the lift.
        suppression.fingersChanged(to: 0, at: 1.5)
        #expect(suppression.shouldDrop(scrollAt: 1.52) == true)
        #expect(suppression.shouldDrop(scrollAt: 1.6) == true)
        #expect(suppression.shouldDrop(scrollAt: 1.7) == true)
        #expect(suppression.shouldDrop(scrollAt: 2.0) == false)
        #expect(!suppression.isActive)
    }

    @Test func touchingAgainStopsDropping() {
        var suppression = ScrollSuppression()
        suppression.gestureBegan()
        suppression.gestureEnded(at: 1)
        suppression.fingersChanged(to: 0, at: 1)
        suppression.fingersChanged(to: 2, at: 1.05)
        #expect(!suppression.isActive)
        #expect(suppression.shouldDrop(scrollAt: 1.06) == false)
    }

    @Test func givesUpAfterTheMaximum() {
        var suppression = ScrollSuppression()
        suppression.gestureBegan()
        suppression.gestureEnded(at: 0)
        suppression.fingersChanged(to: 0, at: 0)
        var time = 0.0
        while time < ScrollSuppression.maximumDuration - 0.1 {
            time += 0.05
            #expect(suppression.shouldDrop(scrollAt: time) == true)
        }
        #expect(suppression.shouldDrop(scrollAt: ScrollSuppression.maximumDuration + 0.01) == false)

        var lifting = ScrollSuppression()
        lifting.gestureBegan()
        lifting.gestureEnded(at: 0)
        #expect(lifting.shouldDrop(scrollAt: ScrollSuppression.maximumDuration + 0.01) == false)
    }
}

@Suite struct CursorMoverTests {
    /// Shaped like `CGWindowListCopyWindowInfo`'s entries, numbers as `NSNumber`.
    func window(pid: pid_t, layer: Int = 0, frame: CGRect, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: frame.dictionaryRepresentation,
            kCGWindowAlpha as String: NSNumber(value: alpha),
        ]
    }

    @Test func centersOnTheFrontWindow() {
        let windows = [
            window(pid: 1, layer: 101, frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
            window(pid: 2, frame: CGRect(x: 100, y: 50, width: 800, height: 600)),
            window(pid: 3, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
        ]
        #expect(CursorMover.center(ofFrontWindowOf: 2, in: windows) == CGPoint(x: 500, y: 350))
    }

    @Test func waitsUntilTheAppIsInFront() {
        let windows = [
            window(pid: 3, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
            window(pid: 2, frame: CGRect(x: 100, y: 50, width: 800, height: 600)),
        ]
        #expect(CursorMover.center(ofFrontWindowOf: 2, in: windows) == nil)
    }

    @Test func skipsTinyAndInvisibleWindows() {
        let windows = [
            window(pid: 3, frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            window(pid: 3, frame: CGRect(x: 0, y: 0, width: 400, height: 400), alpha: 0),
            window(pid: 2, frame: CGRect(x: 0, y: 0, width: 200, height: 100)),
        ]
        #expect(CursorMover.center(ofFrontWindowOf: 2, in: windows) == CGPoint(x: 100, y: 50))
    }

    @Test func parsesTheOption() throws {
        #expect(try Config.parse("").moveCursorToWindow)
        #expect(try Config.parse("move_cursor_to_window = false").moveCursorToWindow == false)
    }
}
