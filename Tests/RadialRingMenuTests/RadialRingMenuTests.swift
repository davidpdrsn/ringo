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
    /// The message `text` fails to parse with.
    private func errorMessage(_ text: String) -> String? {
        do {
            _ = try Config.parse(text)
            return nil
        } catch {
            return error.description
        }
    }

    @Test func parsesFullConfig() throws {
        let config = try Config.parse("""
            hotkey = "cmd+shift+k"

            [icons]
            radius = 140
            size = 48.5

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
        #expect(config.openAnimationDuration == Config.defaultOpenAnimationMs / 1000)
        #expect(config.outerRing.color == nil)
        #expect(config.outerRing.highlight == .outerDefault)
        #expect(config.innerRing.color == nil)
        #expect(config.innerRing.highlight == .innerDefault)
        #expect(config.apps.isEmpty)
    }

    @Test func parsesOpenAnimation() throws {
        #expect(try Config.parse("open_animation_ms = 300").openAnimationDuration == 0.3)
        #expect(try Config.parse("open_animation_ms = 0").openAnimationDuration == 0)
        #expect(throws: ConfigError.self) { try Config.parse("open_animation_ms = -1") }
        #expect(throws: ConfigError.self) { try Config.parse("open_animation_ms = 5000") }
    }

    @Test func parsesSelectedAndUnselectedIcons() throws {
        let config = try Config.parse("[icons]\nselected_scale = 1.5\nunselected_opacity = 0.3")
        #expect(config.selectedIconScale == 1.5)
        #expect(config.unselectedIconOpacity == 0.3)
        let defaults = try Config.parse("")
        #expect(defaults.selectedIconScale == Config.defaultSelectedIconScale)
        #expect(defaults.unselectedIconOpacity == Config.defaultUnselectedIconOpacity)
        #expect(throws: ConfigError.self) { try Config.parse("[icons]\nselected_scale = 0.2") }
        #expect(throws: ConfigError.self) { try Config.parse("[icons]\nselected_scale = 4") }
        #expect(throws: ConfigError.self) { try Config.parse("[icons]\nunselected_opacity = 1.5") }
    }

    @Test func pointsMovedSettingsToTheirNewPlace() {
        #expect(errorMessage("icon_size = 64")?.contains("`size` under `[icons]`") == true)
        #expect(errorMessage("radius = 110")?.contains("`radius` under `[icons]`") == true)
    }

    @Test func namesTheTableOfAnUnknownKey() {
        #expect(errorMessage("[icons]\nsise = 50")?.contains("[icons]") == true)
        #expect(errorMessage("[outer_ring.highlight]\nwidht = 50")?.contains("[outer_ring.highlight]") == true)
    }

    @Test func parsesOuterRing() throws {
        let config = try Config.parse("""
            [outer_ring]
            inner_radius = 70
            outer_radius = 130.5
            color = "#00000080"
            """)
        #expect(config.outerRing.innerRadius == 70)
        #expect(config.outerRing.outerRadius == 130.5)
        #expect(config.outerRing.color == RGBAColor(red: 0, green: 0, blue: 0, alpha: 128.0 / 255))
    }

    @Test func derivesOuterRingFromIcons() throws {
        let config = try Config.parse("[icons]\nradius = 100\nsize = 50")
        #expect(config.outerRing.innerRadius == 100 - 50 * Config.defaultOuterRingHalfWidthRatio)
        #expect(config.outerRing.outerRadius == 100 + 50 * Config.defaultOuterRingHalfWidthRatio)
        // Setting one edge leaves the other at its default.
        let inner = try Config.parse("[outer_ring]\ninner_radius = 60")
        #expect(inner.outerRing.outerRadius == Config.defaultRadius + Config.defaultIconSize * Config.defaultOuterRingHalfWidthRatio)
    }

    @Test func rejectsBadOuterRing() {
        #expect(throws: ConfigError.self) { try Config.parse("[outer_ring]\ninner_radius = -1") }
        #expect(throws: ConfigError.self) { try Config.parse("[outer_ring]\ninner_radius = 100\nouter_radius = 100") }
        // Only an outer edge inside the default inner one.
        #expect(throws: ConfigError.self) { try Config.parse("[outer_ring]\nouter_radius = 50") }
    }

    @Test func parsesBothHighlightsTheSameWay() throws {
        let style = """
            shape = "bubble"
            width = 75
            fade = 2.5
            overhang = 1
            color = "#FF8800"
            glow_spread = 2
            glow_blur = 6
            glow_opacity = 0.8
            """
        let expected = RingHighlight(
            shape: .bubble, width: 75, fade: 2.5, overhang: 1,
            color: RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 1),
            glowSpread: 2, glowBlur: 6, glowOpacity: 0.8
        )
        #expect(try Config.parse("[outer_ring.highlight]\n" + style).outerRing.highlight == expected)
        #expect(try Config.parse("[inner_ring.highlight]\n" + style).innerRing.highlight == expected)
    }

    @Test func keepsEachHighlightsOwnDefaults() throws {
        let config = try Config.parse("[outer_ring.highlight]\nglow_blur = 4\n\n[inner_ring.highlight]\nwidth = 90")
        var outer = RingHighlight.outerDefault
        outer.glowBlur = 4
        #expect(config.outerRing.highlight == outer)
        var inner = RingHighlight.innerDefault
        inner.width = 90
        #expect(config.innerRing.highlight == inner)
    }

    @Test func parsesInnerRingColor() throws {
        let config = try Config.parse("[inner_ring]\ncolor = \"#ffffff80\"")
        #expect(config.innerRing.color == RGBAColor(red: 1, green: 1, blue: 1, alpha: 128.0 / 255))
    }

    @Test func rejectsBadColors() {
        for bad in ["FF8800", "#FF88", "#FF880", "#GG8800", "#+F8800", "#FF8800801"] {
            #expect(throws: ConfigError.self) { try Config.parse("[inner_ring]\ncolor = \"\(bad)\"") }
        }
        #expect(throws: ConfigError.self) { try Config.parse("[outer_ring]\ncolor = \"black\"") }
        #expect(throws: ConfigError.self) { try Config.parse("[outer_ring.highlight]\ncolor = \"white\"") }
    }

    @Test func rejectsBadHighlights() {
        let bad = [
            "shape = \"blob\"", "width = 0", "width = 400", "fade = -1", "fade = 200",
            "overhang = -1", "overhang = 60", "glow_spread = -1", "glow_spread = 60",
            "glow_blur = -1", "glow_blur = 60", "glow_opacity = -0.1", "glow_opacity = 1.5",
        ]
        for setting in bad {
            #expect(throws: ConfigError.self) { try Config.parse("[outer_ring.highlight]\n\(setting)") }
            #expect(throws: ConfigError.self) { try Config.parse("[inner_ring.highlight]\n\(setting)") }
        }
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

    @Test func parsesHideCursor() throws {
        let config = try Config.parse("""
            [[apps]]
            name = "Ghostty"
            hide_cursor = true

            [[apps]]
            name = "Safari"
            """)
        #expect(config.apps == [AppSpec(name: "Ghostty", hideCursor: true), AppSpec(name: "Safari")])
        #expect(throws: ConfigError.self) { try Config.parse("[[apps]]\nname = \"Ghostty\"\nhide_cursor = \"yes\"") }
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

    @Test func carriesHideCursor() throws {
        #expect(try AppResolver.resolve(AppSpec(process: "some-process", hideCursor: true)).hideCursor)
        #expect(try AppResolver.resolve(AppSpec(path: "/System/Applications/Calculator.app", hideCursor: true)).hideCursor)
        #expect(try !AppResolver.resolve(AppSpec(process: "some-process")).hideCursor)
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

@Suite struct DockBadgeTests {
    @Test func readsTheLabel() {
        #expect(DockBadge.label(from: ["label": "1"] as NSDictionary) == "1")
        #expect(DockBadge.label(from: ["label": "\u{2022}"] as NSDictionary) == "\u{2022}")
    }

    @Test func treatsMissingOrEmptyAsNoBadge() {
        #expect(DockBadge.label(from: nil) == nil)
        #expect(DockBadge.label(from: ["label": ""] as NSDictionary) == nil)
        #expect(DockBadge.label(from: ["other": 1] as NSDictionary) == nil)
    }
}

@Suite struct MouseButtonConfigTests {
    @Test func parsesMouseButton() throws {
        #expect(try Config.parse("mouse_button = 5").mouseButton == 5)
        #expect(try Config.parse("").mouseButton == nil)
    }

    @Test func rejectsLeftAndRightClick() {
        #expect(throws: ConfigError.self) { try Config.parse("mouse_button = 1") }
        #expect(throws: ConfigError.self) { try Config.parse("mouse_button = 2") }
    }
}

@Suite struct MenuBarIconConfigTests {
    @Test func showsTheIconByDefault() throws {
        #expect(try Config.parse("").showMenuBarIcon)
        #expect(try Config.parse("show_menu_bar_icon = false").showMenuBarIcon == false)
    }
}

@Suite struct ConfigEditTests {
    @Test func changesAValueInPlaceKeepingItsComment() {
        let text = "hotkey = \"x\"\n\n[icons]\nradius = 110  # far out\nsize = 64\n"
        let edited = ConfigEdit.apply([ConfigEdit(table: "icons", key: "radius", value: "120")], to: text)
        #expect(edited == "hotkey = \"x\"\n\n[icons]\nradius = 120  # far out\nsize = 64\n")
    }

    @Test func changesAColorKeepingItsComment() {
        let text = "[inner_ring]\ncolor = \"#6867AF\" # purple\n"
        let edited = ConfigEdit.apply([ConfigEdit(table: "inner_ring", key: "color", value: "\"#112233\"")], to: text)
        #expect(edited == "[inner_ring]\ncolor = \"#112233\" # purple\n")
    }

    @Test func onlyChangesTheSettingInItsOwnTable() {
        let text = "[outer_ring]\ncolor = \"#000000\"\n\n[inner_ring]\ncolor = \"#000000\"\n"
        let edited = ConfigEdit.apply([ConfigEdit(table: "inner_ring", key: "color", value: "\"#FFFFFF\"")], to: text)
        #expect(edited == "[outer_ring]\ncolor = \"#000000\"\n\n[inner_ring]\ncolor = \"#FFFFFF\"\n")
    }

    @Test func addsASettingAfterTheLastOneInItsTable() {
        let text = "[outer_ring]\ninner_radius = 80\n# color = \"#000000\"\n\n[[apps]]\nname = \"A\"\n"
        let edited = ConfigEdit.apply([ConfigEdit(table: "outer_ring", key: "outer_radius", value: "130")], to: text)
        #expect(edited == "[outer_ring]\ninner_radius = 80\nouter_radius = 130\n# color = \"#000000\"\n\n[[apps]]\nname = \"A\"\n")
    }

    @Test func addsAMissingTableBeforeTheApps() {
        let text = "hotkey = \"x\"\n\n# The apps.\n[[apps]]\nname = \"A\"\n"
        let edited = ConfigEdit.apply([ConfigEdit(table: "inner_ring", key: "color", value: "\"#FFFFFF\"")], to: text)
        #expect(edited == "hotkey = \"x\"\n\n[inner_ring]\ncolor = \"#FFFFFF\"\n\n# The apps.\n[[apps]]\nname = \"A\"\n")
    }

    @Test func addsASettingOutsideTablesBeforeTheFirstTable() {
        let text = "hotkey = \"x\"\n\n[icons]\nsize = 64\n"
        let edited = ConfigEdit.apply([ConfigEdit(table: nil, key: "open_animation_ms", value: "125")], to: text)
        #expect(edited == "hotkey = \"x\"\nopen_animation_ms = 125\n\n[icons]\nsize = 64\n")
    }

    @Test func removesASetting() {
        let text = "[inner_ring]\ncolor = \"#000000\"\n"
        #expect(ConfigEdit.apply([ConfigEdit(table: "inner_ring", key: "color", value: nil)], to: text) == "[inner_ring]\n")
    }

    @Test func leavesTheAppsAlone() {
        let text = "hotkey = \"x\"\n\n[[apps]]\nname = \"A\"\n"
        let edited = ConfigEdit.apply([ConfigEdit(table: nil, key: "name", value: "\"B\"")], to: text)
        #expect(edited == "hotkey = \"x\"\nname = \"B\"\n\n[[apps]]\nname = \"A\"\n")
    }

    @Test func applyingAnUnchangedStyleChangesNothing() throws {
        let text = Config.template
        #expect(try Config.applyingStyle(of: Config.parse(text), to: text) == text)
    }

    @Test func appliesOnlyTheChangedSettings() throws {
        let text = "hotkey = \"x\"\n\n[outer_ring.highlight]\nshape = \"bubble\" # round\n"
        var config = try Config.parse(text)
        config.outerRing.highlight.shape = .wedge
        config.innerRing.highlight.glowOpacity = 0.5
        let applied = try Config.applyingStyle(of: config, to: text)
        #expect(applied == "hotkey = \"x\"\n\n[outer_ring.highlight]\nshape = \"wedge\" # round\n\n[inner_ring.highlight]\nglow_opacity = 0.5\n")
    }

    @Test func keepsSettingsThatWouldFollowOthersWhereTheyWere() throws {
        // The outer ring's edges follow the icon size unless they're set.
        let text = "[icons]\nsize = 64\n"
        var config = try Config.parse(text)
        config.iconSize = 100
        let applied = try Config.parse(Config.applyingStyle(of: config, to: text))
        #expect(applied.styleSettings == config.styleSettings)
    }

    @Test func writesColorsAsHex() {
        #expect(RGBAColor(red: 1, green: 136.0 / 255, blue: 0, alpha: 1).hex == "#FF8800")
        #expect(RGBAColor(red: 0, green: 0, blue: 0, alpha: 128.0 / 255).hex == "#00000080")
    }
}

@MainActor
@Suite struct StyleEditorTests {
    private func temporaryConfig(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "radial-ring-menu-style-\(UUID().uuidString).toml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func appliesEditsToTheConfigFile() throws {
        let text = "hotkey = \"x\"\n\n# The apps.\n[[apps]]\nname = \"Safari\"\n"
        let url = try temporaryConfig(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = StyleEditorModel(configURL: url, config: try Config.parse(text), items: [])
        model.edited.innerRing.highlight.glowOpacity = 0.5
        #expect(model.hasChanges)

        model.apply()
        #expect(model.problem == nil)
        #expect(!model.hasChanges)
        #expect(try String(contentsOf: url, encoding: .utf8)
            == "hotkey = \"x\"\n\n[inner_ring.highlight]\nglow_opacity = 0.5\n\n# The apps.\n[[apps]]\nname = \"Safari\"\n")
    }

    @Test func leavesTheFileAloneWhenTheEditsAreInvalid() throws {
        let text = "hotkey = \"x\"\n"
        let url = try temporaryConfig(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = StyleEditorModel(configURL: url, config: try Config.parse(text), items: [])
        // Inside the inner edge.
        model.edited.outerRing.outerRadius = 10

        model.apply()
        #expect(model.problem != nil)
        #expect(model.hasChanges)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func keepsUnappliedEditsWhenTheFileReloads() throws {
        let config = try Config.parse("")
        let model = StyleEditorModel(configURL: URL(fileURLWithPath: "/dev/null"), config: config, items: [])
        model.edited.iconSize = 100
        var reloaded = config
        reloaded.radius = 150
        model.configDidLoad(reloaded, items: [])
        #expect(model.edited.iconSize == 100)
        #expect(model.saved.radius == 150)
    }
}
