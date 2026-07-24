import Foundation

final class Preferences: @unchecked Sendable {
    static let shared = Preferences()

    private enum Key {
        static let reverseWheelMouse = "reverseWheelMouse"
        static let reverseTouchSurface = "reverseTouchSurface"
        static let smoothWheelMouse = "smoothWheelMouse"
        static let smoothScrollPreset = "smoothScrollPreset"
        static let wheelMouseSpeed = "wheelMouseSpeed"
        static let touchSurfaceSpeed = "touchSurfaceSpeed"
        static let excludedAppBundleIdentifiers =
            "excludedAppBundleIdentifiers"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.reverseWheelMouse: true,
            Key.reverseTouchSurface: false,
            Key.smoothWheelMouse: true,
            Key.smoothScrollPreset: SmoothScrollPreset.balanced.rawValue,
            Key.wheelMouseSpeed: 1.0,
            Key.touchSurfaceSpeed: 1.0,
            Key.excludedAppBundleIdentifiers: [String]()
        ])
    }

    var reverseWheelMouse: Bool {
        get { defaults.bool(forKey: Key.reverseWheelMouse) }
        set { defaults.set(newValue, forKey: Key.reverseWheelMouse) }
    }

    var reverseTouchSurface: Bool {
        get { defaults.bool(forKey: Key.reverseTouchSurface) }
        set { defaults.set(newValue, forKey: Key.reverseTouchSurface) }
    }

    var smoothWheelMouse: Bool {
        get { defaults.bool(forKey: Key.smoothWheelMouse) }
        set { defaults.set(newValue, forKey: Key.smoothWheelMouse) }
    }

    var smoothScrollPreset: SmoothScrollPreset {
        get {
            guard let rawValue = defaults.string(
                forKey: Key.smoothScrollPreset
            ) else {
                return .balanced
            }
            return SmoothScrollPreset(rawValue: rawValue) ?? .balanced
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.smoothScrollPreset)
        }
    }

    var wheelMouseSpeed: Double {
        get { clampedSpeed(defaults.double(forKey: Key.wheelMouseSpeed)) }
        set { defaults.set(clampedSpeed(newValue), forKey: Key.wheelMouseSpeed) }
    }

    var touchSurfaceSpeed: Double {
        get { clampedSpeed(defaults.double(forKey: Key.touchSurfaceSpeed)) }
        set { defaults.set(clampedSpeed(newValue), forKey: Key.touchSurfaceSpeed) }
    }

    var excludedAppBundleIdentifiers: Set<String> {
        get {
            Set(
                defaults.stringArray(
                    forKey: Key.excludedAppBundleIdentifiers
                ) ?? []
            )
        }
        set {
            defaults.set(
                Array(newValue).sorted(),
                forKey: Key.excludedAppBundleIdentifiers
            )
        }
    }

    func isSmoothingExcluded(for bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return excludedAppBundleIdentifiers.contains(bundleIdentifier)
    }

    func setSmoothingExcluded(
        _ excluded: Bool,
        for bundleIdentifier: String
    ) {
        var identifiers = excludedAppBundleIdentifiers
        if excluded {
            identifiers.insert(bundleIdentifier)
        } else {
            identifiers.remove(bundleIdentifier)
        }
        excludedAppBundleIdentifiers = identifiers
    }

    var policy: ScrollPolicy {
        ScrollPolicy(
            reverseWheelMouse: reverseWheelMouse,
            reverseTouchSurface: reverseTouchSurface
        )
    }

    private func clampedSpeed(_ value: Double) -> Double {
        min(max(value, 0.5), 2.0)
    }
}
