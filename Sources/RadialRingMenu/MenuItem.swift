import AppKit

import UniformTypeIdentifiers

/// An app resolved from an `AppSpec`, ready to show in the menu.
struct MenuItem {
    enum Target {
        /// An app bundle, opened (and launched if needed) through Launch Services.
        case app(url: URL, bundleID: String)
        /// A running process without a bundle, e.g. started with `cargo run`.
        /// Can only be switched to, not launched.
        case process(name: String)
    }

    var title: String
    var target: Target
    var icon: NSImage

    func runningApplication(in apps: [NSRunningApplication]) -> NSRunningApplication? {
        switch target {
        case .app(_, let bundleID):
            return apps.first { $0.bundleIdentifier == bundleID }
        case .process(let name):
            return apps.first {
                $0.activationPolicy != .prohibited
                    && ($0.localizedName == name || $0.executableURL?.lastPathComponent == name)
            }
        }
    }
}

struct AppResolutionError: Error, CustomStringConvertible {
    var spec: AppSpec
    var reason: String

    var description: String {
        let label = spec.path ?? spec.bundleID ?? spec.process ?? spec.name ?? "?"
        return "\(label): \(reason)"
    }
}

enum AppResolver {
    static func resolve(_ spec: AppSpec) throws(AppResolutionError) -> MenuItem {
        let customIcon = try loadCustomIcon(spec)

        if spec.path == nil, spec.bundleID == nil, let process = spec.process {
            // Looked up when switching, since it may not be running yet.
            return MenuItem(
                title: spec.name ?? process,
                target: .process(name: process),
                icon: customIcon ?? NSWorkspace.shared.icon(for: .unixExecutable)
            )
        }

        // Some apps are symlinks (e.g. /Applications/Safari.app), whose icon would
        // get an alias badge.
        let url = try locate(spec).resolvingSymlinksInPath()
        // Opening anything else, like a bare executable, would launch it in Terminal.
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            throw AppResolutionError(
                spec: spec,
                reason: "\(url.path) is not an app bundle, use `process` to switch to a running executable"
            )
        }
        let title = spec.name
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return MenuItem(
            title: title,
            target: .app(url: url, bundleID: bundleID),
            icon: customIcon ?? NSWorkspace.shared.icon(forFile: url.path)
        )
    }

    /// The `icon` override: an image file (PNG, ICNS, PDF, ...) or an app,
    /// whose icon is used.
    private static func loadCustomIcon(_ spec: AppSpec) throws(AppResolutionError) -> NSImage? {
        guard let path = spec.icon else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppResolutionError(spec: spec, reason: "icon \(path): no such file")
        }
        if url.pathExtension == "app" {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        guard let image = NSImage(contentsOf: url), image.isValid else {
            throw AppResolutionError(spec: spec, reason: "icon \(path): not an image")
        }
        return image
    }

    private static func locate(_ spec: AppSpec) throws(AppResolutionError) -> URL {
        let fileManager = FileManager.default

        if let path = spec.path {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw AppResolutionError(spec: spec, reason: "no such file")
            }
            return url
        }

        if let bundleID = spec.bundleID {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw AppResolutionError(spec: spec, reason: "no app with that bundle ID is installed")
            }
            return url
        }

        if let name = spec.name {
            let fileName = name.hasSuffix(".app") ? name : "\(name).app"
            for directory in searchDirectories() {
                let candidate = directory.appending(path: fileName, directoryHint: .isDirectory)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            throw AppResolutionError(
                spec: spec,
                reason: "not found in the usual app folders, set `bundle_id` or `path` instead, "
                    + "or `process` for an executable that isn't an app bundle"
            )
        }

        throw AppResolutionError(spec: spec, reason: "needs a `name`, `bundle_id`, `path` or `process`")
    }

    /// The standard app folders, plus one level of subfolders in the user-managed
    /// ones (e.g. `/Applications/Setapp`).
    private static func searchDirectories() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            home.appending(path: "Applications"),
        ]
        let system = [
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Library/CoreServices",
            "/System/Library/CoreServices/Applications",
        ].map { URL(fileURLWithPath: $0) }

        let subfolders = roots.flatMap { root -> [URL] in
            let contents = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return contents.filter {
                $0.pathExtension != "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
        return roots + system + subfolders
    }
}
