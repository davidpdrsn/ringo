import Foundation
import TOMLDecoder

/// The user's configuration, loaded from `config.toml`.
struct Config: Equatable {
    var hotkey: Hotkey
    /// Distance from the center of the menu to the center of each icon, in points.
    var radius: Double
    var iconSize: Double
    /// Opens the menu when this many fingers rest on the trackpad. `nil` is off.
    var trackpadFingers: Int?
    /// Moves the cursor to the middle of the app's window after switching.
    var moveCursorToWindow: Bool
    /// An extra mouse button that opens the menu while held, counting from 1.
    var mouseButton: Int?
    var apps: [AppSpec]

    static let defaultHotkey = "option+space"
    static let defaultRadius = 110.0
    static let defaultIconSize = 64.0
}

/// One entry in the `[[apps]]` array. At least one field must be set.
///
/// The app is looked up by `path`, then `bundle_id`, then `process`, then
/// `name`. When `name` is set together with one of the others it's only used as
/// the label.
struct AppSpec: Equatable {
    var name: String?
    var bundleID: String?
    var path: String?
    /// The name of a running process that isn't an app bundle.
    var process: String?
    /// An image file or app to take the icon from, instead of the app's own.
    var icon: String?
}

enum ConfigError: Error, CustomStringConvertible {
    case parse(String)
    case invalid(String)
    case io(String)

    var description: String {
        switch self {
        case .parse(let message): "Couldn't parse config: \(message)"
        case .invalid(let message): "Invalid config: \(message)"
        case .io(let message): message
        }
    }
}

extension Config {
    static func parse(_ text: String) throws(ConfigError) -> Config {
        let raw: RawConfig
        do {
            raw = try TOMLDecoder().decode(RawConfig.self, from: text)
        } catch let error as ConfigError {
            throw error
        } catch {
            throw .parse(String(describing: error))
        }

        let hotkey: Hotkey
        do {
            hotkey = try Hotkey(parsing: raw.hotkey ?? defaultHotkey)
        } catch {
            throw .invalid("hotkey: \(error)")
        }

        let radius = raw.radius ?? defaultRadius
        guard radius > 0 else { throw .invalid("radius must be positive") }

        let iconSize = raw.iconSize ?? defaultIconSize
        guard (16...512).contains(iconSize) else {
            throw .invalid("icon_size must be between 16 and 512")
        }

        let apps = raw.apps ?? []
        if let index = apps.firstIndex(where: { $0.name == nil && $0.bundleID == nil && $0.path == nil && $0.process == nil }) {
            throw .invalid("apps[\(index)] needs a `name`, `bundle_id`, `path` or `process`")
        }

        if let button = raw.mouseButton, !(3...32).contains(button) {
            // 1 and 2 are the left and right buttons.
            throw .invalid("mouse_button must be between 3 and 32")
        }

        if let fingers = raw.trackpadFingers, !(3...5).contains(fingers) {
            // Fewer would fire on every scroll.
            throw .invalid("trackpad_fingers must be 3, 4 or 5")
        }

        return Config(
            hotkey: hotkey,
            radius: radius,
            iconSize: iconSize,
            trackpadFingers: raw.trackpadFingers,
            moveCursorToWindow: raw.moveCursorToWindow ?? true,
            mouseButton: raw.mouseButton,
            apps: apps
        )
    }

    /// `$XDG_CONFIG_HOME/radial-ring-menu/config.toml`, falling back to `~/.config`.
    static var defaultURL: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        }
        return base.appending(path: "radial-ring-menu/config.toml", directoryHint: .notDirectory)
    }

    /// Reads the config file, writing `template` there first if it doesn't exist.
    static func readOrCreate(at url: URL) throws(ConfigError) -> String {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw .io("Couldn't create \(url.path): \(error.localizedDescription)")
            }
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw .io("Couldn't read \(url.path): \(error.localizedDescription)")
        }
    }

    static let template = """
        # Radial Ring Menu
        #
        # Hold the hotkey to open the menu around the cursor, flick toward an app and
        # release (or click) to switch to it. Releasing in the middle cancels.
        #
        # The file is reloaded automatically when saved.

        # Modifiers: cmd, shift, option (alt), ctrl. Keys: a-z, 0-9, space, tab,
        # return, escape, f1-f20, arrows (left, right, up, down) and punctuation.
        # A modifier can also be used on its own, optionally from one side of the
        # keyboard: "left-option", "right-cmd", "option", ...
        hotkey = "option+space"

        # Distance from the cursor to the icons, and the icon size, in points.
        radius = 110
        icon_size = 64

        # Also open the menu by resting this many fingers (3-5) on the trackpad.
        # Slide them toward an app and lift to switch; adding a finger cancels.
        # System gestures with the same number of fingers still fire, so you may
        # want to move those to another count in System Settings → Trackpad.
        # Grant the Accessibility permission so the fingers' movement doesn't also
        # scroll the app you switch to.
        # trackpad_fingers = 3

        # Move the cursor to the middle of the app's window after switching to it.
        move_cursor_to_window = true

        # Also open the menu while holding this mouse button. Buttons count from 1
        # (1 is left, 2 right, 3 middle, 4 and 5 usually the side buttons); use
        # "Identify Mouse Button…" in the menu bar menu to find yours. The button
        # stops doing anything else. Needs the Accessibility permission.
        # mouse_button = 5

        # Apps are laid out clockwise starting at the top.
        # Each entry needs a `name`, `bundle_id` or `path`. A `name` alone is looked
        # up in /Applications and the system app folders. For a running executable
        # that isn't an app bundle (e.g. started with `cargo run`), use
        # `process = "<process name>"`; it can be switched to but not launched.
        # Any entry can set `icon` to an image file (PNG, ICNS, ...) or an app to
        # use instead of its own icon.

        [[apps]]
        name = "Finder"

        [[apps]]
        name = "Safari"

        [[apps]]
        name = "Mail"

        [[apps]]
        name = "Calendar"

        [[apps]]
        name = "Notes"

        [[apps]]
        bundle_id = "com.apple.Terminal"

        [[apps]]
        name = "Music"

        [[apps]]
        name = "System Settings"

        """
}

// MARK: - Decoding

private struct RawConfig: Decodable {
    var hotkey: String?
    var radius: Double?
    var iconSize: Double?
    var trackpadFingers: Int?
    var moveCursorToWindow: Bool?
    var mouseButton: Int?
    var apps: [AppSpec]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkey
        case radius
        case iconSize = "icon_size"
        case trackpadFingers = "trackpad_fingers"
        case moveCursorToWindow = "move_cursor_to_window"
        case mouseButton = "mouse_button"
        case apps
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self, context: "the config")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey)
        radius = try container.decodeNumberIfPresent(forKey: .radius)
        iconSize = try container.decodeNumberIfPresent(forKey: .iconSize)
        trackpadFingers = try container.decodeIfPresent(Int.self, forKey: .trackpadFingers)
        moveCursorToWindow = try container.decodeIfPresent(Bool.self, forKey: .moveCursorToWindow)
        mouseButton = try container.decodeIfPresent(Int.self, forKey: .mouseButton)
        apps = try container.decodeIfPresent([AppSpec].self, forKey: .apps)
    }
}

extension AppSpec: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case bundleID = "bundle_id"
        case path
        case process
        case icon
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self, context: "[[apps]]")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        process = try container.decodeIfPresent(String.self, forKey: .process)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Catches typos like `icon_szie` that would otherwise be silently ignored.
private func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(
    in decoder: any Decoder,
    allowed: Keys.Type,
    context: String
) throws {
    let allowed = Set(Keys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: AnyKey.self)
    if let unknown = container.allKeys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) {
        throw ConfigError.invalid("unknown key `\(unknown)` in \(context)")
    }
}

extension KeyedDecodingContainer {
    /// TOML distinguishes integers from floats; accept either.
    fileprivate func decodeNumberIfPresent(forKey key: Key) throws -> Double? {
        guard contains(key) else { return nil }
        if let int = try? decode(Int.self, forKey: key) {
            return Double(int)
        }
        return try decode(Double.self, forKey: key)
    }
}
