import Foundation

enum ScrollDeviceKind: String {
    case wheelMouse
    case touchSurface

    static func classify(isContinuous: Bool) -> ScrollDeviceKind {
        isContinuous ? .touchSurface : .wheelMouse
    }
}

struct ScrollSourceClassifier {
    private(set) var lastSource: ScrollDeviceKind = .wheelMouse
    private var lastTouchTime: TimeInterval?
    private var touchingFingerCount = 0

    mutating func observeGesture(touchingFingers: Int, at time: TimeInterval) {
        guard touchingFingers >= 2 else { return }
        lastTouchTime = time
        touchingFingerCount = max(touchingFingerCount, touchingFingers)
    }

    mutating func classify(
        isContinuous: Bool,
        hasMomentumPhase: Bool,
        sourceProcessID: Int64,
        at time: TimeInterval
    ) -> ScrollDeviceKind {
        defer { touchingFingerCount = 0 }

        if !isContinuous || sourceProcessID != 0 {
            lastSource = .wheelMouse
            return lastSource
        }

        let elapsed = lastTouchTime.map { time - $0 } ?? .infinity

        if touchingFingerCount >= 2, elapsed < 0.222 {
            lastSource = .touchSurface
            return lastSource
        }

        if !hasMomentumPhase, elapsed > 0.333 {
            lastSource = .wheelMouse
            return lastSource
        }

        return lastSource
    }
}

struct ScrollPolicy {
    var reverseWheelMouse: Bool
    var reverseTouchSurface: Bool

    func shouldReverse(isContinuous: Bool) -> Bool {
        switch ScrollDeviceKind.classify(isContinuous: isContinuous) {
        case .wheelMouse:
            reverseWheelMouse
        case .touchSurface:
            reverseTouchSurface
        }
    }

    static func shouldSmoothWheelMouse(
        isContinuous: Bool,
        smoothingEnabled: Bool,
        applicationIsExcluded: Bool
    ) -> Bool {
        !isContinuous && smoothingEnabled && !applicationIsExcluded
    }

    static func inverted(_ value: Int64) -> Int64 {
        value == .min ? .max : -value
    }
}
