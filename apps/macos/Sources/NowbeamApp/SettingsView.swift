import AppKit
import NowbeamCore
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case preview = "分享与预览", sources = "来源与隐私", destinations = "接收端", receiver = "接收服务管理"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .preview: "dot.radiowaves.left.and.right"
        case .sources: "hand.raised"
        case .destinations: "network"
        case .receiver: "server.rack"
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsSection? = .preview

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nowbeam").font(.headline)
                    Text("当前状态，由你决定分享范围。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        } detail: {
            Group {
                switch selection ?? .preview {
                case .preview: SharingView(model: model)
                case .sources: SourcesView(model: model)
                case .destinations: DestinationsView(model: model)
                case .receiver: ReceiverView(model: model)
                }
            }
            .navigationTitle((selection ?? .preview).rawValue)
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .frame(minWidth: 760, minHeight: 570)
    }
}

@MainActor
private struct SharingView: View {
    @ObservedObject var model: AppModel
    @State private var confirmSharing = false

    private var activelySharing: Bool { model.configuration.sharingEnabled && model.sessionState.permitsCapture }
    private var sharingTitle: String {
        if !model.configuration.sharingEnabled { return "分享已暂停" }
        return activelySharing ? "正在分享允许的来源" : "系统保护中，未分享活动"
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: activelySharing ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .font(.title).foregroundStyle(activelySharing ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sharingTitle).font(.title2.weight(.semibold))
                        Text(model.sessionState.description).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(model.configuration.sharingEnabled ? "暂停分享" : "恢复分享…") {
                        if model.configuration.sharingEnabled { model.setSharing(false) }
                        else { confirmSharing = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.configuration.sharingEnabled && model.enabledDestinationCount == 0)
                }
                if model.enabledDestinationCount == 0 {
                    Text("先添加并启用接收端。配置前仍可在本地选择来源、检查预览。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("已启用 \(model.enabledDestinationCount) 个目的地；\(model.confirmedDestinationCount) 个已收到确认。发送不等于接收方确认。")
                        .foregroundStyle(.secondary)
                }
            }
            Section(!model.sessionState.permitsCapture ? "系统保护中，不发送活动" : (model.configuration.sharingEnabled ? "当前允许发送的内容" : "恢复分享后将发送的内容")) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let sources = model.currentPreview()
                    PreviewRow(label: "应用", value: sources.application?.displayName ?? "不分享")
                    PreviewRow(label: "窗口", value: sources.window?.title ?? "不分享")
                    if let media = sources.media {
                        PreviewRow(label: "媒体", value: media.title)
                        if let artist = media.artist { PreviewRow(label: "艺人", value: artist) }
                        if let album = media.album { PreviewRow(label: "专辑", value: album) }
                        PreviewRow(label: "播放器", value: media.playerName)
                        PreviewRow(label: "播放状态", value: media.playback.state == .playing ? "播放中" : "已暂停")
                        PreviewRow(label: "进度", value: playbackTime(media.playback.positionMs) + " / " + playbackTime(media.playback.durationMs))
                    } else {
                        PreviewRow(label: "媒体", value: "不分享")
                    }
                }
            }
            Section("分享边界") {
                Text("暂停时，已启用的接收端仍可收到空快照，以区分“在线但没有活动”和“离线”。每次启动都需要你明确恢复分享。")
                Text("锁屏、权限撤销或来源失效会清空相应内容。网络中断时无法保证撤回立即送达；接收方必须在最后一次有效快照的 45 秒租约到期后清除。")
                Text("Nowbeam 不保存活动历史。但接收方可能另行保存已经收到的数据，无法保证删除对方保存的副本。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("恢复分享？", isPresented: $confirmSharing) {
            Button("恢复分享") { model.setSharing(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把预览中的允许来源发送给 \(model.enabledDestinationCount) 个已启用的目的地。接收方可能另行保存数据。")
        }
    }

    private func playbackTime(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "未知" }
        let seconds = milliseconds / 1_000
        let suffix = String(format: "%02lld", seconds % 60)
        return "\(seconds / 60):\(suffix)"
    }
}

private struct PreviewRow: View {
    let label: String
    let value: String
    var body: some View {
        LabeledContent(label) {
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

@MainActor
private struct SourcesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("前台应用") {
                Toggle("分享当前前台应用的名称", isOn: sourceBinding(\.applicationEnabled))
                Text("开启后默认允许应用名称。隐藏规则同时阻止该应用的窗口标题，但不影响独立的媒体来源。")
                    .foregroundStyle(.secondary)
                ApplicationRules(model: model, windowAllowed: false)
            }
            Section("窗口标题") {
                Toggle("分享聚焦窗口标题", isOn: sourceBinding(\.windowEnabled))
                Text("只有白名单内、未隐藏的应用才会读取标题。关闭此来源会停止读取，而不是读取后丢弃。")
                    .foregroundStyle(.secondary)
                HStack {
                    Text(model.windowDiagnostic).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("授权辅助功能…") { model.requestAccessibility() }
                        .disabled(!model.configuration.sources.windowEnabled)
                }
                ApplicationRules(model: model, windowAllowed: true)
            }
            Section("媒体") {
                Toggle("分享当前媒体会话", isOn: sourceBinding(\.mediaEnabled))
                Text("面向 QQ 音乐、网易云音乐；只读取系统当前选中的有效会话，不读取账号、历史、缓存或音频。")
                    .foregroundStyle(.secondary)
                Text(model.mediaDiagnostic).font(.callout)
                Text("未知时长、进度或播放速率不会伪造成固定值。接口不可用、停止或退出时媒体为空，不回填旧曲目。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("系统保护") {
                Text(model.sessionState.description)
                Text("锁定状态无法确认时停止全部采集。读取锁定状态依赖系统字典中的未文档化字段；字段缺失时不会默认解锁。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            #if DEBUG
            Section("仅开发构建") {
                Toggle("允许回环明文开发连接", isOn: Binding(get: { model.allowLoopback }, set: model.setLoopbackAllowed))
                Text("仅允许显式的 127.0.0.1 或 ::1。不会放宽证书验证，也不允许局域网或公网明文；Release 构建没有此例外。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
    }

    private func sourceBinding(_ keyPath: WritableKeyPath<SourcePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration.sources[keyPath: keyPath] }, set: { value in
            model.updateSources { $0[keyPath: keyPath] = value }
        })
    }
}

@MainActor
private struct ApplicationRules: View {
    @ObservedObject var model: AppModel
    let windowAllowed: Bool
    private var identifiers: [String] {
        let preferences = model.configuration.sources
        return (windowAllowed ? preferences.allowedWindowApplications : preferences.hiddenApplications).sorted()
    }

    var body: some View {
        if identifiers.isEmpty {
            Text(windowAllowed ? "白名单为空：不会读取任何窗口标题。" : "尚未隐藏应用。")
                .font(.callout).foregroundStyle(.secondary)
        }
        ForEach(identifiers, id: \.self) { identifier in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.applicationLabel(identifier))
                    Text(identifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button(windowAllowed ? "撤销允许" : "不再隐藏") {
                    model.updateSources { preferences in
                        if windowAllowed { preferences.allowedWindowApplications.remove(identifier) }
                        else { preferences.hiddenApplications.remove(identifier) }
                    }
                }
            }
        }
        Button(windowAllowed ? "允许一个应用…" : "隐藏一个应用…", systemImage: "plus") {
            model.addApplicationRule(windowAllowed: windowAllowed)
        }
    }
}
