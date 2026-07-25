import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    typealias CurrentApplication = (
        bundleIdentifier: String?,
        name: String?
    )

    private let preferences: Preferences
    private let scrollController: ScrollEventController
    private let currentApplication: () -> CurrentApplication?

    private let stateLabel = NSTextField(labelWithString: "")
    private let reverseMouseButton = NSButton(
        checkboxWithTitle: "反转普通鼠标滚轮",
        target: nil,
        action: nil
    )
    private let reverseTouchButton = NSButton(
        checkboxWithTitle: "反转触控板 / 触控表面",
        target: nil,
        action: nil
    )
    private let smoothMouseButton = NSButton(
        checkboxWithTitle: "平滑普通鼠标滚动",
        target: nil,
        action: nil
    )
    private let presetPopup = NSPopUpButton()
    private let wheelSpeedSlider = NSSlider()
    private let wheelSpeedValueLabel = NSTextField(labelWithString: "")
    private let touchSpeedSlider = NSSlider()
    private let touchSpeedValueLabel = NSTextField(labelWithString: "")
    private let excludeApplicationButton = NSButton(
        checkboxWithTitle: "对当前应用禁用平滑",
        target: nil,
        action: nil
    )
    private let clearExclusionsButton = NSButton(
        title: "清除应用排除列表",
        target: nil,
        action: nil
    )
    private let launchAtLoginButton = NSButton(
        checkboxWithTitle: "登录时启动",
        target: nil,
        action: nil
    )

    init(
        preferences: Preferences,
        scrollController: ScrollEventController,
        currentApplication: @escaping () -> CurrentApplication?
    ) {
        self.preferences = preferences
        self.scrollController = scrollController
        self.currentApplication = currentApplication

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 590),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScrollTwin 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        configureContent()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        refresh()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        reverseMouseButton.state =
            preferences.reverseWheelMouse ? .on : .off
        reverseTouchButton.state =
            preferences.reverseTouchSurface ? .on : .off
        smoothMouseButton.state =
            preferences.smoothWheelMouse ? .on : .off

        if let index = SmoothScrollPreset.allCases.firstIndex(
            of: preferences.smoothScrollPreset
        ) {
            presetPopup.selectItem(at: index)
        }
        presetPopup.isEnabled = preferences.smoothWheelMouse
        wheelSpeedSlider.doubleValue = preferences.wheelMouseSpeed
        wheelSpeedValueLabel.stringValue = speedText(preferences.wheelMouseSpeed)
        touchSpeedSlider.doubleValue = preferences.touchSurfaceSpeed
        touchSpeedValueLabel.stringValue = speedText(preferences.touchSurfaceSpeed)

        let application = currentApplication()
        if let bundleIdentifier = application?.bundleIdentifier {
            let name = application?.name ?? bundleIdentifier
            excludeApplicationButton.title =
                "对“\(name)”禁用平滑"
            excludeApplicationButton.state =
                preferences.isSmoothingExcluded(
                    for: bundleIdentifier
                ) ? .on : .off
            excludeApplicationButton.isEnabled =
                preferences.smoothWheelMouse
        } else {
            excludeApplicationButton.title = "对当前应用禁用平滑"
            excludeApplicationButton.state = .off
            excludeApplicationButton.isEnabled = false
        }

        clearExclusionsButton.isEnabled =
            !preferences.excludedAppBundleIdentifiers.isEmpty

        switch scrollController.state {
        case .stopped:
            stateLabel.stringValue = "状态：已停止"
        case .needsAccessibilityPermission:
            stateLabel.stringValue = "状态：需要辅助功能权限"
        case .running:
            stateLabel.stringValue = "状态：正在运行"
        case .failed:
            stateLabel.stringValue = "状态：无法创建滚动监听"
        }

        if #available(macOS 13.0, *) {
            launchAtLoginButton.state =
                SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            launchAtLoginButton.isHidden = true
        }
    }

    private func configureContent() {
        guard let contentView = window?.contentView else { return }

        stateLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor

        reverseMouseButton.target = self
        reverseMouseButton.action = #selector(toggleMouseDirection)
        reverseTouchButton.target = self
        reverseTouchButton.action = #selector(toggleTouchDirection)
        smoothMouseButton.target = self
        smoothMouseButton.action = #selector(toggleMouseSmoothing)

        presetPopup.addItems(
            withTitles: SmoothScrollPreset.allCases.map(\.title)
        )
        presetPopup.target = self
        presetPopup.action = #selector(selectSmoothPreset)

        configureSpeedSlider(wheelSpeedSlider, action: #selector(changeWheelSpeed))
        configureSpeedSlider(touchSpeedSlider, action: #selector(changeTouchSpeed))

        excludeApplicationButton.target = self
        excludeApplicationButton.action =
            #selector(toggleApplicationExclusion)
        clearExclusionsButton.target = self
        clearExclusionsButton.action = #selector(clearExclusions)
        clearExclusionsButton.bezelStyle = .inline

        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin)

        let title = NSTextField(
            labelWithString: "鼠标与触控板滚动"
        )
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let directionHint = NSTextField(
            wrappingLabelWithString:
                "方向设置基于 macOS 当前的“自然滚动”。触控板保持系统原生滚动，不参与平滑处理。"
        )
        directionHint.textColor = .secondaryLabelColor

        let smoothingLabel = NSTextField(
            labelWithString: "动画响应 / 停下速度"
        )
        smoothingLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let presetRow = NSStackView(views: [smoothingLabel, presetPopup])
        presetRow.orientation = .horizontal
        presetRow.distribution = .fill
        presetRow.spacing = 12

        let smoothingHint = NSTextField(
            wrappingLabelWithString:
                "灵敏会更快跟随输入并更快停下；柔和会延长动画尾部。不会改变每格滚动距离。"
        )
        smoothingHint.textColor = .secondaryLabelColor

        let speedLabel = NSTextField(labelWithString: "滚动距离（每一格）")
        speedLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let wheelSpeedRow = speedRow(
            title: "普通鼠标滚轮",
            slider: wheelSpeedSlider,
            valueLabel: wheelSpeedValueLabel
        )
        let touchSpeedRow = speedRow(
            title: "触控板 / 触控表面",
            slider: touchSpeedSlider,
            valueLabel: touchSpeedValueLabel
        )
        let speedHint = NSTextField(
            wrappingLabelWithString:
                "距离会立即生效。普通鼠标的动画响应在上方设置；触控板仍保留 macOS 原生手势和惯性。"
        )
        speedHint.textColor = .secondaryLabelColor

        let permissionButton = NSButton(
            title: "打开辅助功能权限设置…",
            target: self,
            action: #selector(openAccessibilitySettings)
        )
        let closeButton = NSButton(
            title: "关闭设置",
            target: self,
            action: #selector(closeSettings)
        )
        closeButton.keyEquivalent = "\r"
        let quitButton = NSButton(
            title: "退出 ScrollTwin",
            target: self,
            action: #selector(quit)
        )

        let actionRow = NSStackView(
            views: [permissionButton, NSView(), quitButton, closeButton]
        )
        actionRow.orientation = .horizontal
        actionRow.spacing = 10

        let stack = NSStackView(views: [
            title,
            stateLabel,
            separator(),
            reverseMouseButton,
            reverseTouchButton,
            directionHint,
            separator(),
            smoothMouseButton,
            presetRow,
            smoothingHint,
            speedLabel,
            wheelSpeedRow,
            touchSpeedRow,
            speedHint,
            excludeApplicationButton,
            clearExclusionsButton,
            separator(),
            launchAtLoginButton,
            actionRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        directionHint.maximumNumberOfLines = 3
        smoothingHint.maximumNumberOfLines = 2
        speedHint.maximumNumberOfLines = 2

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -24
            ),
            stack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: 24
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor,
                constant: -24
            ),
            directionHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            smoothingHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            speedHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            presetRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func configureSpeedSlider(_ slider: NSSlider, action: Selector) {
        slider.minValue = 0.5
        slider.maxValue = 2.0
        slider.numberOfTickMarks = 7
        slider.allowsTickMarkValuesOnly = false
        slider.target = self
        slider.action = action
    }

    private func speedRow(
        title: String,
        slider: NSSlider,
        valueLabel: NSTextField
    ) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 10
        slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        valueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        return row
    }

    private func speedText(_ speed: Double) -> String {
        "\(Int((speed * 100).rounded()))%"
    }

    @objc private func toggleMouseDirection() {
        preferences.reverseWheelMouse =
            reverseMouseButton.state == .on
        refresh()
    }

    @objc private func toggleTouchDirection() {
        preferences.reverseTouchSurface =
            reverseTouchButton.state == .on
        refresh()
    }

    @objc private func toggleMouseSmoothing() {
        preferences.smoothWheelMouse =
            smoothMouseButton.state == .on
        scrollController.preferencesDidChange()
        refresh()
    }

    @objc private func selectSmoothPreset() {
        let cases = SmoothScrollPreset.allCases
        guard cases.indices.contains(presetPopup.indexOfSelectedItem) else {
            return
        }
        preferences.smoothScrollPreset =
            cases[presetPopup.indexOfSelectedItem]
        scrollController.preferencesDidChange()
        refresh()
    }

    @objc private func changeWheelSpeed() {
        preferences.wheelMouseSpeed = wheelSpeedSlider.doubleValue
        refresh()
    }

    @objc private func changeTouchSpeed() {
        preferences.touchSurfaceSpeed = touchSpeedSlider.doubleValue
        refresh()
    }

    @objc private func toggleApplicationExclusion() {
        guard let bundleIdentifier =
                currentApplication()?.bundleIdentifier else {
            return
        }
        preferences.setSmoothingExcluded(
            excludeApplicationButton.state == .on,
            for: bundleIdentifier
        )
        scrollController.preferencesDidChange()
        refresh()
    }

    @objc private func clearExclusions() {
        preferences.excludedAppBundleIdentifiers = []
        scrollController.preferencesDidChange()
        refresh()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLoginButton.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginButton.state =
                SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "无法更改登录启动设置"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        refresh()
    }

    @objc private func closeSettings() {
        window?.close()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
