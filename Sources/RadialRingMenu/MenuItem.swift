import AppKit

/// An app resolved from an `AppSpec`, ready to show in the menu.
struct MenuItem {
    var title: String
    var url: URL
    var bundleID: String?
    var icon: NSImage
}

struct AppResolutionError: Error, CustomStringConvertible {
    var spec: AppSpec
    var reason: String

    var description: String {
        let label = spec.path ?? spec.bundleID ?? spec.name ?? "?"
        return "\(label): \(reason)"
    }
}

enum AppResolver {
    static func resolve(_ spec: AppSpec) throws(AppResolutionError) -> MenuItem {
        // Some apps are symlinks (e.g. /Applications/Safari.app), whose icon would
        // get an alias badge.
        let url = try locate(spec).resolvingSymlinksInPath()
        // Opening anything else, like a bare executable, would launch it in Terminal.
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier != nil else {
            throw AppResolutionError(spec: spec, reason: "\(url.path) is not an app bundle")
        }
        let title = spec.name
            ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return MenuItem(
            title: title,
            url: url,
            bundleID: bundle.bundleIdentifier,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
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
                reason: "not found in the usual app folders, set `bundle_id` or `path` instead"
            )
        }

        throw AppResolutionError(spec: spec, reason: "needs a `name`, `bundle_id` or `path`")
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
