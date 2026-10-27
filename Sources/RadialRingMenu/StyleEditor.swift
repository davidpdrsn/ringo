import AppKit
import Observation
import SwiftUI

/// A window for trying out the style settings on a live preview of the menu,
/// and writing them to the config file.
@MainActor
final class StyleEditorWindowController: NSWindowController {
    let model: StyleEditorModel

    init(model: StyleEditorModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Style"
        window.contentView = NSHostingView(rootView: StyleEditorView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("StyleEditor")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The style settings being edited, and the config they started from.
@MainActor
@Observable
final class StyleEditorModel {
    let configURL: URL
    /// The config as last loaded from the file.
    private(set) var saved: Config
    var edited: Config
    private(set) var items: [MenuItem]
    /// Why applying the edits last failed.
    private(set) var problem: String?
    /// Bumped to replay the open animation in the preview.
    private(set) var replays = 0

    init(configURL: URL, config: Config, items: [MenuItem]) {
        self.configURL = configURL
        saved = config
        edited = config
        self.items = items
    }

    var hasChanges: Bool {
        edited.styleSettings != saved.styleSettings
    }

    /// Takes in the config after it's loaded from the file, keeping edits that
    /// haven't been applied yet.
    func configDidLoad(_ config: Config, items: [MenuItem]) {
        if !hasChanges {
            edited = config
        }
        saved = config
        self.items = items
    }

    func revert() {
        edited = saved
        problem = nil
    }

    func replay() {
        replays += 1
    }

    /// Writes the edited settings to the config file, leaving the rest of it as
    /// it is.
    func apply() {
        do {
            let text = try String(contentsOf: configURL, encoding: .utf8)
            let applied = try Config.applyingStyle(of: edited, to: text)
            try applied.write(to: configURL, atomically: true, encoding: .utf8)
            // As read back, so the numbers match the file exactly.
            saved = try Config.parse(applied)
            edited = saved
            problem = nil
        } catch let error as ConfigError {
            problem = error.description
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Views

private struct StyleEditorView: View {
    @Bindable var model: StyleEditorModel

    /// What a highlight without a width spans: one app's share of the ring, at
    /// most 90°.
    private var defaultHighlightWidth: Double {
        min(90, 360 / Double(max(model.items.count, 1)))
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                MenuPreview(config: model.edited, items: model.items, replays: model.replays)
                    .frame(minWidth: 460, minHeight: 460)
                Text("Move the mouse over the preview to point the highlights.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            }

            Divider()

            VStack(spacing: 0) {
                Form {
                    Section("Icons") {
                        NumberSlider("Distance", value: $model.edited.radius, in: 20...400, step: 1, unit: "pt")
                        NumberSlider("Size", value: $model.edited.iconSize, in: 16...200, step: 1, unit: "pt")
                        NumberSlider("Selected size", value: $model.edited.selectedIconScale, in: 0.5...3, step: 0.01, unit: "×")
                        NumberSlider("Others' opacity", value: $model.edited.unselectedIconOpacity, in: 0...1, step: 0.05, unit: "")
                        NumberSlider("Others' size", value: $model.edited.unselectedIconScale, in: 0.2...1, step: 0.01, unit: "×")
                        NumberSlider("Open animation", value: openAnimationMs, in: 0...1000, step: 5, unit: "ms")
                    }
                    Section("Outer ring") {
                        NumberSlider("Inner radius", value: $model.edited.outerRing.innerRadius, in: 0...400, step: 1, unit: "pt")
                        NumberSlider("Outer radius", value: $model.edited.outerRing.outerRadius, in: 1...400, step: 1, unit: "pt")
                        ColorRow("Tint", color: $model.edited.outerRing.color, fallback: .clear)
                    }
                    HighlightSection(
                        "Outer ring highlight",
                        style: $model.edited.outerRing.highlight,
                        defaultWidth: defaultHighlightWidth
                    )
                    Section("Inner ring") {
                        ColorRow("Color", color: $model.edited.innerRing.color, fallback: NSColor.white.withAlphaComponent(0.55).cgColor)
                    }
                    HighlightSection(
                        "Inner ring highlight",
                        style: $model.edited.innerRing.highlight,
                        defaultWidth: defaultHighlightWidth
                    )
                }
                .formStyle(.grouped)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if let problem = model.problem {
                        Text(problem)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Replay Animation") { model.replay() }
                        Spacer()
                        Button("Revert") { model.revert() }
                            .disabled(!model.hasChanges)
                        Button("Apply to Config") { model.apply() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("s")
                            .disabled(!model.hasChanges)
                    }
                }
                .padding(12)
            }
            .frame(width: 460)
        }
    }

    private var openAnimationMs: Binding<Double> {
        Binding(
            get: { model.edited.openAnimationDuration * 1000 },
            set: { model.edited.openAnimationDuration = $0 / 1000 }
        )
    }
}

private struct HighlightSection: View {
    var title: String
    @Binding var style: RingHighlight
    /// The width, in degrees, while it doesn't have one set.
    var defaultWidth: Double

    init(_ title: String, style: Binding<RingHighlight>, defaultWidth: Double) {
        self.title = title
        _style = style
        self.defaultWidth = defaultWidth
    }

    var body: some View {
        Section(title) {
            Picker("Shape", selection: $style.shape) {
                Text("Wedge").tag(RingHighlight.Shape.wedge)
                Text("Bubble").tag(RingHighlight.Shape.bubble)
            }
            .pickerStyle(.segmented)
            NumberSlider("Width", value: $style.width.or(defaultWidth), in: 1...360, step: 1, unit: "°")
            if style.shape == .wedge {
                NumberSlider("Fade", value: $style.fade.or((style.width ?? defaultWidth) / 10), in: 0...90, step: 0.5, unit: "°")
            }
            NumberSlider("Overhang", value: $style.overhang, in: 0...50, step: 0.5, unit: "pt")
            ColorRow("Color", color: $style.color, fallback: NSColor.controlAccentColor.cgColor)
            NumberSlider("Glow spread", value: $style.glowSpread, in: 0...50, step: 0.5, unit: "pt")
            NumberSlider("Glow blur", value: $style.glowBlur, in: 0...50, step: 0.5, unit: "pt")
            NumberSlider("Glow opacity", value: $style.glowOpacity, in: 0...1, step: 0.05, unit: "")
        }
    }
}

private struct NumberSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var unit: String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, unit: String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        LabeledContent {
            HStack {
                // Rounded by hand, since a stepped slider draws a tick for every step.
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                    .frame(minWidth: 160)
                Text(String(format: "%g", value) + (unit.isEmpty ? "" : " \(unit)"))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        } label: {
            // A fixed width, so the sliders line up.
            Text(title)
                .frame(width: 100, alignment: .leading)
        }
    }
}

private struct ColorRow: View {
    var title: String
    @Binding var color: RGBAColor?
    /// Shown while no color is set.
    var fallback: CGColor

    init(_ title: String, color: Binding<RGBAColor?>, fallback: CGColor) {
        self.title = title
        _color = color
        self.fallback = fallback
    }

    var body: some View {
        ColorPicker(
            title,
            selection: Binding(
                get: { color?.cgColor ?? fallback },
                set: { color = RGBAColor($0) }
            ),
            supportsOpacity: true
        )
    }
}

extension Binding where Value == Double? {
    /// The value, or `fallback` while it's `nil`. Setting it sets the value.
    fileprivate func or(_ fallback: Double) -> Binding<Double> {
        Binding<Double>(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }
}

extension RGBAColor {
    /// `color` in sRGB, rounded to what the config can hold.
    fileprivate init(_ color: CGColor) {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let components = (srgb?.components ?? [0, 0, 0, 1]).map { (Double($0) * 255).rounded() / 255 }
        self.init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }
}

// MARK: - Preview

private struct MenuPreview: NSViewRepresentable {
    var config: Config
    var items: [MenuItem]
    var replays: Int

    func makeNSView(context: Context) -> MenuPreviewView {
        MenuPreviewView(frame: .zero)
    }

    func updateNSView(_ view: MenuPreviewView, context: Context) {
        view.show(config, items: items, replays: replays)
    }
}

/// The menu, open in the middle of the view. The highlights follow the mouse
/// while it's over the view, and otherwise point at the first app.
@MainActor
private final class MenuPreviewView: NSView {
    private let menuView = RadialMenuView()
    private var layout = RadialLayout(count: 0, radius: 0, iconSize: 0)
    private var displayLink: CADisplayLink?
    private var occlusionObserver: NSObjectProtocol?
    private var shownSettings: [ConfigEdit] = []
    /// What the icons were laid out and drawn for.
    private var shownLayout: (titles: [String], radius: Double, iconSize: Double, selectedScale: Double)?
    private var shownReplays = 0
    /// Where the highlights pointed on the last frame.
    private var offset: CGPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        menuView.frame = bounds
        menuView.autoresizingMask = [.width, .height]
        addSubview(menuView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ config: Config, items: [MenuItem], replays: Int) {
        let titles = items.map(\.title)
        if let shown = shownLayout, shown.titles == titles, shown.radius == config.radius,
            shown.iconSize == config.iconSize, shown.selectedScale == config.selectedIconScale
        {
            let settings = config.styleSettings
            if settings != shownSettings {
                shownSettings = settings
                menuView.applyStyle(config)
            }
        } else {
            shownLayout = (titles, config.radius, config.iconSize, config.selectedIconScale)
            shownSettings = config.styleSettings
            layout = RadialLayout(count: items.count, radius: config.radius, iconSize: config.iconSize)
            menuView.configure(items: items, layout: layout, config: config)
            presentOpen()
        }
        if replays != shownReplays {
            shownReplays = replays
            present(at: CACurrentMediaTime())
        }
    }

    /// Shows the menu already open, so changes show right away.
    private func presentOpen() {
        let now = CACurrentMediaTime()
        present(at: now - 10)
        // Presenting draws the first frame of the open animation, with nothing
        // visible yet. Draw the open menu over it before it's shown, or every
        // change would flash a blank frame.
        let selection = layout.selection(for: offset)
        menuView.settle(selection: selection)
        menuView.update(time: now, selection: selection, pointer: offset)
    }

    private func present(at time: CFTimeInterval) {
        menuView.present(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            badges: Array(repeating: nil, count: layout.count),
            time: time
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        presentOpen()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = nil
        guard let window else { return }

        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Don't animate while the window can't be seen.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.displayLink?.isPaused = !window.occlusionState.contains(.visible)
            }
        }
        presentOpen()
    }

    @objc private func tick(_ link: CADisplayLink) {
        offset = layout.offset(of: 0)
        if let window {
            let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(mouse) {
                offset = CGPoint(x: mouse.x - bounds.midX, y: mouse.y - bounds.midY)
            }
        }
        menuView.update(time: link.targetTimestamp, selection: layout.selection(for: offset), pointer: offset)
    }
}
