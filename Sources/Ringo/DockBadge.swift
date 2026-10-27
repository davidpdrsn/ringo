import Foundation

/// Reads the badge apps show on their Dock icon, like Discord's unread count.
///
/// Apps hand the badge to the Dock through LaunchServices, which keeps it as the
/// `StatusLabel` of each running app. There's no public API for another app's
/// badge, so this reads it back with private LaunchServices calls.
enum DockBadge {
    static func label(for pid: pid_t) -> String? {
        guard
            let launchServices = LaunchServices.shared,
            let asn = launchServices.createASN(nil, pid)?.takeRetainedValue()
        else { return nil }
        let statusLabel = launchServices.copyItem(defaultSessionID, asn, "StatusLabel" as CFString)?.takeRetainedValue()
        return label(from: statusLabel)
    }

    /// `StatusLabel` is a dictionary like `{ label = "1" }`.
    static func label(from statusLabel: Any?) -> String? {
        guard let label = (statusLabel as? [String: Any])?["label"] as? String, !label.isEmpty else { return nil }
        return label
    }
}

/// `kLSDefaultSessionID`.
private let defaultSessionID: Int32 = -2

private struct LaunchServices: @unchecked Sendable {
    let createASN: @convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?
    let copyItem: @convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?

    static let shared = load()

    private static func load() -> LaunchServices? {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices"
        guard
            let handle = dlopen(path, RTLD_NOW),
            let createASN = dlsym(handle, "_LSASNCreateWithPid"),
            let copyItem = dlsym(handle, "_LSCopyApplicationInformationItem")
        else { return nil }
        return LaunchServices(
            createASN: unsafeBitCast(createASN, to: (@convention(c) (CFAllocator?, pid_t) -> Unmanaged<CFTypeRef>?).self),
            copyItem: unsafeBitCast(copyItem, to: (@convention(c) (Int32, CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?).self)
        )
    }
}
