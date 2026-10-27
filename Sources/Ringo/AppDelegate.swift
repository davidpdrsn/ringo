import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configURL: URL
    private let previewOnLaunch: Bool
    private let controller = RadialMenuController()

    private var statusItem: NSStatusItem?
    private let hotkeyMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var hotKey: (any HotKeyHandle)?
    private var registeredHotkey: Hotkey?
    private var trackpadMonitor: TrackpadMonitor?
    private let mouseButtons = MouseButtonMonitor()
    private var identifyTimeout: DispatchWorkItem?
    private var watcher: ConfigWatcher?
    private var styleEditor: StyleEditorWindowController?

    /// The config and apps last loaded, for the style editor.
    private var config: Config?
    private var items: [MenuItem] = []

    /// The config text last applied, so saves that don't change anything are skipped.
    private var loadedText: String?
    private var isShowingAlert = false
    private var reloadAfterAlert = false

    init(configURL: URL, previewOnLaunch: Bool) {
        self.configURL = configURL
        self.previewOnLaunch = previewOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mouseButtons.handler = { [weak self] event in
            self?.controller.handleMouseButton(event)
        }
        setUpStatusItem()
        reloadConfig(force: true)
        watcher = ConfigWatcher(url: configURL) { [weak self] in
            self?.reloadConfig(force: false)
        }
        if previewOnLaunch {
            controller.openSticky()
        }
    }

    /// Opening the app again while it's running brings back a hidden menu bar
    /// icon, since that's the only way to reach its menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        return false
    }

    // MARK: - Config

    private func reloadConfig(force: Bool) {
        if isShowingAlert {
            reloadAfterAlert = true
            return
        }

        let text: String
        let config: Config
        do {
            text = try Config.readOrCreate(at: configURL)
            guard force || text != loadedText else { return }
            loadedText = text
            config = try Config.parse(text)
        } catch {
            showProblems([error.description])
            return
        }

        var problems: [String] = []
        var items: [MenuItem] = []
        for spec in config.apps {
            do {
                items.append(try AppResolver.resolve(spec))
            } catch {
                problems.append(error.description)
            }
        }

        if hotKey == nil || registeredHotkey != config.hotkey {
            hotKey?.unregister()
            hotKey = nil
            registeredHotkey = nil
            do {
                hotKey = try config.hotkey.register { [weak self] event in
                    self?.controller.handle(event)
                }
                registeredHotkey = config.hotkey
            } catch {
                problems.append(error.description)
            }
        }

        if trackpadMonitor?.fingers != config.trackpadFingers {
            trackpadMonitor?.stop()
            trackpadMonitor = nil
            if let fingers = config.trackpadFingers {
                do {
                    trackpadMonitor = try TrackpadMonitor(fingers: fingers) { [weak self] event in
                        self?.controller.handle(event)
                    }
                } catch {
                    problems.append(error.description)
                }
            }
        }

        if config.mouseButton != nil && !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        if !mouseButtons.configure(button: config.mouseButton) {
            problems.append(Self.needsAccessibility("mouse_button"))
        }

        controller.configure(items: items, config: config)
        self.config = config
        self.items = items
        styleEditor?.model.configDidLoad(config, items: items)
        statusItem?.isVisible = config.showMenuBarIcon
        hotkeyMenuItem.title = registeredHotkey.map { "Hold \($0) to open" } ?? "No hotkey registered"

        if !problems.isEmpty {
            showProblems(problems)
        }
    }

    private func showProblems(_ problems: [String]) {
        isShowingAlert = true
        defer {
            isShowingAlert = false
            if reloadAfterAlert {
                reloadAfterAlert = false
                reloadConfig(force: false)
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Problem with the Ringo config"
        alert.informativeText = problems.joined(separator: "\n\n") + "\n\n" + configURL.path
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Config")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            openConfig()
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Ringo")

        let menu = NSMenu()
        hotkeyMenuItem.isEnabled = false
        menu.addItem(hotkeyMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preview Menu", action: #selector(previewMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Edit Style…", action: #selector(editStyle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Identify Mouse Button…", action: #selector(identifyMouseButton), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Config…", action: #selector(openConfig), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfigFromMenu), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Ringo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private static func needsAccessibility(_ feature: String) -> String {
        "\(feature) needs the Accessibility permission. Allow Ringo under System Settings → "
            + "Privacy & Security → Accessibility, then reload the config."
    }

    /// Waits for the next extra mouse button press and says which number it is,
    /// since what macOS calls a button doesn't always match its label.
    @objc private func identifyMouseButton() {
        let started = mouseButtons.identifyNextButton { [weak self] number in
            self?.finishIdentifying()
            let alert = NSAlert()
            alert.messageText = "That was mouse button \(number)"
            alert.informativeText = "To open the menu while holding it, put this in your config:\n\nmouse_button = \(number)"
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open Config")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn {
                self?.openConfig()
            }
        }
        guard started else {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            showProblems([Self.needsAccessibility("Identifying mouse buttons")])
            return
        }

        // The menu bar item says what to do until a button is pressed.
        statusItem?.length = NSStatusItem.variableLength
        statusItem?.button?.image = nil
        statusItem?.button?.title = "Press a mouse button…"
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.mouseButtons.cancelIdentify()
                self?.finishIdentifying()
            }
        }
        identifyTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func finishIdentifying() {
        identifyTimeout?.cancel()
        identifyTimeout = nil
        statusItem?.button?.title = ""
        statusItem?.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Ringo")
        statusItem?.length = NSStatusItem.squareLength
    }

    @objc private func previewMenu() {
        // Let the status menu finish closing first.
        DispatchQueue.main.async { [controller] in
            controller.openSticky()
        }
    }

    @objc private func editStyle() {
        guard let config else {
            // Shows what's wrong with it.
            reloadConfig(force: true)
            return
        }
        let editor = styleEditor ?? StyleEditorWindowController(
            model: StyleEditorModel(configURL: configURL, config: config, items: items)
        )
        styleEditor = editor
        editor.showWindow(nil)
        NSApp.activate()
    }

    @objc private func openConfig() {
        if !NSWorkspace.shared.open(configURL) {
            // No app is registered for .toml files.
            NSWorkspace.shared.open(
                [configURL],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    @objc private func reloadConfigFromMenu() {
        reloadConfig(force: true)
    }
}
