import Foundation

/// Calls `onChange` shortly after the config file is written.
///
/// Watches both the file (for in-place writes) and its directory (for editors
/// that save by writing a new file and renaming it over the old one).
@MainActor
final class ConfigWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        directorySource = Self.watch(path: url.deletingLastPathComponent().path, events: .write) { [weak self] in
            self?.changed()
        }
        watchFile()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = Self.watch(path: url.path, events: [.write, .extend, .delete, .rename]) { [weak self] in
            self?.changed()
        }
    }

    private func changed() {
        // The file may have been replaced, so start watching the new one.
        watchFile()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private static func watch(
        path: String,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }
}
