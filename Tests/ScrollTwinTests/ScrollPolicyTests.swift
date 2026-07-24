import XCTest
import CoreGraphics
@testable import ScrollTwin

final class ScrollPolicyTests: XCTestCase {
    func testDeviceClassification() {
        XCTAssertEqual(ScrollDeviceKind.classify(isContinuous: false), .wheelMouse)
        XCTAssertEqual(ScrollDeviceKind.classify(isContinuous: true), .touchSurface)
    }

    func testMouseOnlyPolicy() {
        let policy = ScrollPolicy(
            reverseWheelMouse: true,
            reverseTouchSurface: false
        )

        XCTAssertTrue(policy.shouldReverse(isContinuous: false))
        XCTAssertFalse(policy.shouldReverse(isContinuous: true))
    }

    func testTouchOnlyPolicy() {
        let policy = ScrollPolicy(
            reverseWheelMouse: false,
            reverseTouchSurface: true
        )

        XCTAssertFalse(policy.shouldReverse(isContinuous: false))
        XCTAssertTrue(policy.shouldReverse(isContinuous: true))
    }

    func testIntegerInversion() {
        XCTAssertEqual(ScrollPolicy.inverted(12), -12)
        XCTAssertEqual(ScrollPolicy.inverted(-5), 5)
        XCTAssertEqual(ScrollPolicy.inverted(0), 0)
        XCTAssertEqual(ScrollPolicy.inverted(.min), .max)
    }

    func testContinuousMouseWithoutTouchesIsStillMouse() {
        var classifier = ScrollSourceClassifier()

        XCTAssertEqual(
            classifier.classify(
                isContinuous: true,
                hasMomentumPhase: false,
                sourceProcessID: 0,
                at: 10
            ),
            .wheelMouse
        )
    }

    func testTwoFingerGestureClassifiesTrackpad() {
        var classifier = ScrollSourceClassifier()
        classifier.observeGesture(touchingFingers: 2, at: 10)

        XCTAssertEqual(
            classifier.classify(
                isContinuous: true,
                hasMomentumPhase: false,
                sourceProcessID: 0,
                at: 10.1
            ),
            .touchSurface
        )
    }

    func testTrackpadMomentumKeepsPreviousSource() {
        var classifier = ScrollSourceClassifier()
        classifier.observeGesture(touchingFingers: 2, at: 10)
        _ = classifier.classify(
            isContinuous: true,
            hasMomentumPhase: false,
            sourceProcessID: 0,
            at: 10.1
        )

        XCTAssertEqual(
            classifier.classify(
                isContinuous: true,
                hasMomentumPhase: true,
                sourceProcessID: 0,
                at: 11
            ),
            .touchSurface
        )
    }

    func testDiscreteEventAlwaysClassifiesMouse() {
        var classifier = ScrollSourceClassifier()
        classifier.observeGesture(touchingFingers: 2, at: 10)

        XCTAssertEqual(
            classifier.classify(
                isContinuous: false,
                hasMomentumPhase: false,
                sourceProcessID: 0,
                at: 10.1
            ),
            .wheelMouse
        )
    }

    func testContinuousEventCreatedByMosIsMouse() {
        var classifier = ScrollSourceClassifier()

        XCTAssertEqual(
            classifier.classify(
                isContinuous: true,
                hasMomentumPhase: true,
                sourceProcessID: 49_758,
                at: 10
            ),
            .wheelMouse
        )
    }

    func testAllScrollRepresentationsReverseExactlyOnce() throws {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 4,
                wheel2: 0,
                wheel3: 0
            )
        )
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 4)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 4)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 32)

        ScrollEventController.reverseScrollAxes(in: event)

        XCTAssertEqual(
            event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            -4
        )
        XCTAssertEqual(
            event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            -4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            -32
        )
    }

    func testScrollAxesCanBeScaled() throws {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 4,
                wheel2: 0,
                wheel3: 0
            )
        )
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 4)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 4)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 32)

        ScrollEventController.scaleScrollAxes(in: event, multiplier: 1.5)

        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 6)
        XCTAssertEqual(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), 6, accuracy: 0.0001)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 48)
    }

    func testSpeedPreferencesClampToSupportedRange() throws {
        let suiteName = "ScrollTwinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = Preferences(defaults: defaults)

        preferences.wheelMouseSpeed = 3
        preferences.touchSurfaceSpeed = 0.1

        XCTAssertEqual(preferences.wheelMouseSpeed, 2)
        XCTAssertEqual(preferences.touchSurfaceSpeed, 0.5)
    }

    func testSmoothModelPreservesRequestedDistance() {
        var model = SmoothScrollModel(step: 35, angularFrequency: 18)
        model.enqueue(deltaX: 0, deltaY: 1, multiplier: 1)

        var total: Int32 = 0
        for _ in 0..<300 where model.hasPendingMotion {
            total += model.advance(by: 1.0 / 120.0).y
        }

        XCTAssertFalse(model.hasPendingMotion)
        XCTAssertEqual(total, 35, accuracy: 1)
    }

    func testSmoothModelReversalDropsOldDirectionTail() {
        var model = SmoothScrollModel(step: 35, angularFrequency: 18)
        model.enqueue(deltaX: 0, deltaY: 1, multiplier: 1)
        var beganMovingWithinResponseWindow = false
        for _ in 0..<6 {
            if model.advance(by: 1.0 / 120.0).y > 0 {
                beganMovingWithinResponseWindow = true
                break
            }
        }
        XCTAssertTrue(beganMovingWithinResponseWindow)

        model.enqueue(deltaX: 0, deltaY: -1, multiplier: 1)
        var reversedWithinResponseWindow = false
        for _ in 0..<12 {
            if model.advance(by: 1.0 / 120.0).y < 0 {
                reversedWithinResponseWindow = true
                break
            }
        }

        XCTAssertTrue(reversedWithinResponseWindow)
    }

    func testSyntheticMarkerCanBeRecognized() throws {
        let event = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 1,
                wheel2: 0,
                wheel3: 0
            )
        )
        event.setIntegerValueField(
            .eventSourceUserData,
            value: SmoothScrollEngine.syntheticEventMarker
        )

        XCTAssertTrue(SmoothScrollEngine.isSynthetic(event))
    }

    func testBalancedPresetKeepsVersionTwoTuning() {
        XCTAssertEqual(SmoothScrollPreset.balanced.step, 35)
        XCTAssertEqual(
            SmoothScrollPreset.balanced.angularFrequency,
            18,
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            SmoothScrollPreset.responsive.angularFrequency,
            SmoothScrollPreset.balanced.angularFrequency
        )
        XCTAssertLessThan(
            SmoothScrollPreset.soft.angularFrequency,
            SmoothScrollPreset.balanced.angularFrequency
        )
    }

    func testApplicationSmoothingExclusionCanBeToggled() throws {
        let suiteName = "ScrollTwinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = Preferences(defaults: defaults)
        let bundleIdentifier = "com.example.NativeSmoothApp"

        XCTAssertFalse(
            preferences.isSmoothingExcluded(for: bundleIdentifier)
        )
        preferences.setSmoothingExcluded(true, for: bundleIdentifier)
        XCTAssertTrue(
            preferences.isSmoothingExcluded(for: bundleIdentifier)
        )
        preferences.setSmoothingExcluded(false, for: bundleIdentifier)
        XCTAssertFalse(
            preferences.isSmoothingExcluded(for: bundleIdentifier)
        )
    }

    func testExcludedApplicationBypassesOnlySmoothing() {
        XCTAssertTrue(
            ScrollPolicy.shouldSmoothWheelMouse(
                isContinuous: false,
                smoothingEnabled: true,
                applicationIsExcluded: false
            )
        )
        XCTAssertFalse(
            ScrollPolicy.shouldSmoothWheelMouse(
                isContinuous: false,
                smoothingEnabled: true,
                applicationIsExcluded: true
            )
        )
        XCTAssertFalse(
            ScrollPolicy.shouldSmoothWheelMouse(
                isContinuous: true,
                smoothingEnabled: true,
                applicationIsExcluded: false
            )
        )

        let directionPolicy = ScrollPolicy(
            reverseWheelMouse: true,
            reverseTouchSurface: false
        )
        XCTAssertTrue(directionPolicy.shouldReverse(isContinuous: false))
    }
}
