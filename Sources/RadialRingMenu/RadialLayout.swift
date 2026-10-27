import CoreGraphics
import Foundation

/// Where items sit around the center and which one a cursor offset points at.
///
/// Uses y-up coordinates (like AppKit). Items start at 12 o'clock and go clockwise.
struct RadialLayout: Equatable {
    var count: Int
    var radius: CGFloat
    /// Offsets closer to the center than this select nothing.
    var deadZone: CGFloat

    /// Grows `radius` when needed so `count` icons of `iconSize` don't overlap.
    init(count: Int, radius: CGFloat, iconSize: CGFloat) {
        let spacing = iconSize * 1.35
        let minimumRadius = count > 1 ? spacing / (2 * sin(.pi / CGFloat(count))) : 0
        self.count = count
        self.radius = max(radius, minimumRadius)
        self.deadZone = min(24, self.radius * 0.4)
    }

    private var step: CGFloat { 2 * .pi / CGFloat(count) }

    /// Angle of an item in radians, counter-clockwise from the positive x axis.
    func angle(of index: Int) -> CGFloat {
        .pi / 2 - CGFloat(index) * step
    }

    func offset(of index: Int) -> CGPoint {
        let angle = angle(of: index)
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    /// The item whose direction is closest to `offset`, or `nil` inside the dead zone.
    func selection(for offset: CGPoint) -> Int? {
        guard count > 0, hypot(offset.x, offset.y) >= deadZone else { return nil }
        // Clockwise angle from 12 o'clock.
        let clockwise = (.pi / 2 - atan2(offset.y, offset.x)).truncatingRemainder(dividingBy: 2 * .pi)
        let normalized = clockwise < 0 ? clockwise + 2 * .pi : clockwise
        return Int((normalized / step).rounded()) % count
    }
}
