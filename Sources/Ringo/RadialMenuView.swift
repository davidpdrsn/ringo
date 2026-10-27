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
    private var selectedIconScale: CGFloat = 1.22
    private var unselectedIconOpacity: CGFloat = 0.55
    private var unselectedIconScale: CGFloat = 1
    private var openDuration: CFTimeInterval = 0.18
    private var backdropOuterRadius: CGFloat = 0
    /// The edges the backdrop's mask was made for.
    private var backdropMaskRadii: (outer: CGFloat, inner: CGFloat)?
    private var rasterScale: CGFloat = 0

    private var center: CGPoint = .zero
    private var openedAt: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval?
    private var pointerOpacity: CGFloat = 0
    private var labelOpacity: CGFloat = 0
    private var labelIndex: Int?

    private let backdrop = NSVisualEffectView()
    private let overlay = NSView()
    /// The configured color over the blurred backdrop, scaled and faded with it.
    private let backdropTint = CAShapeLayer()
    private let outerHighlight = RingHighlightLayers()
    private let centerRing = CAShapeLayer()
    private let innerHighlight = RingHighlightLayers()
    private let labelBackground = CALayer()
    private let label = CATextLayer()

    /// Each icon starts this fraction of `openDuration` after the one before it.
    private static let staggerRatio = 1.0 / 15
    private static let centerRingRadius: CGFloat = 13
    private static let centerRingLineWidth: CGFloat = 2.5
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
        centerRing.lineWidth = Self.centerRingLineWidth

        backdropTint.fillRule = .evenOdd

        labelBackground.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        labelBackground.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        labelBackground.borderWidth = 1
        label.font = Self.labelFont
        label.fontSize = Self.labelFont.pointSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        labelBackground.addSublayer(label)

        for layer in [backdropTint, outerHighlight.layer, centerRing, innerHighlight.layer, labelBackground] {
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
        self.layout = layout
        iconSize = config.iconSize
        // Icons are drawn for their selected size, so this is set with them.
        selectedIconScale = config.selectedIconScale
        rasterScale = 0

        // Without the fade layers get when added, which a preview being restyled
        // would show.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in itemLayers {
            item.container.removeFromSuperlayer()
        }
        itemLayers = items.map { ItemLayers(item: $0, iconSize: iconSize) }
        for item in itemLayers {
            item.container.opacity = 0
            overlay.layer?.insertSublayer(item.container, below: labelBackground)
        }
        CATransaction.commit()

        applyStyle(config)
    }

    /// Updates the rings and their highlights to `config`, leaving the icons and
    /// any animation as they are. `config` must have the radius and icon size the
    /// layout was made with.
    func applyStyle(_ config: Config) {
        openDuration = config.openAnimationDuration
        unselectedIconOpacity = config.unselectedIconOpacity
        unselectedIconScale = config.unselectedIconScale

        // Keep the backdrop around the icons when the layout grew the radius to
        // fit them.
        let growth = layout.radius - config.radius
        backdropOuterRadius = config.outerRing.outerRadius + growth
        let backdropInnerRadius = config.outerRing.innerRadius + growth
        // Only when it changes, since a new mask redraws the blur.
        let maskRadii = (outer: backdropOuterRadius, inner: CGFloat(backdropInnerRadius))
        if backdropMaskRadii.map({ $0 != maskRadii }) ?? true {
            backdropMaskRadii = maskRadii
            backdrop.maskImage = Self.ringMask(outer: backdropOuterRadius, inner: backdropInnerRadius)
        }

        // For highlights without a width: one app's share of the ring, so on the
        // outer ring it fills the gaps either side of the icon being pointed at
        // (which covers the ring's whole width). At most a quarter of the ring
        // when there are only a few apps.
        let appShare = min(.pi / 2, 2 * .pi / CGFloat(max(layout.count, 1)))
        outerHighlight.configure(
            inner: backdropInnerRadius,
            outer: backdropOuterRadius,
            style: config.outerRing.highlight,
            defaultWidth: appShare
        )
        innerHighlight.configure(
            inner: Self.centerRingRadius - Self.centerRingLineWidth / 2,
            outer: Self.centerRingRadius + Self.centerRingLineWidth / 2,
            style: config.innerRing.highlight,
            defaultWidth: appShare
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let tintBounds = CGRect(x: 0, y: 0, width: backdropOuterRadius * 2, height: backdropOuterRadius * 2)
        backdropTint.bounds = tintBounds
        backdropTint.path = ringPath(in: tintBounds, width: backdropOuterRadius - backdropInnerRadius)
        backdropTint.fillColor = config.outerRing.color?.cgColor
        backdropTint.isHidden = config.outerRing.color == nil
        centerRing.strokeColor = config.innerRing.color?.cgColor ?? NSColor.white.withAlphaComponent(0.55).cgColor
        CATransaction.commit()
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

        CATransaction.begin()
        // Including the new icon images, which would otherwise cross-fade in.
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        if scale != rasterScale {
            rasterScale = scale
            for item in itemLayers {
                item.rasterize(largestSize: iconSize * max(1, selectedIconScale), scale: scale)
            }
            for layer in [backdropTint, centerRing, labelBackground, label] {
                layer.contentsScale = scale
            }
            outerHighlight.setContentsScale(scale)
            innerHighlight.setContentsScale(scale)
        }
        for (item, badge) in zip(itemLayers, badges) {
            item.highlight = 0
            item.recede = 0
            item.setBadge(badge, iconSize: iconSize)
        }
        centerRing.position = center
        outerHighlight.layer.position = center
        innerHighlight.layer.position = center
        backdropTint.position = center
        CATransaction.commit()

        update(time: time, selection: nil, pointer: .zero)
    }

    /// Skips straight to how the pointer, label and icons look with `selection`,
    /// for a preview that's restyled while it's open.
    func settle(selection: Int?) {
        pointerOpacity = selection == nil ? 0 : 1
        labelOpacity = selection == nil ? 0 : 1
        for (index, item) in itemLayers.enumerated() {
            item.highlight = index == selection ? 1 : 0
            item.recede = selection != nil && index != selection ? 1 : 0
        }
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
        backdropTint.opacity = Float(appear)
        backdropTint.transform = CATransform3DMakeScale(backdropScale, backdropScale, 1)

        centerRing.opacity = Float(appear)
        centerRing.transform = CATransform3DMakeScale(appear, appear, 1)

        for (index, item) in itemLayers.enumerated() {
            let t = progress(elapsed - Double(index) * openDuration * Self.staggerRatio, duration: openDuration)
            let travel = easeOutBack(t)
            let offset = layout.offset(of: index)
            item.container.position = CGPoint(x: center.x + offset.x * travel, y: center.y + offset.y * travel)

            approach(&item.highlight, index == selection ? 1 : 0, rate: 24, dt: dt)
            approach(&item.recede, selection != nil && index != selection ? 1 : 0, rate: 18, dt: dt)

            let selected = 1 + (selectedIconScale - 1) * item.highlight
            let receded = 1 + (unselectedIconScale - 1) * item.recede
            let scale = (0.2 + 0.8 * easeOutCubic(t)) * selected * receded
            item.container.transform = CATransform3DMakeScale(scale, scale, 1)
            item.container.opacity = Float(min(1, t * 2.5) * (1 - (1 - unselectedIconOpacity) * item.recede))
        }

        // Only with an app selected, so they never promise a switch that letting
        // go in the dead zone wouldn't make.
        let pointerVisible = selection != nil
        approach(&pointerOpacity, pointerVisible ? 1 : 0, rate: 30, dt: dt)
        for highlight in [outerHighlight, innerHighlight] {
            highlight.layer.opacity = Float(pointerOpacity * appear)
            if pointerVisible {
                highlight.layer.transform = CATransform3DMakeRotation(atan2(offset.y, offset.x), 0, 0, 1)
            }
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

/// The highlight on a ring in the direction of the cursor: a wedge or bubble
/// with a glow behind it. It's drawn pointing at angle 0, and `layer` is rotated
/// as a whole to follow the cursor.
@MainActor
private final class RingHighlightLayers {
    let layer = CALayer()
    /// Only a shadow, shaped by its `shadowPath`.
    private let glow = CALayer()
    /// A conic gradient around the center, lit at angle 0 (towards `endPoint`).
    private let wedge = CAGradientLayer()
    private let wedgeMask = CAShapeLayer()
    private let bubble = CAShapeLayer()

    init() {
        wedge.type = .conic
        wedge.startPoint = CGPoint(x: 0.5, y: 0.5)
        wedge.endPoint = CGPoint(x: 1, y: 0.5)
        wedgeMask.fillRule = .evenOdd
        wedge.mask = wedgeMask
        bubble.fillColor = nil
        bubble.lineCap = .round
        glow.shadowOffset = .zero
        for sublayer in [glow, wedge, bubble] {
            layer.addSublayer(sublayer)
        }
    }

    /// Fits the highlight to a ring between the `inner` and `outer` radius.
    /// `defaultWidth`, in radians, is for a `style` without a width.
    func configure(inner: CGFloat, outer: CGFloat, style: RingHighlight, defaultWidth: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // The highlight's edges, past the ring's by the overhang.
        let overhang = CGFloat(style.overhang)
        let far = outer + overhang
        let near = max(0, inner - overhang)
        let bounds = CGRect(x: 0, y: 0, width: far * 2, height: far * 2)
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.bounds = bounds
        for sublayer in [glow, wedge, wedgeMask, bubble] {
            sublayer.frame = bounds
        }

        let halfWidth: CGFloat = style.width.map { CGFloat($0) * .pi / 360 } ?? defaultWidth / 2
        let fade: CGFloat = style.fade.map { CGFloat($0) * .pi / 180 } ?? halfWidth * 0.2
        let color = style.color?.cgColor ?? NSColor.controlAccentColor.cgColor

        let shape: CGPath
        switch style.shape {
        case .wedge:
            wedgeMask.path = ringPath(in: bounds, width: far - near)
            // As fractions of a full turn. The two ends can't overlap around the back.
            let litEnd = halfWidth / (2 * .pi)
            let fadeEnd = min(0.5, (halfWidth + fade) / (2 * .pi))
            let unlit = color.copy(alpha: 0) ?? color
            wedge.colors = [color, color, unlit, unlit, color, color]
            wedge.locations = [0, litEnd, fadeEnd, 1 - fadeEnd, 1 - litEnd, 1].map { NSNumber(value: Double($0)) }

            // The glow covers it out to the middle of the fade.
            let glowHalfWidth = min(.pi, halfWidth + fade / 2)
            let sector = CGMutablePath()
            sector.addArc(center: middle, radius: far, startAngle: -glowHalfWidth, endAngle: glowHalfWidth, clockwise: false)
            sector.addArc(center: middle, radius: near, startAngle: glowHalfWidth, endAngle: -glowHalfWidth, clockwise: true)
            sector.closeSubpath()
            shape = sector
        case .bubble:
            // The arc spans the width, and the rounded ends reach past it.
            let arc = CGMutablePath()
            arc.addArc(center: middle, radius: (far + near) / 2, startAngle: -halfWidth, endAngle: halfWidth, clockwise: false)
            bubble.path = arc
            bubble.lineWidth = far - near
            bubble.strokeColor = color
            shape = arc.copy(strokingWithWidth: far - near, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        wedge.isHidden = style.shape != .wedge
        bubble.isHidden = style.shape != .bubble

        // Like CSS's box-shadow: the spread grows the shape, then the blur softens
        // its edge.
        let spread = CGFloat(style.glowSpread)
        glow.isHidden = (spread == 0 && style.glowBlur == 0) || style.glowOpacity == 0
        glow.shadowPath = spread > 0
            ? shape.union(shape.copy(strokingWithWidth: spread * 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
            : shape
        glow.shadowRadius = CGFloat(style.glowBlur)
        glow.shadowOpacity = Float(style.glowOpacity)
        // At full strength, since a translucent highlight would make it faint.
        glow.shadowColor = color.copy(alpha: 1)
    }

    func setContentsScale(_ scale: CGFloat) {
        for sublayer in [layer, glow, wedge, wedgeMask, bubble] {
            sublayer.contentsScale = scale
        }
    }
}

/// The layers for one app in the ring.
@MainActor
private final class ItemLayers {
    let title: String
    private let image: NSImage

    let container = CALayer()
    let icon = CALayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()

    /// 0...1, how selected the item looks.
    var highlight: CGFloat = 0
    /// 0...1, how far it has dimmed and shrunk while another item is selected.
    var recede: CGFloat = 0

    init(item: MenuItem, iconSize: CGFloat) {
        title = item.title
        image = item.icon

        container.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)

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

    /// Renders the icon at the largest size it's shown at, `largestSize`, so
    /// it stays crisp without redrawing during the animation.
    func rasterize(largestSize: CGFloat, scale: CGFloat) {
        let pixels = Int((largestSize * scale).rounded(.up))
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
        badge.contentsScale = scale
        badgeText.contentsScale = scale
    }
}

/// A ring filling `bounds`, `width` thick, for the even-odd fill rule.
private func ringPath(in bounds: CGRect, width: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.addEllipse(in: bounds)
    path.addEllipse(in: bounds.insetBy(dx: width, dy: width))
    return path
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

extension RGBAColor {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Frame-rate independent exponential smoothing towards `target`.
private func approach(_ value: inout CGFloat, _ target: CGFloat, rate: CGFloat, dt: CGFloat) {
    value += (target - value) * (1 - exp(-rate * dt))
}
