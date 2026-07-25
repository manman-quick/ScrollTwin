import AppKit
import ApplicationServices

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
    var x: Double
    var y: Double
}

struct SmoothScrollModel {
    private(set) var targetX = 0.0
    private(set) var targetY = 0.0
    private(set) var positionX = 0.0
    private(set) var positionY = 0.0
    private(set) var velocityX = 0.0
    private(set) var velocityY = 0.0

    private static let settleDistance = 0.35
    private static let settleVelocity = 6.0

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
            abs(velocityY) >= 0.5
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
            angularFrequency: angularFrequency,
            elapsed: elapsed
        )
        let y = Self.advanceAxis(
            target: targetY,
            position: &positionY,
            velocity: &velocityY,
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
        angularFrequency: Double,
        elapsed: TimeInterval
    ) -> Double {
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
        // The remaining fraction is below one visible pixel. Sending a final
        // rounded event here produces the familiar last-step hitch in apps
        // that ignore fixed-point deltas, so end the series cleanly instead.
        if abs(target - position) < Self.settleDistance,
           abs(velocity) < Self.settleVelocity {
            position = target
            velocity = 0
            return 0
        }
        return movement
    }

    private static func absClamped(_ value: Int64) -> Int64 {
        value == .min ? .max : abs(value)
    }
}

final class SmoothScrollEngine {
    static let syntheticEventMarker: Int64 = 0x5354_574E

    private var preset: SmoothScrollPreset = .balanced
    private var model = SmoothScrollModel()
    private var outputTimer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var lastFrameTime: TimeInterval?
    private var touchSeriesActive = false
    private var lastFlags: CGEventFlags = []
    private let outputInterval: TimeInterval = 1.0 / 120.0

    deinit { stopOutputTimer() }

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

        stateLock.lock()
        lastFlags = event.flags
        model.enqueue(
            deltaX: deltaX,
            deltaY: deltaY,
            multiplier: multiplier
        )
        stateLock.unlock()

        startOutputTimerIfNeeded()
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
        stopOutputTimer()

        stateLock.lock()
        let shouldEndTouch = sendEnd && touchSeriesActive
        let flags = lastFlags
        lastFrameTime = nil
        model.reset()
        touchSeriesActive = false
        stateLock.unlock()

        if shouldEndTouch {
            post(
                frame: SmoothScrollFrame(x: 0, y: 0),
                scrollPhase: 4,
                momentumPhase: 0,
                flags: flags
            )
        }
    }

    private func startOutputTimerIfNeeded() {
        stateLock.lock()
        guard outputTimer == nil else {
            stateLock.unlock()
            return
        }
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.hehongchi.ScrollTwin.smooth-scroll", qos: .userInteractive)
        )
        timer.schedule(
            deadline: .now(),
            repeating: outputInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in self?.emitFrame() }
        outputTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func stopOutputTimer() {
        stateLock.lock()
        let timer = outputTimer
        outputTimer = nil
        stateLock.unlock()
        timer?.cancel()
    }

    private func emitFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let elapsed = min(max(now - (lastFrameTime ?? now), 1.0 / 240.0), 0.05)
        lastFrameTime = now

        let frame = model.advance(by: elapsed)
        let hasMovement = frame.x != 0 || frame.y != 0
        let flags = lastFlags

        var events: [(
            frame: SmoothScrollFrame,
            scrollPhase: Int64,
            momentumPhase: Int64
        )] = []

        if hasMovement {
            events.append((frame, touchSeriesActive ? 2 : 1, 0))
            touchSeriesActive = true
        }

        let isFinished = !model.hasPendingMotion
        if isFinished {
            if touchSeriesActive {
                events.append((
                    SmoothScrollFrame(x: 0, y: 0), 4, 0
                ))
            }
            touchSeriesActive = false
            lastFrameTime = nil
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
            stopOutputTimer()
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
            wheel1: roundedInt32(frame.y),
            wheel2: roundedInt32(frame.x),
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
        event.setDoubleValueField(
            .scrollWheelEventFixedPtDeltaAxis1,
            value: frame.y
        )
        event.setDoubleValueField(
            .scrollWheelEventFixedPtDeltaAxis2,
            value: frame.x
        )
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis1,
            value: Int64(frame.y.rounded())
        )
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis2,
            value: Int64(frame.x.rounded())
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

    private func roundedInt32(_ value: Double) -> Int32 {
        Int32(min(max(value.rounded(), Double(Int32.min)), Double(Int32.max)))
    }
}
