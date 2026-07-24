import AppKit
import ApplicationServices
import CoreVideo

enum SmoothScrollPreset: String, CaseIterable {
    case responsive
    case balanced
    case soft

    var title: String {
        switch self {
        case .responsive:
            return "灵敏"
        case .balanced:
            return "均衡"
        case .soft:
            return "柔和"
        }
    }

    var step: Double {
        switch self {
        case .responsive:
            return 32
        case .balanced:
            return 35
        case .soft:
            return 38
        }
    }

    var angularFrequency: Double {
        switch self {
        case .responsive:
            return 24
        case .balanced:
            return 18
        case .soft:
            return 14
        }
    }
}

struct SmoothScrollFrame: Equatable {
    var x: Int32
    var y: Int32
}

struct SmoothScrollModel {
    private(set) var targetX = 0.0
    private(set) var targetY = 0.0
    private(set) var positionX = 0.0
    private(set) var positionY = 0.0
    private(set) var velocityX = 0.0
    private(set) var velocityY = 0.0
    private var carryX = 0.0
    private var carryY = 0.0

    let step: Double
    let angularFrequency: Double

    init(step: Double = 35, angularFrequency: Double = 18) {
        self.step = step
        self.angularFrequency = angularFrequency
    }

    var hasPendingMotion: Bool {
        abs(targetX - positionX) >= 0.05 ||
            abs(targetY - positionY) >= 0.05 ||
            abs(velocityX) >= 0.5 ||
            abs(velocityY) >= 0.5 ||
            abs(carryX) >= 0.5 ||
            abs(carryY) >= 0.5
    }

    mutating func enqueue(
        deltaX: Int64,
        deltaY: Int64,
        multiplier: Double
    ) {
        Self.enqueueAxis(
            delta: deltaX,
            multiplier: multiplier,
            step: step,
            target: &targetX,
            position: positionX,
            velocity: velocityX
        )
        Self.enqueueAxis(
            delta: deltaY,
            multiplier: multiplier,
            step: step,
            target: &targetY,
            position: positionY,
            velocity: velocityY
        )
    }

    mutating func advance(by elapsed: TimeInterval) -> SmoothScrollFrame {
        guard elapsed > 0 else {
            return SmoothScrollFrame(x: 0, y: 0)
        }

        let x = Self.advanceAxis(
            target: targetX,
            position: &positionX,
            velocity: &velocityX,
            carry: &carryX,
            angularFrequency: angularFrequency,
            elapsed: elapsed
        )
        let y = Self.advanceAxis(
            target: targetY,
            position: &positionY,
            velocity: &velocityY,
            carry: &carryY,
            angularFrequency: angularFrequency,
            elapsed: elapsed
        )

        return SmoothScrollFrame(x: x, y: y)
    }

    mutating func reset() {
        targetX = 0
        targetY = 0
        positionX = 0
        positionY = 0
        velocityX = 0
        velocityY = 0
        carryX = 0
        carryY = 0
    }

    private static func distance(for delta: Int64, step: Double) -> Double {
        let magnitude = Double(min(absClamped(delta), 12))
        guard magnitude > 0 else { return 0 }

        // Repeated or accelerated wheel ticks cover more distance without
        // making a single notch feel abrupt.
        let gain = 1 + (magnitude - 1) * 0.28
        return Double(delta.signum()) * step * gain
    }

    private static func enqueueAxis(
        delta: Int64,
        multiplier: Double,
        step: Double,
        target: inout Double,
        position: Double,
        velocity: Double
    ) {
        let addition = distance(for: delta, step: step) * multiplier
        guard addition != 0 else { return }

        // A direction change retargets from the visible position. Velocity is
        // preserved, so the spring brakes continuously instead of snapping.
        if velocity != 0, velocity.sign != addition.sign {
            target = position + addition
        } else {
            target += addition
        }
    }

    private static func advanceAxis(
        target: Double,
        position: inout Double,
        velocity: inout Double,
        carry: inout Double,
        angularFrequency: Double,
        elapsed: TimeInterval
    ) -> Int32 {
        let oldPosition = position
        let displacement = position - target
        let decay = exp(-angularFrequency * elapsed)
        let helper = velocity + angularFrequency * displacement

        let newDisplacement =
            (displacement + helper * elapsed) * decay
        let newVelocity =
            (velocity - angularFrequency * helper * elapsed) * decay

        position = target + newDisplacement
        velocity = newVelocity
        let movement = position - oldPosition
        carry += movement

        if abs(target - position) < 0.05, abs(velocity) < 0.5 {
            carry += target - position
            position = target
            velocity = 0
            let finalPixels = carry.rounded()
            carry = 0
            return clampedInt32(finalPixels)
        }

        let wholePixels = carry.rounded(.towardZero)
        carry -= wholePixels

        return clampedInt32(wholePixels)
    }

    private static func clampedInt32(_ value: Double) -> Int32 {
        let clamped = min(
            max(value, Double(Int32.min)),
            Double(Int32.max)
        )
        return Int32(clamped)
    }

    private static func absClamped(_ value: Int64) -> Int64 {
        value == .min ? .max : abs(value)
    }
}

final class SmoothScrollEngine {
    static let syntheticEventMarker: Int64 = 0x5354_574E

    private var preset: SmoothScrollPreset = .balanced
    private var model = SmoothScrollModel()
    private var displayLink: CVDisplayLink?
    private let stateLock = NSLock()
    private var lastFrameTime: TimeInterval?
    private var lastInputTime: TimeInterval?
    private var touchSeriesActive = false
    private var momentumSeriesActive = false
    private var lastFlags: CGEventFlags = []
    private let inputGrace: TimeInterval = 0.05

    init() {
        createDisplayLink()
    }

    deinit {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) ==
            syntheticEventMarker
    }

    func enqueue(
        event: CGEvent,
        multiplier: Double,
        preset requestedPreset: SmoothScrollPreset
    ) {
        if requestedPreset != preset {
            applyPreset(requestedPreset)
        }

        let deltaY = event.getIntegerValueField(
            .scrollWheelEventDeltaAxis1
        )
        let deltaX = event.getIntegerValueField(
            .scrollWheelEventDeltaAxis2
        )

        guard deltaX != 0 || deltaY != 0 else { return }

        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let wasMomentumActive = momentumSeriesActive
        if wasMomentumActive {
            momentumSeriesActive = false
            touchSeriesActive = false
        }
        lastFlags = event.flags
        lastInputTime = now
        model.enqueue(
            deltaX: deltaX,
            deltaY: deltaY,
            multiplier: multiplier
        )
        stateLock.unlock()

        if wasMomentumActive {
            post(
                frame: SmoothScrollFrame(x: 0, y: 0),
                scrollPhase: 0,
                momentumPhase: 4,
                flags: event.flags
            )
        }
        startDisplayLinkIfNeeded()
    }

    func applyPreset(_ newPreset: SmoothScrollPreset) {
        cancel(sendEnd: true)
        stateLock.lock()
        preset = newPreset
        model = SmoothScrollModel(
            step: newPreset.step,
            angularFrequency: newPreset.angularFrequency
        )
        stateLock.unlock()
    }

    func cancel(sendEnd: Bool) {
        stopDisplayLink()

        stateLock.lock()
        let shouldEndMomentum = sendEnd && momentumSeriesActive
        let shouldEndTouch = sendEnd && touchSeriesActive
        let flags = lastFlags
        lastFrameTime = nil
        lastInputTime = nil
        model.reset()
        touchSeriesActive = false
        momentumSeriesActive = false
        stateLock.unlock()

        if shouldEndMomentum {
            post(
                frame: SmoothScrollFrame(x: 0, y: 0),
                scrollPhase: 0,
                momentumPhase: 4,
                flags: flags
            )
        } else if shouldEndTouch {
            post(
                frame: SmoothScrollFrame(x: 0, y: 0),
                scrollPhase: 4,
                momentumPhase: 0,
                flags: flags
            )
        }
    }

    private func createDisplayLink() {
        var newDisplayLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&newDisplayLink) ==
                kCVReturnSuccess,
              let newDisplayLink else {
            displayLink = nil
            return
        }
        CVDisplayLinkSetOutputCallback(
            newDisplayLink,
            { _, _, _, _, _, context in
                guard let context else { return kCVReturnError }
                let engine = Unmanaged<SmoothScrollEngine>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                engine.emitFrame()
                return kCVReturnSuccess
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        displayLink = newDisplayLink
    }

    private func startDisplayLinkIfNeeded() {
        if displayLink == nil {
            createDisplayLink()
        }
        guard let displayLink,
              !CVDisplayLinkIsRunning(displayLink) else {
            return
        }
        stateLock.lock()
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        stateLock.unlock()
        CVDisplayLinkStart(displayLink)
    }

    private func stopDisplayLink() {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    private func emitFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let elapsed = min(max(now - (lastFrameTime ?? now), 1.0 / 240.0), 0.05)
        lastFrameTime = now

        let frame = model.advance(by: elapsed)
        let hasMovement = frame.x != 0 || frame.y != 0
        let inputIsFresh =
            lastInputTime.map { now - $0 <= inputGrace } ?? false
        let flags = lastFlags

        var events: [(
            frame: SmoothScrollFrame,
            scrollPhase: Int64,
            momentumPhase: Int64
        )] = []

        if inputIsFresh, hasMovement {
            if momentumSeriesActive {
                events.append((
                    SmoothScrollFrame(x: 0, y: 0), 0, 4
                ))
                momentumSeriesActive = false
                touchSeriesActive = false
            }
            events.append((frame, touchSeriesActive ? 2 : 1, 0))
            touchSeriesActive = true
        } else if hasMovement {
            if touchSeriesActive {
                events.append((
                    SmoothScrollFrame(x: 0, y: 0), 4, 0
                ))
                touchSeriesActive = false
            }
            events.append((frame, 0, momentumSeriesActive ? 2 : 1))
            momentumSeriesActive = true
        }

        let isFinished = !model.hasPendingMotion
        if isFinished {
            if momentumSeriesActive {
                events.append((
                    SmoothScrollFrame(x: 0, y: 0), 0, 4
                ))
            } else if touchSeriesActive {
                events.append((
                    SmoothScrollFrame(x: 0, y: 0), 4, 0
                ))
            }
            touchSeriesActive = false
            momentumSeriesActive = false
            lastFrameTime = nil
            lastInputTime = nil
        }
        stateLock.unlock()

        for event in events {
            post(
                frame: event.frame,
                scrollPhase: event.scrollPhase,
                momentumPhase: event.momentumPhase,
                flags: flags
            )
        }
        if isFinished {
            stopDisplayLink()
        }
    }

    private func post(
        frame: SmoothScrollFrame,
        scrollPhase: Int64,
        momentumPhase: Int64,
        flags: CGEventFlags
    ) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: frame.y,
            wheel2: frame.x,
            wheel3: 0
        ) else { return }

        event.flags = flags
        event.setIntegerValueField(
            .eventSourceUserData,
            value: Self.syntheticEventMarker
        )
        event.setIntegerValueField(
            .scrollWheelEventIsContinuous,
            value: 1
        )
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: scrollPhase
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: momentumPhase
        )
        event.post(tap: .cghidEventTap)
    }
}
