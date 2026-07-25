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
    private var statusItem: NSStatusItem?
    private var statusMenuTitleItem: NSMenuItem?
    private var smoothingMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement keeps the app out of the Dock. No NSStatusItem is
        // created, so there is no menu-bar icon either.
        NSApp.setActivationPolicy(.accessory)
        observeWorkspace()
        configureStatusItem()

        scrollController.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.settingsWindowController?.refresh()
                self?.refreshStatusItem(for: state)
            }
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

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        item.button?.image = NSImage(
            systemSymbolName: "arrow.up.arrow.down.circle",
            accessibilityDescription: "ScrollTwin"
        )
        item.button?.toolTip = "ScrollTwin"

        let menu = NSMenu()
        let title = NSMenuItem(title: "ScrollTwin", action: nil, keyEquivalent: "")
        title.isEnabled = false
        let openSettings = NSMenuItem(
            title: "打开设置…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        let smoothing = NSMenuItem(
            title: "平滑普通鼠标滚动",
            action: #selector(toggleSmoothingFromMenu),
            keyEquivalent: ""
        )
        let quit = NSMenuItem(
            title: "退出 ScrollTwin",
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        [openSettings, smoothing, quit].forEach { $0.target = self }
        menu.addItem(title)
        menu.addItem(openSettings)
        menu.addItem(smoothing)
        menu.addItem(.separator())
        menu.addItem(quit)
        item.menu = menu

        statusItem = item
        statusMenuTitleItem = title
        smoothingMenuItem = smoothing
        refreshStatusItem(for: scrollController.state)
    }

    private func refreshStatusItem(for state: ScrollEventController.State) {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let status: String
        switch state {
        case .running: status = "正在运行"
        case .needsAccessibilityPermission: status = "需要辅助功能权限"
        case .failed: status = "监听不可用"
        case .stopped: status = "已停止"
        }
        statusMenuTitleItem?.title = "ScrollTwin \(version) · \(status)"
        smoothingMenuItem?.state = preferences.smoothWheelMouse ? .on : .off
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    @objc private func toggleSmoothingFromMenu() {
        preferences.smoothWheelMouse.toggle()
        scrollController.preferencesDidChange()
        settingsWindowController?.refresh()
        refreshStatusItem(for: scrollController.state)
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
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
