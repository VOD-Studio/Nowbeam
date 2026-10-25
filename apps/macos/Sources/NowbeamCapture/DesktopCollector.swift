import AppKit
import ApplicationServices
import NowbeamCore

private let accessibilityChanged = Notification.Name("Nowbeam.accessibilityChanged")

private let accessibilityCallback: AXObserverCallback = { _, _, _, _ in
    NotificationCenter.default.post(name: accessibilityChanged, object: nil)
}

@MainActor
public final class DesktopCollector {
    public private(set) var application: ApplicationPresence?
    public private(set) var window: WindowPresence?
    public private(set) var accessibilityGranted = false
    public private(set) var windowDiagnostic = "窗口来源已关闭"
    public var onChange: (() -> Void)?

    private var preferences = SourcePreferences()
    private var suspended = true
    private var workspaceTokens: [NSObjectProtocol] = []
    private var accessibilityToken: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var applicationElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var pollingRequired = false

    public init() {}

    public func start() {
        guard workspaceTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        accessibilityToken = NotificationCenter.default.addObserver(
            forName: accessibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func configure(_ preferences: SourcePreferences, suspended: Bool) {
        guard self.preferences != preferences || self.suspended != suspended else { return }
        self.preferences = preferences
        self.suspended = suspended
        removeAccessibilityObserver()
        permissionTimer?.invalidate()
        permissionTimer = nil
        if preferences.windowEnabled && !suspended {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let granted = AXIsProcessTrusted()
                    if granted != self.accessibilityGranted || self.pollingRequired {
                        self.refresh()
                    }
                }
            }
            permissionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        refresh()
    }

    public func requestAccessibility() {
        guard preferences.windowEnabled else { return }
        // SDK 将这个只读键声明为可变 C 全局；使用已核实的公开键值，不降级 Swift 并发检查。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    // 发送前重新读取当前状态；不会重放应用切换前的缓存。
    public func refresh() {
        let oldApplication = application
        let oldWindow = window
        let oldDiagnostic = windowDiagnostic
        let oldPermission = accessibilityGranted
        defer {
            if oldApplication != application || oldWindow != window || oldDiagnostic != windowDiagnostic
                || oldPermission != accessibilityGranted {
                onChange?()
            }
        }
        application = nil
        window = nil
        accessibilityGranted = preferences.windowEnabled && !suspended && AXIsProcessTrusted()
        guard !suspended, preferences.applicationEnabled || preferences.windowEnabled else {
            removeAccessibilityObserver()
            windowDiagnostic = suspended ? "系统暂停采集" : "窗口来源已关闭"
            return
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated,
              let identifier = frontmost.bundleIdentifier else {
            removeAccessibilityObserver()
            windowDiagnostic = "没有可确认的前台应用"
            return
        }
        guard !preferences.hiddenApplications.contains(identifier) else {
            removeAccessibilityObserver()
            windowDiagnostic = "当前应用已隐藏，窗口不会读取"
            return
        }
        if preferences.applicationEnabled,
           let name = PublicText.clean(frontmost.localizedName, limit: 128) {
            application = ApplicationPresence(displayName: name)
        }
        guard preferences.windowEnabled else {
            removeAccessibilityObserver()
            windowDiagnostic = "窗口来源已关闭"
            return
        }
        guard preferences.allowedWindowApplications.contains(identifier) else {
            removeAccessibilityObserver()
            windowDiagnostic = "当前应用未在窗口白名单中，不读取标题"
            return
        }
        guard accessibilityGranted else {
            removeAccessibilityObserver()
            windowDiagnostic = "尚未获得辅助功能权限，不读取标题"
            return
        }
        installAccessibilityObserver(for: frontmost.processIdentifier)
        guard let applicationElement else { return }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            observeWindow(nil)
            windowDiagnostic = "当前应用没有可读取的聚焦窗口"
            return
        }
        let focusedWindow = unsafeDowncast(focused, to: AXUIElement.self)
        _ = AXUIElementSetMessagingTimeout(focusedWindow, 0.2)
        observeWindow(focusedWindow)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &title) == .success,
              let text = PublicText.clean(title as? String, limit: 1_024) else {
            windowDiagnostic = "当前聚焦窗口未提供可用标题"
            return
        }
        window = WindowPresence(title: text)
        windowDiagnostic = pollingRequired ? "已允许；当前应用使用有界刷新" : "已允许；正在观察聚焦窗口和标题变化"
    }

    private func installAccessibilityObserver(for pid: pid_t) {
        guard observedPID != pid else { return }
        removeAccessibilityObserver()
        observedPID = pid
        let element = AXUIElementCreateApplication(pid)
        applicationElement = element
        _ = AXUIElementSetMessagingTimeout(element, 0.2)
        var newObserver: AXObserver?
        guard AXObserverCreate(pid, accessibilityCallback, &newObserver) == .success,
              let newObserver else {
            pollingRequired = true
            return
        }
        observer = newObserver
        let result = AXObserverAddNotification(newObserver, element, kAXFocusedWindowChangedNotification as CFString, nil)
        pollingRequired = result != .success
        _ = AXObserverAddNotification(newObserver, element, kAXMainWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
    }

    private func observeWindow(_ element: AXUIElement?) {
        if let current = windowElement, let element, CFEqual(current, element) { return }
        if let observer, let previous = windowElement {
            _ = AXObserverRemoveNotification(observer, previous, kAXTitleChangedNotification as CFString)
            _ = AXObserverRemoveNotification(observer, previous, kAXUIElementDestroyedNotification as CFString)
        }
        windowElement = element
        if let observer, let element {
            let result = AXObserverAddNotification(observer, element, kAXTitleChangedNotification as CFString, nil)
            pollingRequired = pollingRequired || result != .success
            _ = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil)
        }
    }

    private func removeAccessibilityObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = nil
        applicationElement = nil
        windowElement = nil
        pollingRequired = false
    }

    public func stop() {
        removeAccessibilityObserver()
        permissionTimer?.invalidate()
        permissionTimer = nil
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        if let accessibilityToken { NotificationCenter.default.removeObserver(accessibilityToken) }
        accessibilityToken = nil
        application = nil
        window = nil
    }
}
