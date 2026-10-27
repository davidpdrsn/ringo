import Foundation
import TOMLDecoder

/// The user's configuration, loaded from `config.toml`.
struct Config: Equatable {
    var hotkey: Hotkey
    /// Distance from the center of the menu to the center of each icon, in points.
    var radius: Double
    var iconSize: Double
    /// How much bigger the selected app's icon gets.
    var selectedIconScale: Double
    /// How opaque the other apps' icons are while one is selected.
    var unselectedIconOpacity: Double
    /// How long icons take to fan out when the menu opens, in seconds.
    var openAnimationDuration: Double
    var outerRing: OuterRing
    var innerRing: InnerRing
    /// Opens the menu when this many fingers rest on the trackpad. `nil` is off.
    var trackpadFingers: Int?
    /// Moves the cursor to the middle of the app's window after switching.
    var moveCursorToWindow: Bool
    /// An extra mouse button that opens the menu while held, counting from 1.
    var mouseButton: Int?
    var showMenuBarIcon: Bool
    var apps: [AppSpec]

    static let defaultHotkey = "option+space"
    static let defaultRadius = 110.0
    static let defaultIconSize = 64.0
    static let defaultSelectedIconScale = 1.22
    static let defaultUnselectedIconOpacity = 0.55
    static let defaultOpenAnimationMs = 180.0
    /// By default the outer ring reaches this fraction of the icon size to either
    /// side of `radius`. Less than a half, so the icons stick out past its edges.
    static let defaultOuterRingHalfWidthRatio = 0.3
}

/// The grey ring behind the icons.
struct OuterRing: Equatable {
    /// How far the ring's edges are from the center, in points.
    var innerRadius: Double
    var outerRadius: Double
    /// Laid over the blurred ring, which shows through it below full opacity.
    /// `nil` leaves just the blur.
    var color: RGBAColor?
    var highlight: RingHighlight
}

/// The small circle in the middle.
struct InnerRing: Equatable {
    /// `nil` is a translucent white.
    var color: RGBAColor?
    var highlight: RingHighlight
}

/// The lit part of a ring in the direction of the cursor.
struct RingHighlight: Equatable {
    enum Shape: String, Equatable {
        /// Fills the ring's width, fading out at both ends.
        case wedge
        /// An arc with rounded ends.
        case bubble
    }

    var shape: Shape
    /// In degrees. `nil` is one app's share of the ring, up to 90. A bubble's
    /// rounded ends reach past it.
    var width: Double?
    /// How far a wedge fades out past each end, in degrees. `nil` is a tenth of
    /// its width.
    var fade: Double?
    /// How far it reaches past both edges of the ring, in points.
    var overhang: Double
    /// Also used for the glow. `nil` is the system accent color.
    var color: RGBAColor?
    /// Like CSS's `box-shadow`: how far the solid part of the glow reaches past
    /// the highlight, and how far its edge fades out over, both in points.
    var glowSpread: Double
    var glowBlur: Double
    /// From 0 to 1.
    var glowOpacity: Double

    static let outerDefault = RingHighlight(
        shape: .wedge, width: nil, fade: nil, overhang: 0, color: nil,
        glowSpread: 0, glowBlur: 0, glowOpacity: 0.3
    )
    /// The arc the inner ring has always had.
    static let innerDefault = RingHighlight(
        shape: .bubble, width: 72, fade: nil, overhang: 1, color: nil,
        glowSpread: 0, glowBlur: 3, glowOpacity: 0.8
    )
}

/// An sRGB color, written in the config as `"#RRGGBB"` or `"#RRGGBBAA"`.
struct RGBAColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

extension RGBAColor {
    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard
            digits.count == 6 || digits.count == 8,
            digits.allSatisfy(\.isHexDigit),
            let value = UInt32(digits, radix: 16)
        else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        func channel(_ shift: UInt32) -> Double { Double(rgba >> shift & 0xFF) / 255 }
        self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    /// `"#RRGGBB"`, or `"#RRGGBBAA"` when it isn't opaque.
    var hex: String {
        let channels = [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
        return channels[3] == 255 ? rgb : rgb + String(format: "%02X", channels[3])
    }
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
    /// Hides the cursor after switching to the app, until the mouse moves.
    var hideCursor = false
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

        let radius = raw.icons?.radius ?? defaultRadius
        guard radius > 0 else { throw .invalid("icons.radius must be positive") }

        let iconSize = raw.icons?.size ?? defaultIconSize
        guard (16...512).contains(iconSize) else {
            throw .invalid("icons.size must be between 16 and 512")
        }
        let selectedIconScale = try checked(raw.icons?.selectedScale, in: 0.5...3, key: "icons.selected_scale")
            ?? defaultSelectedIconScale
        let unselectedIconOpacity = try checked(raw.icons?.unselectedOpacity, in: 0...1, key: "icons.unselected_opacity")
            ?? defaultUnselectedIconOpacity

        let openAnimationMs = raw.openAnimationMs ?? defaultOpenAnimationMs
        guard (0...1000).contains(openAnimationMs) else {
            throw .invalid("open_animation_ms must be between 0 and 1000")
        }

        let outerInnerRadius = raw.outerRing?.innerRadius ?? max(0, radius - iconSize * defaultOuterRingHalfWidthRatio)
        let outerOuterRadius = raw.outerRing?.outerRadius ?? radius + iconSize * defaultOuterRingHalfWidthRatio
        guard outerInnerRadius >= 0 else { throw .invalid("outer_ring.inner_radius can't be negative") }
        guard outerOuterRadius > outerInnerRadius else {
            throw .invalid("outer_ring.outer_radius (\(outerOuterRadius)) must be larger than outer_ring.inner_radius (\(outerInnerRadius))")
        }
        let outerRing = OuterRing(
            innerRadius: outerInnerRadius,
            outerRadius: outerOuterRadius,
            color: try parseColor(raw.outerRing?.color, key: "outer_ring.color"),
            highlight: try RingHighlight(raw.outerRing?.highlight, defaults: .outerDefault, table: "outer_ring.highlight")
        )
        let innerRing = InnerRing(
            color: try parseColor(raw.innerRing?.color, key: "inner_ring.color"),
            highlight: try RingHighlight(raw.innerRing?.highlight, defaults: .innerDefault, table: "inner_ring.highlight")
        )

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
            selectedIconScale: selectedIconScale,
            unselectedIconOpacity: unselectedIconOpacity,
            openAnimationDuration: openAnimationMs / 1000,
            outerRing: outerRing,
            innerRing: innerRing,
            trackpadFingers: raw.trackpadFingers,
            moveCursorToWindow: raw.moveCursorToWindow ?? true,
            mouseButton: raw.mouseButton,
            showMenuBarIcon: raw.showMenuBarIcon ?? true,
            apps: apps
        )
    }

    fileprivate static func parseColor(_ hex: String?, key: String) throws(ConfigError) -> RGBAColor? {
        guard let hex else { return nil }
        guard let color = RGBAColor(hex: hex) else {
            throw .invalid("\(key) must be a color like \"#FF8800\", or \"#FF880080\" with alpha")
        }
        return color
    }

    /// `value`, after checking it's within `range`.
    fileprivate static func checked(_ value: Double?, in range: ClosedRange<Double>, key: String) throws(ConfigError) -> Double? {
        guard let value else { return nil }
        guard range.contains(value) else {
            throw .invalid(String(format: "%@ must be between %g and %g", key, range.lowerBound, range.upperBound))
        }
        return value
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

        # Also open the menu by resting this many fingers (3-5) on the trackpad.
        # Slide them toward an app and lift to switch; adding a finger cancels.
        # System gestures with the same number of fingers still fire, so you may
        # want to move those to another count in System Settings → Trackpad.
        # Grant the Accessibility permission so the fingers' movement doesn't also
        # scroll the app you switch to.
        # trackpad_fingers = 3

        # Also open the menu while holding this mouse button. Buttons count from 1
        # (1 is left, 2 right, 3 middle, 4 and 5 usually the side buttons); use
        # "Identify Mouse Button…" in the menu bar menu to find yours. The button
        # stops doing anything else. Needs the Accessibility permission.
        # mouse_button = 5

        # Move the cursor to the middle of the app's window after switching to it.
        move_cursor_to_window = true

        # Hide the icon in the menu bar. Open the app again while it's running to
        # bring the icon back until the config is next reloaded.
        # show_menu_bar_icon = false

        # How long the icons take to fan out when the menu opens, in milliseconds.
        # 0 shows them right away.
        open_animation_ms = 180

        # How far the icons are from the cursor, and their size, in points.
        [icons]
        radius = 110
        size = 64
        # How much bigger the selected app's icon gets, and how opaque the others
        # are while one is selected, from 0 to 1.
        # selected_scale = 1.22
        # unselected_opacity = 0.55

        # Colors below are "#RRGGBB", or "#RRGGBBAA" where the last two digits are
        # the opacity.

        # The grey ring behind the icons: how far its edges are from the cursor, in
        # points, and a color laid over it (partly transparent tints the ring,
        # opaque replaces it). By default it's a bit narrower than the icons, so
        # they stick out of it, and there's only the blur. If the apps don't fit at
        # the radius and the menu grows to make room, the ring grows with it.
        [outer_ring]
        # inner_radius = 90
        # outer_radius = 130
        # color = "#00000080"

        # The part of the ring in the direction of the cursor.
        #   shape: "wedge" fills the ring's width and fades out at its ends.
        #     "bubble" is an arc with rounded ends, which reach past its width.
        #   width: in degrees. By default one app's share of the ring, at most 90.
        #   fade: how far a wedge fades out past each end, in degrees. By default
        #     a tenth of its width.
        #   overhang: how far it reaches past both edges of the ring, in points.
        #   color: also used for the glow. The system accent color by default.
        #   glow_spread, glow_blur: like CSS's box-shadow, how far the solid part
        #     of the glow reaches past the highlight, and how far its edge fades
        #     out over, in points.
        #   glow_opacity: how strong the glow is, from 0 to 1.
        [outer_ring.highlight]
        # shape = "wedge"
        # width = 60
        # fade = 6
        # overhang = 0
        # color = "#FF9500"
        # glow_spread = 0
        # glow_blur = 0
        # glow_opacity = 0.3

        # The small circle in the middle. A translucent white by default.
        [inner_ring]
        # color = "#FFFFFF8C"

        # Its highlight takes the same settings as the outer ring's, and by default
        # is a bubble in the system accent color.
        [inner_ring.highlight]
        # shape = "bubble"
        # width = 72
        # overhang = 1
        # glow_blur = 3
        # glow_opacity = 0.8

        # Apps are laid out clockwise starting at the top.
        # Each entry needs a `name`, `bundle_id` or `path`. A `name` alone is looked
        # up in /Applications and the system app folders. For a running executable
        # that isn't an app bundle (e.g. started with `cargo run`), use
        # `process = "<process name>"`; it can be switched to but not launched.
        # Any entry can set `icon` to an image file (PNG, ICNS, ...) or an app to
        # use instead of its own icon, and `hide_cursor = true` to hide the cursor
        # after switching to it, until the mouse moves.

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
    var openAnimationMs: Double?
    var trackpadFingers: Int?
    var moveCursorToWindow: Bool?
    var mouseButton: Int?
    var showMenuBarIcon: Bool?
    var icons: RawIcons?
    var outerRing: RawOuterRing?
    var innerRing: RawInnerRing?
    var apps: [AppSpec]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkey
        case openAnimationMs = "open_animation_ms"
        case trackpadFingers = "trackpad_fingers"
        case moveCursorToWindow = "move_cursor_to_window"
        case mouseButton = "mouse_button"
        case showMenuBarIcon = "show_menu_bar_icon"
        case icons
        case outerRing = "outer_ring"
        case innerRing = "inner_ring"
        case apps
    }

    /// Settings that have moved, and where to.
    static let renamed = [
        "radius": "`radius` under `[icons]`",
        "icon_size": "`size` under `[icons]`",
    ]

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self, renamed: Self.renamed)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey)
        openAnimationMs = try container.decodeNumberIfPresent(forKey: .openAnimationMs)
        trackpadFingers = try container.decodeIfPresent(Int.self, forKey: .trackpadFingers)
        moveCursorToWindow = try container.decodeIfPresent(Bool.self, forKey: .moveCursorToWindow)
        mouseButton = try container.decodeIfPresent(Int.self, forKey: .mouseButton)
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon)
        icons = try container.decodeIfPresent(RawIcons.self, forKey: .icons)
        outerRing = try container.decodeIfPresent(RawOuterRing.self, forKey: .outerRing)
        innerRing = try container.decodeIfPresent(RawInnerRing.self, forKey: .innerRing)
        apps = try container.decodeIfPresent([AppSpec].self, forKey: .apps)
    }
}

private struct RawIcons: Decodable {
    var radius: Double?
    var size: Double?
    var selectedScale: Double?
    var unselectedOpacity: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case radius
        case size
        case selectedScale = "selected_scale"
        case unselectedOpacity = "unselected_opacity"
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        radius = try container.decodeNumberIfPresent(forKey: .radius)
        size = try container.decodeNumberIfPresent(forKey: .size)
        selectedScale = try container.decodeNumberIfPresent(forKey: .selectedScale)
        unselectedOpacity = try container.decodeNumberIfPresent(forKey: .unselectedOpacity)
    }
}

private struct RawOuterRing: Decodable {
    var innerRadius: Double?
    var outerRadius: Double?
    var color: String?
    var highlight: RawRingHighlight?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case innerRadius = "inner_radius"
        case outerRadius = "outer_radius"
        case color
        case highlight
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        innerRadius = try container.decodeNumberIfPresent(forKey: .innerRadius)
        outerRadius = try container.decodeNumberIfPresent(forKey: .outerRadius)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        highlight = try container.decodeIfPresent(RawRingHighlight.self, forKey: .highlight)
    }
}

private struct RawInnerRing: Decodable {
    var color: String?
    var highlight: RawRingHighlight?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case color
        case highlight
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        highlight = try container.decodeIfPresent(RawRingHighlight.self, forKey: .highlight)
    }
}

private struct RawRingHighlight: Decodable {
    var shape: String?
    var width: Double?
    var fade: Double?
    var overhang: Double?
    var color: String?
    var glowSpread: Double?
    var glowBlur: Double?
    var glowOpacity: Double?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case shape
        case width
        case fade
        case overhang
        case color
        case glowSpread = "glow_spread"
        case glowBlur = "glow_blur"
        case glowOpacity = "glow_opacity"
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shape = try container.decodeIfPresent(String.self, forKey: .shape)
        width = try container.decodeNumberIfPresent(forKey: .width)
        fade = try container.decodeNumberIfPresent(forKey: .fade)
        overhang = try container.decodeNumberIfPresent(forKey: .overhang)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        glowSpread = try container.decodeNumberIfPresent(forKey: .glowSpread)
        glowBlur = try container.decodeNumberIfPresent(forKey: .glowBlur)
        glowOpacity = try container.decodeNumberIfPresent(forKey: .glowOpacity)
    }
}

extension RingHighlight {
    /// `defaults`, with whatever `raw` sets from the `[table]` in the config.
    fileprivate init(_ raw: RawRingHighlight?, defaults: RingHighlight, table: String) throws(ConfigError) {
        self = defaults
        guard let raw else { return }
        if let name = raw.shape {
            guard let shape = Shape(rawValue: name) else {
                throw .invalid("\(table).shape must be \"wedge\" or \"bubble\"")
            }
            self.shape = shape
        }
        if let width = raw.width {
            guard width > 0 && width <= 360 else {
                throw .invalid("\(table).width must be more than 0 and at most 360")
            }
            self.width = width
        }
        fade = try Config.checked(raw.fade, in: 0...180, key: "\(table).fade") ?? fade
        overhang = try Config.checked(raw.overhang, in: 0...50, key: "\(table).overhang") ?? overhang
        color = try Config.parseColor(raw.color, key: "\(table).color") ?? color
        glowSpread = try Config.checked(raw.glowSpread, in: 0...50, key: "\(table).glow_spread") ?? glowSpread
        glowBlur = try Config.checked(raw.glowBlur, in: 0...50, key: "\(table).glow_blur") ?? glowBlur
        glowOpacity = try Config.checked(raw.glowOpacity, in: 0...1, key: "\(table).glow_opacity") ?? glowOpacity
    }
}

extension AppSpec: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case bundleID = "bundle_id"
        case path
        case process
        case icon
        case hideCursor = "hide_cursor"
    }

    init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(in: decoder, allowed: CodingKeys.self, context: "[[apps]]")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        process = try container.decodeIfPresent(String.self, forKey: .process)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        hideCursor = try container.decodeIfPresent(Bool.self, forKey: .hideCursor) ?? false
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Catches typos like `icon_szie` that would otherwise be silently ignored, and
/// points `renamed` settings to their new place. `context` defaults to the
/// table being decoded.
private func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(
    in decoder: any Decoder,
    allowed: Keys.Type,
    context: String? = nil,
    renamed: [String: String] = [:]
) throws {
    let allowed = Set(Keys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: AnyKey.self)
    guard let unknown = container.allKeys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) else {
        return
    }
    if let newPlace = renamed[unknown] {
        throw ConfigError.invalid("`\(unknown)` is now \(newPlace)")
    }
    let table = decoder.codingPath.map(\.stringValue).joined(separator: ".")
    throw ConfigError.invalid("unknown key `\(unknown)` in \(context ?? (table.isEmpty ? "the config" : "[\(table)]"))")
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
