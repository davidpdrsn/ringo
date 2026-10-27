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
    private var watcher: ConfigWatcher?

    /// The config text last applied, so saves that don't change anything are skipped.
    private var loadedText: String?
    private var isShowingAlert = false
    private var reloadAfterAlert = false

    init(configURL: URL, previewOnLaunch: Bool) {
        self.configURL = configURL
        self.previewOnLaunch = previewOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        reloadConfig(force: true)
        watcher = ConfigWatcher(url: configURL) { [weak self] in
            self?.reloadConfig(force: false)
        }
        if previewOnLaunch {
            controller.openSticky()
        }
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

        controller.configure(items: items, config: config)
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
        alert.messageText = "Problem with the Radial Ring Menu config"
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
        item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Radial Ring Menu")

        let menu = NSMenu()
        hotkeyMenuItem.isEnabled = false
        menu.addItem(hotkeyMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preview Menu", action: #selector(previewMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Config…", action: #selector(openConfig), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfigFromMenu), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Radial Ring Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func previewMenu() {
        // Let the status menu finish closing first.
        DispatchQueue.main.async { [controller] in
            controller.openSticky()
        }
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
