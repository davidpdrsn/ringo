import AppKit
import QuartzCore

/// Draws the ring of app icons and animates it frame by frame.
///
/// `RadialMenuController` drives it by calling `update(time:selection:pointer:)`
/// from a display link, so all animation here is computed by hand rather than
/// with Core Animation transactions.
@MainActor
final class RadialMenuView: NSView {
    enum MouseButton {
        case left
        case right
    }

    var onMouseDown: ((MouseButton) -> Void)?

    private var itemLayers: [ItemLayers] = []
    private var layout = RadialLayout(count: 0, radius: 0, iconSize: 0)
    private var iconSize: CGFloat = 64
    private var openDuration: CFTimeInterval = 0.18
    private var backdropOuterRadius: CGFloat = 0
    private var rasterScale: CGFloat = 0

    private var center: CGPoint = .zero
    private var openedAt: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval?
    private var pointerOpacity: CGFloat = 0
    private var labelOpacity: CGFloat = 0
    private var labelIndex: Int?

    private let backdrop = NSVisualEffectView()
    private let overlay = NSView()
    private let centerRing = CAShapeLayer()
    private let pointer = CAShapeLayer()
    private let labelBackground = CALayer()
    private let label = CATextLayer()

    /// Each icon starts this fraction of `openDuration` after the one before it.
    private static let staggerRatio = 1.0 / 15
    private static let centerRingRadius: CGFloat = 13
    private static let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.alphaValue = 0
        addSubview(backdrop)

        overlay.wantsLayer = true
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)

        let ringPath = CGPath(
            ellipseIn: CGRect(x: -Self.centerRingRadius, y: -Self.centerRingRadius, width: Self.centerRingRadius * 2, height: Self.centerRingRadius * 2),
            transform: nil
        )
        centerRing.path = ringPath
        centerRing.fillColor = NSColor.black.withAlphaComponent(0.3).cgColor
        centerRing.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        centerRing.lineWidth = 2.5

        let arcHalfWidth = CGFloat.pi * 0.2
        let arcPath = CGMutablePath()
        arcPath.addArc(center: .zero, radius: Self.centerRingRadius, startAngle: -arcHalfWidth, endAngle: arcHalfWidth, clockwise: false)
        pointer.path = arcPath
        pointer.fillColor = nil
        pointer.strokeColor = NSColor.controlAccentColor.cgColor
        pointer.lineWidth = 4.5
        pointer.lineCap = .round
        pointer.shadowColor = NSColor.controlAccentColor.cgColor
        pointer.shadowOpacity = 0.8
        pointer.shadowRadius = 3
        pointer.shadowOffset = .zero

        labelBackground.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        labelBackground.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        labelBackground.borderWidth = 1
        label.font = Self.labelFont
        label.fontSize = Self.labelFont.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        labelBackground.addSublayer(label)

        for layer in [centerRing, pointer, labelBackground] {
            layer.opacity = 0
            overlay.layer?.addSublayer(layer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Route every click to this view rather than the backdrop or overlay.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(.left) }
    override func rightMouseDown(with event: NSEvent) { onMouseDown?(.right) }
    override func otherMouseDown(with event: NSEvent) { onMouseDown?(.right) }

    // MARK: - Setup

    func configure(items: [MenuItem], layout: RadialLayout, config: Config) {
        for item in itemLayers {
            item.container.removeFromSuperlayer()
        }
        self.layout = layout
        iconSize = config.iconSize
        openDuration = config.openAnimationDuration
        rasterScale = 0

        itemLayers = items.map { ItemLayers(item: $0, iconSize: iconSize) }
        for item in itemLayers {
            item.container.opacity = 0
            overlay.layer?.insertSublayer(item.container, below: labelBackground)
        }

        // Keep the backdrop around the icons when the layout grew the radius to
        // fit them.
        let growth = layout.radius - config.radius
        backdropOuterRadius = config.backdropOuterRadius + growth
        backdrop.maskImage = Self.ringMask(outer: backdropOuterRadius, inner: config.backdropInnerRadius + growth)
    }

    /// Resets the open animation, centered on `center` (in view coordinates).
    /// `badges` has each item's Dock badge, if it has one.
    func present(at center: CGPoint, badges: [String?], time: CFTimeInterval) {
        self.center = center
        openedAt = time
        lastFrameTime = nil
        pointerOpacity = 0
        labelOpacity = 0
        labelIndex = nil

        let scale = window?.backingScaleFactor ?? 2
        if scale != rasterScale {
            rasterScale = scale
            for item in itemLayers {
                item.rasterize(iconSize: iconSize, scale: scale)
            }
            for layer in [centerRing, pointer, labelBackground, label] {
                layer.contentsScale = scale
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (item, badge) in zip(itemLayers, badges) {
            item.highlight = 0
            item.emphasis = 1
            item.setBadge(badge, iconSize: iconSize)
        }
        centerRing.position = center
        pointer.position = center
        CATransaction.commit()

        update(time: time, selection: nil, pointer: .zero)
    }

    // MARK: - Animation

    func update(time: CFTimeInterval, selection: Int?, pointer offset: CGPoint) {
        let dt = lastFrameTime.map { min(time - $0, 0.1) } ?? 0
        lastFrameTime = time
        let elapsed = time - openedAt
        let appear = easeOutCubic(progress(elapsed, duration: openDuration))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let backdropScale = 0.7 + 0.3 * appear
        let backdropSize = backdropOuterRadius * 2 * backdropScale
        backdrop.frame = CGRect(
            x: center.x - backdropSize / 2,
            y: center.y - backdropSize / 2,
            width: backdropSize,
            height: backdropSize
        )
        backdrop.alphaValue = appear

        centerRing.opacity = Float(appear)
        centerRing.transform = CATransform3DMakeScale(appear, appear, 1)

        for (index, item) in itemLayers.enumerated() {
            let t = progress(elapsed - Double(index) * openDuration * Self.staggerRatio, duration: openDuration)
            let travel = easeOutBack(t)
            let offset = layout.offset(of: index)
            item.container.position = CGPoint(x: center.x + offset.x * travel, y: center.y + offset.y * travel)

            approach(&item.highlight, index == selection ? 1 : 0, rate: 24, dt: dt)
            approach(&item.emphasis, selection == nil || index == selection ? 1 : 0.55, rate: 18, dt: dt)

            let scale = (0.2 + 0.8 * easeOutCubic(t)) * (1 + 0.22 * item.highlight)
            item.container.transform = CATransform3DMakeScale(scale, scale, 1)
            item.container.opacity = Float(min(1, t * 2.5) * item.emphasis)
            item.halo.opacity = Float(item.highlight)
        }

        let pointerVisible = hypot(offset.x, offset.y) >= layout.deadZone * 0.5
        approach(&pointerOpacity, pointerVisible ? 1 : 0, rate: 30, dt: dt)
        pointer.opacity = Float(pointerOpacity * appear)
        if pointerVisible {
            pointer.transform = CATransform3DMakeRotation(atan2(offset.y, offset.x), 0, 0, 1)
        }

        updateLabel(selection: selection, dt: dt)

        CATransaction.commit()
    }

    private func updateLabel(selection: Int?, dt: CGFloat) {
        if let selection, selection != labelIndex {
            labelIndex = selection
            let title = itemLayers[selection].title
            label.string = title
            let textSize = (title as NSString).size(withAttributes: [.font: Self.labelFont])
            let size = CGSize(width: ceil(textSize.width) + 20, height: ceil(textSize.height) + 8)
            labelBackground.bounds = CGRect(origin: .zero, size: size)
            labelBackground.cornerRadius = size.height / 2
            label.frame = CGRect(x: 0, y: (size.height - ceil(textSize.height)) / 2, width: size.width, height: ceil(textSize.height))
        }
        approach(&labelOpacity, selection == nil ? 0 : 1, rate: 24, dt: dt)
        labelBackground.opacity = Float(labelOpacity)
        // In the hole of the ring, under the direction indicator, where it can't
        // cover a neighbouring icon.
        labelBackground.position = CGPoint(
            x: center.x,
            y: center.y - Self.centerRingRadius - 12 - labelBackground.bounds.height / 2
        )
    }

    // MARK: - Helpers

    private static func ringMask(outer: CGFloat, inner: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: outer * 2, height: outer * 2), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect)
            path.append(NSBezierPath(ovalIn: rect.insetBy(dx: outer - inner, dy: outer - inner)))
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
    }
}

/// The layers for one app in the ring.
@MainActor
private final class ItemLayers {
    let title: String
    private let image: NSImage

    let container = CALayer()
    let halo = CALayer()
    let icon = CALayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()

    /// 0...1, how selected the item looks.
    var highlight: CGFloat = 0
    /// 0...1, dims the other items while one is selected.
    var emphasis: CGFloat = 1

    init(item: MenuItem, iconSize: CGFloat) {
        title = item.title
        image = item.icon

        container.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)

        let haloSize = iconSize * 1.28
        halo.bounds = CGRect(x: 0, y: 0, width: haloSize, height: haloSize)
        halo.position = CGPoint(x: iconSize / 2, y: iconSize / 2)
        halo.cornerRadius = haloSize / 2
        halo.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        halo.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        halo.borderWidth = 1.5
        halo.opacity = 0

        icon.frame = container.bounds
        icon.contentsGravity = .resizeAspect
        icon.minificationFilter = .trilinear
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.35
        icon.shadowRadius = 3
        icon.shadowOffset = CGSize(width: 0, height: -1.5)

        badge.backgroundColor = NSColor.systemRed.cgColor
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.3
        badge.shadowRadius = 1.5
        badge.shadowOffset = CGSize(width: 0, height: -0.5)
        badge.isHidden = true
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.alignmentMode = .center
        badgeText.truncationMode = .end
        badge.addSublayer(badgeText)

        container.addSublayer(halo)
        container.addSublayer(icon)
        container.addSublayer(badge)
    }

    /// Shows `label` in a red badge over the top right corner, like the Dock.
    func setBadge(_ label: String?, iconSize: CGFloat) {
        badge.isHidden = label == nil
        guard let label else { return }
        let height = (iconSize * 0.34).rounded()
        let font = NSFont.systemFont(ofSize: height * 0.62, weight: .semibold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let width = min(max(height, ceil(textSize.width) + height * 0.6), iconSize)
        badge.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        badge.cornerRadius = height / 2
        badge.position = CGPoint(x: iconSize - width / 2 + height * 0.15, y: iconSize - height / 2 + height * 0.15)
        badgeText.font = font
        badgeText.fontSize = font.pointSize
        badgeText.string = label
        badgeText.frame = CGRect(x: 0, y: (height - ceil(textSize.height)) / 2, width: width, height: ceil(textSize.height))
    }

    /// Renders the icon at the largest size it's shown at (when highlighted), so
    /// it stays crisp without redrawing during the animation.
    func rasterize(iconSize: CGFloat, scale: CGFloat) {
        let pixels = Int((iconSize * 1.25 * scale).rounded(.up))
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // Fit custom icons that aren't square instead of stretching them.
        let side = CGFloat(pixels)
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let size = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
        image.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()

        icon.contents = context.makeImage()
        container.contentsScale = scale
        halo.contentsScale = scale
        badge.contentsScale = scale
        badgeText.contentsScale = scale
    }
}

private func progress(_ elapsed: CFTimeInterval, duration: CFTimeInterval) -> CGFloat {
    guard duration > 0 else { return elapsed >= 0 ? 1 : 0 }
    return CGFloat(min(max(elapsed / duration, 0), 1))
}

private func easeOutCubic(_ t: CGFloat) -> CGFloat {
    1 - pow(1 - t, 3)
}

/// Ease out with a small overshoot, so items spring into place.
private func easeOutBack(_ t: CGFloat) -> CGFloat {
    let c1: CGFloat = 1.3
    let c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
}

/// Frame-rate independent exponential smoothing towards `target`.
private func approach(_ value: inout CGFloat, _ target: CGFloat, rate: CGFloat, dt: CGFloat) {
    value += (target - value) * (1 - exp(-rate * dt))
}
