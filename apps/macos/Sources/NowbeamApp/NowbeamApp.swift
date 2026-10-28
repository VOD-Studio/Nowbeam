import AppKit
import SwiftUI

/// 模型与导航状态由进程级单例持有：设置窗口、菜单栏面板和退出清理共用同一份。
@MainActor
enum AppEnvironment {
    static let model = AppModel()
    static let navigator = SettingsNavigator()
}

private let settingsWindowID = "settings"

// 设置窗口与菜单栏面板都交给 SwiftUI 场景管理：系统才会为其套用 macOS 26 的玻璃窗口外壳、
// 悬浮侧栏和菜单栏面板，同时自动提供标准的编辑菜单（⌘V 粘贴凭证依赖它）。
@main
struct NowbeamApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate

    init() {
        // 菜单栏常驻上报：禁止系统在无窗口或空闲时自动终止，否则会绕过退出清理、静默断开。
        ProcessInfo.processInfo.disableAutomaticTermination("menu-bar-presence")
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    var body: some Scene {
        Window("Nowbeam", id: settingsWindowID) {
            SettingsView(model: AppEnvironment.model, navigator: AppEnvironment.navigator)
                .frame(minWidth: 800, minHeight: 540)
        }
        .defaultSize(width: 940, height: 640)
        .defaultLaunchBehavior(.presented)
        .commands { SettingsCommands() }

        MenuBarExtra {
            StatusPanel()
        } label: {
            StatusIcon(model: AppEnvironment.model)
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        // 仅开发构建：MenuBarExtra 面板无法在不点击的情况下展示，这里提供同内容的普通窗口用于截图验收。
        Window("面板预览（仅开发构建）", id: "panel-preview") {
            StatusPanel().glassPanel(radius: 24).padding(8)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["NOWBEAM_DEBUG_PANEL"] == "1" ? .presented : .suppressed)
        #endif
    }
}

/// ⌘, 打开设置窗口。
private struct SettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { SettingsOpener.open(using: openWindow) }
                .keyboardShortcut(",")
        }
    }
}

@MainActor
private enum SettingsOpener {
    static func open(section: SettingsSection? = nil, using openWindow: OpenWindowAction) {
        if let section { AppEnvironment.navigator.selection = section }
        openWindow(id: settingsWindowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// 菜单栏图标：暂停与分享中用不同符号，不靠颜色区分。
private struct StatusIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sharing = model.sharingState == .sharing
        Image(systemName: sharing ? "dot.radiowaves.left.and.right" : "pause.circle")
            .accessibilityLabel(sharing ? "Nowbeam：正在分享允许的来源" : "Nowbeam：当前不分享活动")
    }
}

private struct StatusPanel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        StatusPopover(
            model: AppEnvironment.model,
            openSettings: { SettingsOpener.open(section: $0, using: openWindow) },
            quit: { NSApplication.shared.terminate(nil) }
        )
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var exiting = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NOWBEAM_DEBUG_APPEARANCE"] == "dark" {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        #endif
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !exiting else { return .terminateLater }
        exiting = true
        Task {
            await AppEnvironment.model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
