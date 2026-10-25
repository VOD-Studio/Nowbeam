import AppKit
import Combine
import NowbeamCore
import SwiftUI

@main
private enum NowbeamLauncher {
    @MainActor
    static func main() {
        // 菜单栏常驻上报：禁止系统在无窗口或空闲时自动终止，否则会绕过退出清理、静默断开。
        ProcessInfo.processInfo.disableAutomaticTermination("menu-bar-presence")
        ProcessInfo.processInfo.disableSuddenTermination()
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = ApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var settingsWindow: NSWindow?
    private var observation: AnyCancellable?
    private var exiting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        observation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refreshMenu() }
        }
        refreshMenu()
        showSettings()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        let sharing = model.configuration.sharingEnabled && model.sessionState.permitsCapture
        let image = NSImage(systemSymbolName: sharing ? "dot.radiowaves.left.and.right" : "pause.circle", accessibilityDescription: "Nowbeam")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = sharing ? "Nowbeam：正在分享允许的来源" : "Nowbeam：当前不分享活动"
        menu.removeAllItems()
        addLabel(model.configuration.sharingEnabled ? model.sessionState.description : "分享已暂停；已启用目标只接收空快照")
        addAction(model.configuration.sharingEnabled ? "暂停分享" : "恢复分享…", selector: #selector(toggleSharing))
        menu.addItem(.separator())
        let sources = sharing ? model.currentPreview() : Sources.empty
        addLabel("应用：" + (sources.application?.displayName ?? "不分享"))
        addLabel("窗口：" + (sources.window?.title ?? "不分享"))
        addLabel("媒体：" + (sources.media.map { $0.playerName + " · " + $0.title } ?? "不分享"))
        menu.addItem(.separator())
        if model.configuration.destinations.isEmpty {
            addLabel("尚未配置接收端")
        } else {
            for destination in model.configuration.destinations {
                let phase = model.statuses[destination.id]?.phase
                let state: String
                switch phase {
                case .confirmed: state = "已确认"
                case .connecting, .ready: state = "连接中，尚未确认"
                case .retrying: state = "等待重连"
                case .blocked: state = "需要处理授权或连接问题"
                default: state = "未连接"
                }
                addLabel(destination.name + " — " + state)
            }
        }
        menu.addItem(.separator())
        addAction("设置…", selector: #selector(showSettings), key: ",")
        addAction("退出 Nowbeam", selector: #selector(quit), key: "q")
    }

    private func addLabel(_ text: String) {
        let item = NSMenuItem(title: String(text.prefix(100)), action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, selector: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 690),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Nowbeam"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.minSize = NSSize(width: 780, height: 610)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("Nowbeam.Settings")
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleSharing() {
        if model.configuration.sharingEnabled { model.setSharing(false); return }
        guard model.enabledDestinationCount > 0 else { showSettings(); return }
        let alert = NSAlert()
        alert.messageText = "恢复分享？"
        alert.informativeText = "将把本地隐私规则允许的来源发送给 \(model.enabledDestinationCount) 个已启用目的地。接收方可能保存副本。可在设置中检查当前预览。"
        alert.addButton(withTitle: "恢复分享")
        alert.addButton(withTitle: "取消")
        showSettings()
        guard let settingsWindow else { return }
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.setSharing(true) }
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !exiting else { return .terminateLater }
        exiting = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
