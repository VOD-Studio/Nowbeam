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

    /// 侧栏符号各自固定语义色，贴近系统设置的导航观感。
    var tint: Color {
        switch self {
        case .preview: .blue
        case .sources: .purple
        case .destinations: .teal
        case .receiver: .indigo
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
                Label(section.rawValue, systemImage: section.symbol)
                    .foregroundStyle(section.tint)
                    .symbolVariant(.none)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 175, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter(model: model)
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
            .id(selection ?? .preview)
            .transition(.opacity)
            .animation(.snappy(duration: 0.22), value: selection)
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

/// 侧栏底部状态卡：玻璃材质上以色点与短文案呈现当前会话状态。
@MainActor
private struct SidebarFooter: View {
    @ObservedObject var model: AppModel

    private var tone: SharingTone {
        guard model.configuration.sharingEnabled else { return .paused }
        return model.sessionState.permitsCapture ? .sharing : .protected
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone.color)
                .frame(width: 8, height: 8)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: tone == .sharing)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nowbeam").font(.headline)
                Text(tone.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.3), value: tone == .sharing)
    }
}

@MainActor
struct SharingView: View {
    @ObservedObject var model: AppModel
    @State private var confirmSharing = false

    private var activelySharing: Bool { model.configuration.sharingEnabled && model.sessionState.permitsCapture }

    private var tone: SharingTone {
        guard model.configuration.sharingEnabled else { return .paused }
        return model.sessionState.permitsCapture ? .sharing : .protected
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(tone.color)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: activelySharing)
                        .frame(width: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tone.title).font(.title3.weight(.semibold))
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.3), value: tone.title)
                        Text(model.sessionState.description).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(model.configuration.sharingEnabled ? "暂停分享" : "恢复分享…") {
                        if model.configuration.sharingEnabled { model.setSharing(false) }
                        else { confirmSharing = true }
                    }
                    .prominentAction()
                    .controlSize(.large)
                    .disabled(!model.configuration.sharingEnabled && model.enabledDestinationCount == 0)
                }
                .padding(.vertical, 6)
                .animation(.snappy(duration: 0.3), value: activelySharing)
                if model.enabledDestinationCount == 0 {
                    Label("先添加并启用接收端。配置前仍可在本地选择来源、检查预览。", systemImage: "arrow.up.doc")
                        .foregroundStyle(.secondary)
                } else {
                    Label("已启用 \(model.enabledDestinationCount) 个目的地；\(model.confirmedDestinationCount) 个已收到确认。发送不等于接收方确认。",
                          systemImage: "checkmark.seal")
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.25), value: model.confirmedDestinationCount)
                }
            }
            Section(!model.sessionState.permitsCapture ? "系统保护中，不发送活动" : (model.configuration.sharingEnabled ? "当前允许发送的内容" : "恢复分享后将发送的内容")) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SourcePreview(model: model, refresh: context.date)
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
}

/// 预览区：应用、窗口、媒体三个来源芯片；媒体芯片含真实进度与播放徽章。
@MainActor
private struct SourcePreview: View {
    @ObservedObject var model: AppModel
    let refresh: Date

    var body: some View {
        let sources = model.currentPreview()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SourceChip(title: "应用", symbol: "macwindow.on.rectangle", tint: .blue,
                           value: sources.application?.displayName, placeholder: "不分享")
                SourceChip(title: "窗口", symbol: "rectangle.bottomthird.inset.filled", tint: .purple,
                           value: sources.window?.title, placeholder: "默认关闭")
            }
            MediaChip(media: sources.media, at: refresh)
        }
        .animation(.snappy(duration: 0.3), value: sources)
    }
}

@MainActor
private struct SourceChip: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String?
    let placeholder: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value ?? placeholder)
                    .font(.callout.weight(value == nil ? .regular : .medium))
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(value == nil ? 0.72 : 1)
    }
}

@MainActor
private struct MediaChip: View {
    let media: MediaPresence?
    let at: Date

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "music.note")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.pink)
                .frame(width: 22)
            if let media {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(media.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                        if let artist = media.artist {
                            Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        PlaybackBadge(state: media.playback.state)
                    }
                    .contentTransition(.numericText())
                    if let progress = playbackProgress(media) {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .tint(.pink)
                        HStack(spacing: 4) {
                            Text(progress.label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(media.playerName).font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(media.playerName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("媒体").font(.caption2).foregroundStyle(.secondary)
                    Text("不分享").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(media == nil ? 0.72 : 1)
    }

    /// 仅在时长与位置都可靠时绘制进度；unknown 值不得伪造成固定进度。
    private func playbackProgress(_ media: MediaPresence) -> (fraction: Double, label: String)? {
        let total = media.playback.durationMs
        let position = media.playback.positionMs
        guard let total, total > 0, let position, position >= 0 else { return nil }
        let clamped = min(Double(position) / Double(total), 1)
        return (clamped, "\(clock(position)) / \(clock(total))")
    }

    private func clock(_ milliseconds: Int64) -> String {
        let seconds = Int(milliseconds / 1_000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

@MainActor
private struct PlaybackBadge: View {
    let state: Playback.State

    var body: some View {
        Label(state == .playing ? "播放中" : "已暂停",
              systemImage: state == .playing ? "play.fill" : "pause.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(state == .playing ? Color.pink : Color.secondary)
            .labelStyle(.titleAndIcon)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: state == .playing)
    }
}

@MainActor
struct SourcesView: View {
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
                    Label(model.windowDiagnostic, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("授权辅助功能…") { model.requestAccessibility() }
                        .glassAction()
                        .disabled(!model.configuration.sources.windowEnabled)
                }
                ApplicationRules(model: model, windowAllowed: true)
            }
            Section("媒体") {
                Toggle("分享当前媒体会话", isOn: sourceBinding(\.mediaEnabled))
                Text("面向 QQ 音乐、网易云音乐；只读取系统当前选中的有效会话，不读取账号、历史、缓存或音频。")
                    .foregroundStyle(.secondary)
                Label(model.mediaDiagnostic, systemImage: "waveform")
                    .font(.callout)
                Text("未知时长、进度或播放速率不会伪造成固定值。接口不可用、停止或退出时媒体为空，不回填旧曲目。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("系统保护") {
                Label(model.sessionState.description, systemImage: "lock.shield")
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
            HStack(spacing: 10) {
                Image(systemName: "app.badge")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.applicationLabel(identifier))
                    Text(identifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button(windowAllowed ? "撤销允许" : "不再隐藏", systemImage: "minus.circle") {
                    model.updateSources { preferences in
                        if windowAllowed { preferences.allowedWindowApplications.remove(identifier) }
                        else { preferences.hiddenApplications.remove(identifier) }
                    }
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .animation(.snappy(duration: 0.28), value: identifiers)
        Button(windowAllowed ? "允许一个应用…" : "隐藏一个应用…", systemImage: "plus") {
            model.addApplicationRule(windowAllowed: windowAllowed)
        }
    }
}
