import AppKit
import QuartzCore

/// Owns the menu panel and the hold → flick → release interaction.
///
/// - Holding the hotkey opens the menu around the cursor, and it only stays open
///   while the hotkey is held.
/// - Releasing the key (or any of its modifiers) switches to the app the cursor
///   points at, or cancels if the cursor is still in the dead zone.
/// - Left click picks the app the cursor points at, or cancels from the center.
/// - Right click or Escape cancels.
/// - Tab swaps the configured apps for the other running ones, most recent
///   first, and back. The configured ring always opens first, so its apps keep
///   their places.
/// - With a modifier-only hotkey, typing a key or pressing another modifier
///   while holding it cancels, since that's someone typing ⌥E or using a
///   shortcut rather than reaching for the menu.
/// - Holding an extra mouse button (`mouse_button`) works like the hotkey.
/// - Resting fingers on the trackpad (`trackpad_fingers`) works the same way:
///   moving them picks a direction, lifting them switches, and adding a finger
///   cancels.
/// - With `switch_back_tap_ms`, a quick tap of the hotkey, mouse button or
///   fingers that doesn't point at an app switches back to the app in front
///   before. The inner ring changes color while letting go would do that.
@MainActor
final class RadialMenuController: NSObject {
    private enum Phase {
        case closed
        /// Opened by holding the hotkey; releasing it decides.
        case holding(openedAt: CFTimeInterval)
        /// Opened without the hotkey (Preview Menu); stays until a click or Escape.
        case sticky
        /// Opened by fingers on the trackpad; lifting them decides.
        case trackpad(openedAt: CFTimeInterval)
        /// Opened by holding an extra mouse button; releasing it decides.
        case mouseButton(openedAt: CFTimeInterval)

        /// When the hotkey, mouse button or fingers went down, for telling a tap
        /// from a hold.
        var pressedAt: CFTimeInterval? {
            switch self {
            case .holding(let openedAt), .trackpad(let openedAt), .mouseButton(let openedAt): openedAt
            case .closed, .sticky: nil
            }
        }
    }

    private enum Ring {
        case apps
        case recent
    }

    private var phase = Phase.closed
    private var config: Config?
    /// The configured apps.
    private var appItems: [MenuItem] = []
    private var appLayout = RadialLayout(count: 0, radius: 0, iconSize: 0)
    /// Which apps the ring shows, and the app in each place around it (`nil`
    /// for an empty one).
    private var ring = Ring.apps
    private var items: [MenuItem?] = []
    /// Where each recent app goes, kept between openings so they stay put.
    private var recentSlots = RecentSlots<NSRunningApplication>()
    private var layout = RadialLayout(count: 0, radius: 0, iconSize: 0)
    /// Whether Tab has swapped the ring since it opened, which rules out a tap.
    private var switchedRings = false
    /// Whether Tab is held, so its key repeats don't swap the ring again.
    private var tabIsDown = false
    /// When Tab last went down or up, so a modifier-only hotkey doesn't take it
    /// for typing.
    private var lastTabEventAt: CFTimeInterval = 0
    private var hotkey: Hotkey?
    private var iconSize: CGFloat = 0
    private var moveCursorToWindow = true
    private var switchBackTapDuration: CFTimeInterval?
    private let cursorMover = CursorMover()
    private let cursorHider = CursorHider()
    private let recentApps = RecentApps()

    private let panel = RadialMenuPanel()
    private let menuView = RadialMenuView()
    private var displayLink: CADisplayLink?
    /// Escape and Tab, registered while the menu is open.
    private var menuHotKeys: [HotKeyRegistration] = []
    /// The menu's center in global AppKit screen coordinates.
    private var center: CGPoint = .zero
    /// How far the fingers have moved, standing in for the cursor in `.trackpad`.
    private var trackpadOffset: CGPoint = .zero
    /// Takes the panel off screen once the ring has faded out.
    private var pendingHide: DispatchWorkItem?

    var isOpen: Bool {
        if case .closed = phase { false } else { true }
    }

    override init() {
        super.init()
        panel.contentView = menuView
        menuView.onMouseDown = { [weak self] button in
            self?.mouseDown(button)
        }
    }

    func configure(items: [MenuItem], config: Config) {
        if isOpen { close() }
        self.config = config
        appItems = items
        ring = .apps
        self.items = items
        hotkey = config.hotkey
        iconSize = config.iconSize
        moveCursorToWindow = config.moveCursorToWindow
        switchBackTapDuration = config.switchBackTapDuration
        layout = RadialLayout(count: items.count, radius: config.radius, iconSize: config.iconSize)
        appLayout = layout
        menuView.configure(items: items, layout: layout, config: config)
    }

    func handle(_ event: HotKeyCenter.Event) {
        switch (event, phase) {
        case (.pressed, .closed):
            open(.holding(openedAt: CACurrentMediaTime()))
        case (.pressed, .sticky):
            close()
        case (.released, .holding):
            triggerReleased()
        case (.pressed, .holding), (.pressed, .trackpad), (.pressed, .mouseButton), (.released, _):
            // Key repeat, the trackpad already has the menu open, or a release
            // with nothing held open.
            break
        }
    }

    func handleMouseButton(_ event: HotKeyCenter.Event) {
        switch (event, phase) {
        case (.pressed, .closed):
            open(.mouseButton(openedAt: CACurrentMediaTime()))
        case (.released, .mouseButton):
            released()
        default:
            // Something else has the menu open.
            break
        }
    }

    func handle(_ event: TrackpadGesture.Event) {
        switch (event, phase) {
        case (.began, .closed):
            trackpadOffset = .zero
            open(.trackpad(openedAt: CACurrentMediaTime()))
        case (.moved(let offset), .trackpad):
            trackpadOffset = offset
        case (.ended, .trackpad):
            released()
        case (.cancelled, .trackpad):
            close()
        default:
            // The hotkey already has the menu open.
            break
        }
    }

    /// Opens the menu without the hotkey held, e.g. for `--preview`.
    func openSticky() {
        guard !isOpen else { return }
        open(.sticky)
    }

    // MARK: - Opening and closing

    private func open(_ phase: Phase) {
        guard !appItems.isEmpty, let config else {
            NSSound.beep()
            return
        }

        if ring != .apps {
            ring = .apps
            items = appItems
            layout = appLayout
            menuView.configure(items: items, layout: layout, config: config)
        }
        switchedRings = false
        tabIsDown = false

        // Don't move the cursor from under the menu if the last switch is still waiting.
        cursorMover.cancel()
        cursorHider.show()

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }

        center = clampedCenter(for: mouse, in: screen.frame)
        if center != mouse {
            warpCursor(to: center)
        }

        pendingHide?.cancel()
        pendingHide = nil
        panel.setFrame(screen.frame, display: false)
        // Through the animator, to cancel a fade-out still running from the last close.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            menuView.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        NSCursor.arrow.set()

        self.phase = phase
        let now = CACurrentMediaTime()
        menuView.present(at: toView(center), badges: badges(for: items), time: now, switchingBack: isSwitchBackTap(at: now))

        let link = menuView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        register("escape") { [weak self] event in
            if event == .pressed { self?.close() }
        }
        register("tab") { [weak self] event in
            self?.tab(event)
        }
    }

    /// Registers `key` for while the menu is open. Carbon hotkeys only match the
    /// exact modifiers, and the hotkey's are still down while it's held, so it's
    /// registered both on its own and with those.
    private func register(_ key: String, handler: @escaping (HotKeyCenter.Event) -> Void) {
        guard let plain = try? KeyCombo(parsing: key) else { return }
        var combos = [plain]
        if let modifiers = hotkey?.modifiers, !modifiers.isEmpty {
            var held = plain
            held.modifiers = modifiers
            combos.append(held)
        }
        menuHotKeys += combos.compactMap { combo in
            // The key may be the hotkey itself, which handles its own press and release.
            if case .combo(let hotkeyCombo) = hotkey,
               hotkeyCombo.keyCode == combo.keyCode, hotkeyCombo.modifiers == combo.modifiers {
                return nil
            }
            return try? HotKeyCenter.shared.register(combo, handler: handler)
        }
    }

    private func badges(for items: [MenuItem?]) -> [String?] {
        let runningApps = NSWorkspace.shared.runningApplications
        return items.map { item in
            item?.runningApplication(in: runningApps).flatMap { DockBadge.label(for: $0.processIdentifier) }
        }
    }

    // MARK: - Recent apps

    private func tab(_ event: HotKeyCenter.Event) {
        lastTabEventAt = CACurrentMediaTime()
        switch event {
        case .pressed:
            guard !tabIsDown else { return }
            tabIsDown = true
            swapRing()
        case .released:
            tabIsDown = false
        }
    }

    /// Swaps the configured apps for the recent ones, or back.
    private func swapRing() {
        guard isOpen, let config else { return }
        switch ring {
        case .apps:
            // Those already in the configured ring are a flick away there.
            let recent = recentApps.recent.filter { app in
                !appItems.contains { $0.runningApplication(in: [app]) != nil }
            }
            guard !recent.isEmpty else {
                NSSound.beep()
                return
            }
            ring = .recent
            items = recentSlots.place(recent).map { $0.map(MenuItem.init(running:)) }
            layout = RadialLayout(count: items.count, radius: config.radius, iconSize: config.iconSize)
        case .recent:
            ring = .apps
            items = appItems
            layout = appLayout
        }
        switchedRings = true
        menuView.show(
            items: items,
            layout: layout,
            config: config,
            badges: badges(for: items),
            caption: ring == .recent ? "Recent" : nil,
            time: CACurrentMediaTime()
        )
    }

    /// The configured item for `app`, for its settings and so an app with no
    /// windows opens one, or else one that just switches to it.
    private func menuItem(for app: NSRunningApplication) -> MenuItem {
        appItems.first { $0.runningApplication(in: [app]) != nil } ?? MenuItem(running: app)
    }

    private func close(activating item: MenuItem? = nil) {
        guard isOpen else { return }
        phase = .closed
        displayLink?.invalidate()
        displayLink = nil
        for registration in menuHotKeys {
            registration.unregister()
        }
        menuHotKeys = []

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            menuView.animator().alphaValue = 0
        }
        hidePanel(after: 0.1)

        if let item {
            activate(item)
        }
    }

    private func hidePanel(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Switches back to the app in front before the current one, like a quick ⌘Tab.
    private func switchBack() {
        guard let app = recentApps.previous else {
            NSSound.beep()
            return
        }
        activate(menuItem(for: app))
    }

    private func activate(_ item: MenuItem) {
        switch item.target {
        case .app(let url, _):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
                if let error {
                    NSLog("Couldn't open %@: %@", url.path, error.localizedDescription)
                }
                guard let pid = app?.processIdentifier else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.switched(to: pid, hideCursor: item.hideCursor) }
                }
            }
        case .process, .running:
            guard let app = item.runningApplication(in: NSWorkspace.shared.runningApplications) else {
                NSSound.beep()
                return
            }
            activate(app)
            switched(to: app.processIdentifier, hideCursor: item.hideCursor)
        }
    }

    private func activate(_ app: NSRunningApplication) {
        if app.isHidden {
            app.unhide()
        }
        // Since macOS 14 a background app's request to activate another app is
        // ignored, unless it asks to be active itself and hands activation over.
        NSApp.activate()
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    private func switched(to pid: pid_t, hideCursor: Bool) {
        // The menu may have opened again while the app was launching.
        guard !isOpen else { return }
        if hideCursor {
            cursorHider.hide(while: pid)
        }
        if moveCursorToWindow {
            cursorMover.moveCursor(toFrontWindowOf: pid)
        }
    }

    // MARK: - Tracking

    @objc private func tick(_ link: CADisplayLink) {
        guard isOpen else { return }

        if case .holding(let openedAt) = phase, let hotkey {
            if wasUsedForTyping(since: openedAt) {
                close()
                return
            }
            if !NSEvent.modifierFlags.contains(hotkey.modifierFlags) {
                // Letting go of a modifier counts as letting go of the hotkey.
                triggerReleased()
                if !isOpen { return }
            }
        }

        let offset = pointerOffset()
        let selection = selection(for: offset)
        menuView.update(
            time: link.targetTimestamp,
            selection: selection,
            pointer: offset,
            switchingBack: selection == nil && isSwitchBackTap(at: link.targetTimestamp)
        )
    }

    private func triggerReleased() {
        guard case .holding(let openedAt) = phase else { return }
        if wasUsedForTyping(since: openedAt) {
            close()
        } else {
            released()
        }
    }

    /// Switches to the app the pointer points at. Otherwise cancels, or after a
    /// quick tap switches back to the previous app.
    private func released() {
        let selection = selection(for: pointerOffset())
        if selection == nil && isSwitchBackTap(at: CACurrentMediaTime()) {
            close()
            switchBack()
        } else {
            close(activating: selection.flatMap { items[$0] })
        }
    }

    /// Whether the press is still short enough that letting go without pointing
    /// at an app switches back.
    private func isSwitchBackTap(at time: CFTimeInterval) -> Bool {
        guard let switchBackTapDuration, let pressedAt = phase.pressedAt, !switchedRings else { return false }
        return time - pressedAt < switchBackTapDuration
    }

    /// Whether a modifier-only hotkey has been combined with other keys since
    /// `openedAt`. Doesn't apply to key combos, where the key itself counts as a
    /// key press, or to Tab, which swaps the ring.
    private func wasUsedForTyping(since openedAt: CFTimeInterval) -> Bool {
        guard case .modifier(let key) = hotkey, !tabIsDown else { return false }
        let otherModifiers = NSEvent.modifierFlags
            .intersection([.control, .option, .shift, .command])
            .subtracting(key.modifierFlags)
        let secondsSinceKeyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let since = max(openedAt, lastTabEventAt)
        return !otherModifiers.isEmpty || secondsSinceKeyDown < CACurrentMediaTime() - since
    }

    private func mouseDown(_ button: RadialMenuView.MouseButton) {
        guard isOpen else { return }
        switch button {
        case .left:
            close(activating: selection(for: pointerOffset()).flatMap { items[$0] })
        case .right:
            close()
        }
    }

    // MARK: - Geometry

    /// The place `offset` points at, unless it's empty.
    private func selection(for offset: CGPoint) -> Int? {
        layout.selection(for: offset).flatMap { items[$0] == nil ? nil : $0 }
    }

    /// Where the user is pointing, relative to the menu's center.
    private func pointerOffset() -> CGPoint {
        if case .trackpad = phase {
            return trackpadOffset
        }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - center.x, y: mouse.y - center.y)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
    }

    /// Keeps the whole ring on screen when opened near an edge.
    private func clampedCenter(for point: CGPoint, in frame: CGRect) -> CGPoint {
        // Half an icon, plus room for the backdrop edge and the label.
        let extent = layout.radius + iconSize / 2 + 40
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low > high ? (low + high) / 2 : min(max(value, low), high)
        }
        return CGPoint(
            x: clamp(point.x, frame.minX + extent, frame.maxX - extent),
            y: clamp(point.y, frame.minY + extent, frame.maxY - extent)
        )
    }

    private func warpCursor(to point: CGPoint) {
        // CoreGraphics uses a top-left origin relative to the primary screen.
        guard let primary = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primary.frame.maxY - point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

/// A transparent, full-screen panel that never activates the app, so the
/// frontmost app keeps focus until we switch away from it.
final class RadialMenuPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        // Nearly invisible, but non-zero alpha so clicks anywhere land on the panel.
        backgroundColor = NSColor(white: 0, alpha: 0.004)
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
