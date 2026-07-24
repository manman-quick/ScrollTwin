import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences.shared
    private lazy var scrollController = ScrollEventController(
        preferences: preferences
    )
    private var settingsWindowController: SettingsWindowController?
    private var healthCheckTimer: Timer?
    private var activeAppBundleIdentifier: String?
    private var activeAppName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement keeps the app out of the Dock. No NSStatusItem is
        // created, so there is no menu-bar icon either.
        NSApp.setActivationPolicy(.accessory)
        observeWorkspace()

        scrollController.onStateChange = { [weak self] _ in
            self?.settingsWindowController?.refresh()
        }
        scrollController.start(promptForPermission: true)
        healthCheckTimer = Timer.scheduledTimer(
            timeInterval: 2,
            target: self,
            selector: #selector(performHealthCheck),
            userInfo: nil,
            repeats: true
        )
        showSettings()
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthCheckTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        scrollController.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    @objc private func performHealthCheck() {
        scrollController.healthCheck()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        scrollController.healthCheck()
    }

    @objc private func workspaceDidActivateApplication(
        _ notification: Notification
    ) {
        guard let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication else {
            return
        }
        updateActiveApplication(application)
    }

    private func showSettings() {
        updateActiveApplication(NSWorkspace.shared.frontmostApplication)

        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                preferences: preferences,
                scrollController: scrollController,
                currentApplication: { [weak self] in
                    guard let self else { return nil }
                    return (
                        bundleIdentifier: self.activeAppBundleIdentifier,
                        name: self.activeAppName
                    )
                }
            )
        }
        settingsWindowController?.show()
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceDidActivateApplication),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        updateActiveApplication(NSWorkspace.shared.frontmostApplication)
    }

    private func updateActiveApplication(
        _ application: NSRunningApplication?
    ) {
        guard let application,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }
        activeAppBundleIdentifier = application.bundleIdentifier
        activeAppName = application.localizedName
        scrollController.setActiveApplication(
            bundleIdentifier: application.bundleIdentifier
        )
        settingsWindowController?.refresh()
    }
}
