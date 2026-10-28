import AppKit
import QuartzCore

/// Opens the menu when a number of fingers rest on the trackpad.
///
/// macOS only delivers touches to the key window of the active app, so this
/// reads every trackpad through the private MultitouchSupport framework instead,
/// like BetterTouchTool and MiddleClick do.
@MainActor
final class TrackpadMonitor {
    private static weak var current: TrackpadMonitor?

    var fingers: Int { gesture.fingers }

    private let multitouch: MultitouchSupport
    private let handler: (TrackpadGesture.Event) -> Void
    private var gesture: TrackpadGesture
    private let scrollBlocker = ScrollBlocker()
    private var deviceList: CFArray?
    /// Each trackpad and its surface size in millimeters.
    private var devices: [(ref: MTDeviceRef, size: CGSize)] = []
    private var wakeObserver: (any NSObjectProtocol)?

    init(fingers: Int, handler: @escaping (TrackpadGesture.Event) -> Void) throws(HotKeyError) {
        guard let multitouch = MultitouchSupport.shared else {
            throw HotKeyError("Couldn't load MultitouchSupport, so trackpad_fingers doesn't work.")
        }
        self.multitouch = multitouch
        self.handler = handler
        gesture = TrackpadGesture(fingers: fingers)

        Self.current?.stop()
        Self.current = self
        startDevices()
        // Trackpads stop reporting touches after sleep until they're restarted.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopDevices()
                self?.startDevices()
            }
        }
    }

    func stop() {
        stopDevices()
        scrollBlocker.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        if Self.current === self {
            Self.current = nil
        }
    }

    private func startDevices() {
        gesture.reset()
        guard let list = multitouch.createList()?.takeRetainedValue() else { return }
        deviceList = list
        for device in list as [AnyObject] {
            let ref = Unmanaged.passUnretained(device).toOpaque()
            var width: Int32 = 0
            var height: Int32 = 0
            _ = multitouch.surfaceDimensions(ref, &width, &height)
            // Reported in hundredths of a millimeter.
            devices.append((ref, CGSize(width: Double(width) / 100, height: Double(height) / 100)))
            multitouch.registerCallback(ref, contactFrameCallback)
            multitouch.start(ref, 0)
        }
    }

    private func stopDevices() {
        for device in devices {
            multitouch.unregisterCallback(device.ref, contactFrameCallback)
            multitouch.stop(device.ref)
        }
        devices = []
        deviceList = nil
    }

    fileprivate static func handle(_ frame: TouchFrame) {
        guard let monitor = current else { return }
        let size = monitor.devices.first { UInt(bitPattern: $0.ref) == frame.device }?.size
            ?? CGSize(width: 125, height: 77)
        for event in monitor.gesture.process(frame, surfaceSize: size, at: CACurrentMediaTime()) {
            switch event {
            case .began: monitor.scrollBlocker.gestureBegan()
            case .ended, .cancelled: monitor.scrollBlocker.gestureEnded()
            case .moved: break
            }
            monitor.handler(event)
        }
        monitor.scrollBlocker.fingersChanged(to: frame.fingers)
    }
}

/// What one trackpad frame boils down to.
struct TouchFrame: Sendable {
    /// Identifies the trackpad.
    var device: UInt
    /// Fingers touching the surface.
    var fingers: Int
    /// The touching fingers' average position, 0...1 with the origin at the
    /// bottom left.
    var centroid: CGPoint
}

/// Turns trackpad frames into the start, movement and end of an N-finger touch.
struct TrackpadGesture {
    enum Event: Equatable {
        case began
        /// Where the fingers have moved since they landed, scaled to points.
        case moved(CGPoint)
        /// The fingers lifted.
        case ended
        /// More fingers landed, so it's some other gesture.
        case cancelled
    }

    /// The fingers have to stay down this long before the menu opens, so putting
    /// down or lifting more fingers (which passes through fewer) doesn't flash it.
    static let settleTime: CFTimeInterval = 0.05
    /// All the fingers have to land within this long of the first one, so a palm
    /// brushing the trackpad while two fingers scroll doesn't count as a third.
    static let landingTime: CFTimeInterval = 0.15
    /// How far the pointer moves per millimeter the fingers move.
    static let pointsPerMillimeter: CGFloat = 4

    let fingers: Int
    private var state = State.idle

    private enum State {
        case idle
        /// Some fingers are down, but not enough yet.
        case landing(device: UInt, since: CFTimeInterval)
        case settling(device: UInt, start: CGPoint, since: CFTimeInterval)
        case active(device: UInt, start: CGPoint)
        /// Ignores everything until all fingers have lifted.
        case blocked
    }

    init(fingers: Int) {
        self.fingers = fingers
    }

    mutating func reset() {
        state = .idle
    }

    mutating func process(_ frame: TouchFrame, surfaceSize: CGSize, at time: CFTimeInterval) -> [Event] {
        switch state {
        case .idle:
            if frame.fingers == fingers {
                state = .settling(device: frame.device, start: frame.centroid, since: time)
            } else if frame.fingers > fingers {
                state = .blocked
            } else if frame.fingers > 0 {
                state = .landing(device: frame.device, since: time)
            }
            return []

        case .landing(let device, let since):
            guard frame.device == device else { return [] }
            if frame.fingers == 0 {
                state = .idle
            } else if frame.fingers == fingers, time - since <= Self.landingTime {
                state = .settling(device: device, start: frame.centroid, since: time)
            } else if frame.fingers >= fingers {
                // Too late to be part of the same touch.
                state = .blocked
            }
            return []

        case .settling(let device, let start, let since):
            guard frame.device == device else { return [] }
            guard frame.fingers == fingers else {
                state = frame.fingers == 0 ? .idle : .blocked
                return []
            }
            guard time - since >= Self.settleTime else { return [] }
            state = .active(device: device, start: start)
            return [.began, .moved(offset(from: start, to: frame.centroid, surfaceSize: surfaceSize))]

        case .active(let device, let start):
            guard frame.device == device else { return [] }
            if frame.fingers == fingers {
                return [.moved(offset(from: start, to: frame.centroid, surfaceSize: surfaceSize))]
            }
            let event: Event = frame.fingers > fingers ? .cancelled : .ended
            state = frame.fingers == 0 ? .idle : .blocked
            return [event]

        case .blocked:
            if frame.fingers == 0 {
                state = .idle
            }
            return []
        }
    }

    /// Converts via millimeters so the direction isn't skewed by the trackpad
    /// being wider than it's tall.
    private func offset(from start: CGPoint, to end: CGPoint, surfaceSize: CGSize) -> CGPoint {
        CGPoint(
            x: (end.x - start.x) * surfaceSize.width * Self.pointsPerMillimeter,
            y: (end.y - start.y) * surfaceSize.height * Self.pointsPerMillimeter
        )
    }
}

// MARK: - MultitouchSupport

/// Layouts from the private MultitouchSupport framework, as reverse engineered
/// by projects like MiddleClick and OpenMultitouchSupport.
struct MTPoint {
    var x: Float
    var y: Float
}

struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    /// 3 when a finger lands, 4 while it touches; other values are hovering or lifting.
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    /// 0...1 with the origin at the bottom left.
    var normalized: MTVector
    var zTotal: Float
    var unknown1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var unknown2: Int32
    var unknown3: Int32
    var zDensity: Float

    var isTouching: Bool { state == 3 || state == 4 }
}

typealias MTDeviceRef = UnsafeMutableRawPointer
/// The touches arrive as a C array of `MTTouch`, which C function types can't
/// name directly.
typealias MTContactFrameCallback = @convention(c) (
    MTDeviceRef?, UnsafeRawPointer?, Int32, Double, Int32
) -> Int32

struct MultitouchSupport: @unchecked Sendable {
    let createList: @convention(c) () -> Unmanaged<CFArray>?
    let registerCallback: @convention(c) (MTDeviceRef, MTContactFrameCallback) -> Void
    let unregisterCallback: @convention(c) (MTDeviceRef, MTContactFrameCallback) -> Void
    let start: @convention(c) (MTDeviceRef, Int32) -> Void
    let stop: @convention(c) (MTDeviceRef) -> Void
    let surfaceDimensions: @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    static let shared = load()

    private static func load() -> MultitouchSupport? {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard
            let createList = symbol("MTDeviceCreateList", as: (@convention(c) () -> Unmanaged<CFArray>?).self),
            let registerCallback = symbol(
                "MTRegisterContactFrameCallback",
                as: (@convention(c) (MTDeviceRef, MTContactFrameCallback) -> Void).self
            ),
            let unregisterCallback = symbol(
                "MTUnregisterContactFrameCallback",
                as: (@convention(c) (MTDeviceRef, MTContactFrameCallback) -> Void).self
            ),
            let start = symbol("MTDeviceStart", as: (@convention(c) (MTDeviceRef, Int32) -> Void).self),
            let stop = symbol("MTDeviceStop", as: (@convention(c) (MTDeviceRef) -> Void).self),
            let surfaceDimensions = symbol(
                "MTDeviceGetSensorSurfaceDimensions",
                as: (@convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self
            )
        else { return nil }
        return MultitouchSupport(
            createList: createList,
            registerCallback: registerCallback,
            unregisterCallback: unregisterCallback,
            start: start,
            stop: stop,
            surfaceDimensions: surfaceDimensions
        )
    }
}

/// Called on a MultitouchSupport thread for every frame, while any finger is on
/// a trackpad.
private func contactFrameCallback(
    _ device: MTDeviceRef?,
    _ touches: UnsafeRawPointer?,
    _ count: Int32,
    _: Double,
    _: Int32
) -> Int32 {
    var fingers = 0
    var sum = CGPoint.zero
    if let touches, count > 0 {
        let touches = touches.assumingMemoryBound(to: MTTouch.self)
        for touch in UnsafeBufferPointer(start: touches, count: Int(count)) where touch.isTouching {
            fingers += 1
            sum.x += CGFloat(touch.normalized.position.x)
            sum.y += CGFloat(touch.normalized.position.y)
        }
    }
    let frame = TouchFrame(
        device: UInt(bitPattern: device),
        fingers: fingers,
        centroid: fingers > 0 ? CGPoint(x: sum.x / CGFloat(fingers), y: sum.y / CGFloat(fingers)) : .zero
    )
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            TrackpadMonitor.handle(frame)
        }
    }
    return 0
}
