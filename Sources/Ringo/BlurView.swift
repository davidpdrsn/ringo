import AppKit

/// A behind-window blur whose radius can be set, which `NSVisualEffectView`
/// doesn't offer.
///
/// With a radius it reaches into the material's private layers: it sets the
/// backdrop's blur and hides the milky fill over it, so only what's laid on top
/// tints the blur. If the layers ever look different it leaves them alone, and
/// the material shows as it is.
final class BlurView: NSVisualEffectView {
    /// In points. `nil` is the material's own blur and fill.
    var radius: CGFloat? {
        didSet {
            if radius != oldValue { applyRadius() }
        }
    }

    /// The backdrop layer last given `radius`, and its own radius from before.
    private weak var changedBackdrop: CALayer?
    private var originalRadius: Any?

    // The material can rebuild its layers on any of these, undoing the changes.

    override func updateLayer() {
        super.updateLayer()
        applyRadius()
    }

    override func layout() {
        super.layout()
        applyRadius()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyRadius()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRadius()
    }

    private func applyRadius() {
        let keyPath = "filters.gaussianBlur.inputRadius"
        guard
            let material = layer?.sublayers?.first,
            let backdrop = material.sublayers?.first(where: { $0.name == "backdrop" }),
            let filters = backdrop.filters as? [NSObject],
            filters.contains(where: { $0.responds(to: NSSelectorFromString("name")) && $0.value(forKey: "name") as? String == "gaussianBlur" }),
            let current = backdrop.value(forKeyPath: keyPath) as? NSNumber
        else { return }

        for name in ["fill", "tone"] {
            material.sublayers?.first { $0.name == name }?.isHidden = radius != nil
        }
        if let radius {
            if changedBackdrop !== backdrop {
                changedBackdrop = backdrop
                originalRadius = current
            }
            if current.doubleValue != Double(radius) {
                backdrop.setValue(radius, forKeyPath: keyPath)
            }
        } else if changedBackdrop === backdrop {
            // A rebuilt layer already has the material's own radius.
            backdrop.setValue(originalRadius, forKeyPath: keyPath)
            changedBackdrop = nil
        }
    }
}
