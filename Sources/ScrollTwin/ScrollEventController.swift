import AppKit
import ApplicationServices

final class ScrollEventController: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case needsAccessibilityPermission
        case running
        case failed
    }

    private(set) var state: State = .stopped {
        didSet {
            if oldValue != state {
                onStateChange?(state)
            }
        }
    }

    var onStateChange: ((State) -> Void)?

    private var activeTap: CFMachPort?
    private var activeRunLoopSource: CFRunLoopSource?
    private var gestureTap: CFMachPort?
    private var gestureRunLoopSource: CFRunLoopSource?
    private let preferences: Preferences
    private var sourceClassifier = ScrollSourceClassifier()
    private let smoothEngine = SmoothScrollEngine()
    private var activeApplicationBundleIdentifier: String?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    func start(promptForPermission: Bool) {
        stop()

        guard Self.isAccessibilityTrusted(prompt: promptForPermission) else {
            state = .needsAccessibilityPermission
            return
        }

        let scrollMask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let gestureMask = CGEventMask(NSEvent.EventTypeMask.gesture.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let controller = Unmanaged<ScrollEventController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                controller.enableTaps()
                return Unmanaged.passUnretained(event)
            }

            if type.rawValue == UInt32(NSEvent.EventType.gesture.rawValue) {
                controller.observeGesture(event)
                return Unmanaged.passUnretained(event)
            }

            guard type == .scrollWheel else {
                return Unmanaged.passUnretained(event)
            }

            if SmoothScrollEngine.isSynthetic(event) {
                return Unmanaged.passUnretained(event)
            }

            let isContinuous =
                event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let hasMomentumPhase =
                !(NSEvent(cgEvent: event)?.momentumPhase.isEmpty ?? true)
            let device = controller.sourceClassifier.classify(
                isContinuous: isContinuous,
                hasMomentumPhase: hasMomentumPhase,
                sourceProcessID: event.getIntegerValueField(
                    .eventSourceUnixProcessID
                ),
                at: ProcessInfo.processInfo.systemUptime
            )
            let policy = controller.preferences.policy

            let shouldSmooth = ScrollPolicy.shouldSmoothWheelMouse(
                isContinuous: isContinuous,
                smoothingEnabled: controller.preferences.smoothWheelMouse,
                applicationIsExcluded:
                    controller.preferences.isSmoothingExcluded(
                        for: controller.activeApplicationBundleIdentifier
                    )
            )

            if device == .wheelMouse, shouldSmooth {
                controller.smoothEngine.enqueue(
                    event: event,
                    multiplier: policy.reverseWheelMouse
                        ? -controller.preferences.wheelMouseSpeed
                        : controller.preferences.wheelMouseSpeed,
                    preset: controller.preferences.smoothScrollPreset
                )
                return nil
            }

            let shouldReverse: Bool
            switch device {
            case .wheelMouse:
                shouldReverse = policy.reverseWheelMouse
            case .touchSurface:
                shouldReverse = policy.reverseTouchSurface
            }

            let speed = device == .wheelMouse
                ? controller.preferences.wheelMouseSpeed
                : controller.preferences.touchSurfaceSpeed
            let multiplier = shouldReverse ? -speed : speed

            guard multiplier != 1 else {
                return Unmanaged.passUnretained(event)
            }

            ScrollEventController.scaleScrollAxes(in: event, multiplier: multiplier)
            return Unmanaged.passUnretained(event)
        }

        let passiveTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: gestureMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        let modifyingTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: scrollMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let modifyingTap else {
            state = Self.isAccessibilityTrusted(prompt: false)
                ? .failed
                : .needsAccessibilityPermission
            return
        }

        let activeSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            modifyingTap,
            0
        )

        activeTap = modifyingTap
        activeRunLoopSource = activeSource

        if let passiveTap {
            let passiveSource = CFMachPortCreateRunLoopSource(
                kCFAllocatorDefault,
                passiveTap,
                0
            )
            gestureTap = passiveTap
            gestureRunLoopSource = passiveSource
            CFRunLoopAddSource(CFRunLoopGetMain(), passiveSource, .commonModes)
            CGEvent.tapEnable(tap: passiveTap, enable: true)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), activeSource, .commonModes)
        CGEvent.tapEnable(tap: modifyingTap, enable: true)
        state = .running
    }

    func stop() {
        if let tap = activeTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let tap = gestureTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = activeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let source = gestureRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        activeTap = nil
        activeRunLoopSource = nil
        gestureTap = nil
        gestureRunLoopSource = nil
        sourceClassifier = ScrollSourceClassifier()
        smoothEngine.cancel(sendEnd: true)
        state = .stopped
    }

    func retry() {
        start(promptForPermission: false)
    }

    func preferencesDidChange() {
        if !preferences.smoothWheelMouse {
            smoothEngine.cancel(sendEnd: true)
        }
        smoothEngine.applyPreset(preferences.smoothScrollPreset)
    }

    func setActiveApplication(bundleIdentifier: String?) {
        activeApplicationBundleIdentifier = bundleIdentifier
    }

    func healthCheck() {
        guard Self.isAccessibilityTrusted(prompt: false) else {
            if state != .needsAccessibilityPermission {
                stop()
                state = .needsAccessibilityPermission
            }
            return
        }

        guard let activeTap,
              CFMachPortIsValid(activeTap) else {
            start(promptForPermission: false)
            return
        }

        if !CGEvent.tapIsEnabled(tap: activeTap) {
            CGEvent.tapEnable(tap: activeTap, enable: true)
        }
        if let gestureTap,
           CFMachPortIsValid(gestureTap),
           !CGEvent.tapIsEnabled(tap: gestureTap) {
            CGEvent.tapEnable(tap: gestureTap, enable: true)
        }
        state = .running
    }

    private func enableTaps() {
        if let activeTap {
            CGEvent.tapEnable(tap: activeTap, enable: true)
        }
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: true)
        }
    }

    private func observeGesture(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        sourceClassifier.observeGesture(
            touchingFingers: nsEvent.touches(matching: .touching, in: nil).count,
            at: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func reverseScrollAxes(in event: CGEvent) {
        scaleScrollAxes(in: event, multiplier: -1)
    }

    static func scaleScrollAxes(in event: CGEvent, multiplier: Double) {
        let axes: [(
            delta: CGEventField,
            point: CGEventField,
            fixed: CGEventField
        )] = [
            (
                .scrollWheelEventDeltaAxis1,
                .scrollWheelEventPointDeltaAxis1,
                .scrollWheelEventFixedPtDeltaAxis1
            ),
            (
                .scrollWheelEventDeltaAxis2,
                .scrollWheelEventPointDeltaAxis2,
                .scrollWheelEventFixedPtDeltaAxis2
            ),
            (
                .scrollWheelEventDeltaAxis3,
                .scrollWheelEventPointDeltaAxis3,
                .scrollWheelEventFixedPtDeltaAxis3
            )
        ]

        // Setting a coarse delta makes macOS recalculate the point and fixed
        // deltas. Capture every original value before changing any field.
        let originalValues = axes.map { axis in
            (
                delta: event.getIntegerValueField(axis.delta),
                point: event.getIntegerValueField(axis.point),
                fixed: event.getDoubleValueField(axis.fixed)
            )
        }

        for (index, axis) in axes.enumerated() {
            event.setIntegerValueField(
                axis.delta,
                value: scaledInteger(originalValues[index].delta, by: multiplier)
            )
        }

        for (index, axis) in axes.enumerated() {
            event.setDoubleValueField(
                axis.fixed,
                value: originalValues[index].fixed * multiplier
            )
        }

        for (index, axis) in axes.enumerated() {
            event.setIntegerValueField(
                axis.point,
                value: scaledInteger(originalValues[index].point, by: multiplier)
            )
        }
    }

    private static func scaledInteger(_ value: Int64, by multiplier: Double) -> Int64 {
        let scaled = (Double(value) * multiplier).rounded()
        return Int64(min(max(scaled, Double(Int64.min)), Double(Int64.max)))
    }
}
