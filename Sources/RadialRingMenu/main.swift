import AppKit

let usage = """
    Usage: RadialRingMenu [--config <path>] [--check] [--preview]

      --config <path>  Use this config file instead of \(Config.defaultURL.path)
      --check          Validate the config, list the apps it resolves to and exit
      --preview        Open the menu as soon as the app starts
    """

var configURL = Config.defaultURL
var check = false
var preview = false

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--config":
        guard let path = arguments.next() else {
            FileHandle.standardError.write(Data("--config needs a path\n".utf8))
            exit(2)
        }
        configURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    case "--check":
        check = true
    case "--preview":
        preview = true
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        // macOS passes things like -NSDocumentRevisionsDebugMode when launched from Xcode.
        if !argument.hasPrefix("-NS") && !argument.hasPrefix("-Apple") {
            FileHandle.standardError.write(Data("Unknown argument \(argument)\n\n\(usage)\n".utf8))
            exit(2)
        }
    }
}

if check {
    exit(checkConfig(at: configURL))
}

let app = NSApplication.shared
let delegate = AppDelegate(configURL: configURL, previewOnLaunch: preview)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

/// Prints what the config resolves to. Returns the process exit code.
func checkConfig(at url: URL) -> Int32 {
    print("Config: \(url.path)")
    let config: Config
    do {
        config = try Config.parse(try Config.readOrCreate(at: url))
    } catch {
        print("✗ \(error)")
        return 1
    }
    print("Hotkey: \(config.hotkey)")
    print("Apps (clockwise from the top):")
    var failed = false
    for spec in config.apps {
        do {
            let item = try AppResolver.resolve(spec)
            let app = item.runningApplication(in: NSWorkspace.shared.runningApplications)
            let badge = app.flatMap { DockBadge.label(for: $0.processIdentifier) }.map { " [badge \($0)]" } ?? ""
            switch item.target {
            case .app(let url, _):
                print("  ✓ \(item.title) — \(url.path)\(badge)")
            case .process(let name):
                print("  ✓ \(item.title) — process \"\(name)\" (\(app != nil ? "running" : "not running"))\(badge)")
            }
        } catch {
            failed = true
            print("  ✗ \(error)")
        }
    }
    return failed ? 1 : 0
}
