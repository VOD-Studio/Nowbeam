import NowbeamCore
import SwiftUI

@MainActor
struct SharingView: View {
    @ObservedObject var model: AppModel
    var navigate: (SettingsSection) -> Void = { _ in }
    @State private var confirmSharing = false

    private var sourcesChosen: Bool {
        let sources = model.configuration.sources
        return sources.applicationEnabled || sources.windowEnabled || sources.mediaEnabled
    }

    private var previewTitle: String {
        switch model.sharingState {
        case .protected: "系统保护中，不发送活动"
        case .sharing: "当前正在发送的内容"
        case .paused: "恢复分享后将发送的内容"
        }
    }

    var body: some View {
        PageScaffold("分享与预览") {
            SharingHero(model: model, resume: { confirmSharing = true }, addDestination: { navigate(.destinations) })
            if !model.configuration.sharingEnabled && !(sourcesChosen && model.enabledDestinationCount > 0) {
                SetupChecklist(sourcesChosen: sourcesChosen, hasDestination: !model.configuration.destinations.isEmpty,
                               destinationEnabled: model.enabledDestinationCount > 0, navigate: navigate)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(previewTitle, caption: "这是经过本地隐私规则过滤后的准确内容，预览与发送使用同一份结果。") {
                    Button("来源设置") { navigate(.sources) }.buttonStyle(.link)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    PreviewCard(model: model, refresh: context.date, navigate: navigate)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("发送到") {
                    Button("管理接收端") { navigate(.destinations) }.buttonStyle(.link)
                }
                DestinationOverview(model: model, addDestination: { navigate(.destinations) })
            }
            BoundaryNote()
        }
        .alert("恢复分享？", isPresented: $confirmSharing) {
            Button("恢复分享") { model.setSharing(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把预览中的允许来源发送给 \(model.enabledDestinationCount) 个已启用的接收端。接收方可能另行保存数据。")
        }
    }
}

// MARK: - 状态主卡

/// 页面最显眼的位置：当前状态 + 唯一的主操作。
@MainActor
private struct SharingHero: View {
    @ObservedObject var model: AppModel
    let resume: () -> Void
    let addDestination: () -> Void

    private var detail: String {
        let enabled = model.enabledDestinationCount
        switch model.sharingState {
        case .sharing:
            return enabled == 0
                ? "还没有启用的接收端，暂时不会发送给任何人。"
                : "已启用 \(enabled) 个接收端，\(model.confirmedDestinationCount) 个已收到确认。"
        case .paused:
            return enabled == 0
                ? "先添加并启用接收端；配置前仍可在本地选择来源、检查预览。"
                : "已启用的 \(enabled) 个接收端只会收到空快照，用来保持在线。"
        case .protected:
            return model.sessionState.description + "。接收端只会收到空快照。"
        }
    }

    var body: some View {
        let state = model.sharingState
        HStack(alignment: .center, spacing: 18) {
            SharingBadge(state: state, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(22)
        .glassPanel(radius: 32, tint: state.tone == .neutral ? nil : state.tone.fill)
        .animation(.snappy(duration: 0.3), value: state)
    }

    @ViewBuilder
    private var action: some View {
        if model.configuration.sharingEnabled {
            Button("暂停分享", systemImage: "pause.fill") { model.setSharing(false) }
                .glassAction()
                .controlSize(.large)
        } else if model.enabledDestinationCount == 0 {
            Button("添加接收端…", systemImage: "plus", action: addDestination)
                .prominentAction()
                .controlSize(.large)
        } else {
            Button("恢复分享…", systemImage: "play.fill", action: resume)
                .prominentAction()
                .controlSize(.large)
        }
    }
}

// MARK: - 首次使用清单

/// 仅在尚未具备分享条件时出现，提示还差哪一步；不替用户做任何授权。
private struct SetupChecklist: View {
    let sourcesChosen: Bool
    let hasDestination: Bool
    let destinationEnabled: Bool
    let navigate: (SettingsSection) -> Void

    var body: some View {
        Card {
            VStack(spacing: 0) {
                step(1, done: sourcesChosen, title: "选择要分享的来源",
                     detail: sourcesChosen ? "已开启至少一个来源" : "默认全部关闭，由你决定分享什么",
                     go: .sources)
                CardDivider()
                step(2, done: destinationEnabled, title: "添加并启用接收端",
                     detail: destinationEnabled ? "已有启用的接收端" : (hasDestination ? "已添加的接收端尚未启用" : "填写 wss:// 地址与设备凭证"),
                     go: .destinations)
                CardDivider()
                step(3, done: false, title: "检查预览，然后恢复分享", detail: "每次启动都需要你明确恢复", go: nil)
            }
        }
    }

    @ViewBuilder
    private func step(_ number: Int, done: Bool, title: String, detail: String, go: SettingsSection?) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.primary.opacity(0.08))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let go, !done {
                Button("前往") { navigate(go) }.secondaryAction()
            }
        }
        .cardRow()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 准确预览

@MainActor
private struct PreviewCard: View {
    @ObservedObject var model: AppModel
    let refresh: Date
    let navigate: (SettingsSection) -> Void

    var body: some View {
        let sources = model.currentPreview()
        let preferences = model.configuration.sources
        Card {
            PreviewLine(symbol: "macwindow", tint: .blue, title: "前台应用") {
                if let application = sources.application {
                    Text(application.displayName).textSelection(.enabled)
                } else {
                    EmptyValue(reason: preferences.applicationEnabled ? "当前没有可公开的应用" : "来源已关闭")
                }
            }
            CardDivider()
            PreviewLine(symbol: "text.below.photo", tint: .purple, title: "窗口标题") {
                if let window = sources.window {
                    Text(window.title).lineLimit(2).textSelection(.enabled)
                } else {
                    EmptyValue(reason: preferences.windowEnabled ? model.windowDiagnostic : "来源已关闭")
                }
            }
            CardDivider()
            PreviewLine(symbol: "music.note", tint: .pink, title: "媒体") {
                if let media = sources.media {
                    MediaDetail(media: media, at: refresh)
                } else {
                    EmptyValue(reason: preferences.mediaEnabled ? model.mediaDiagnostic : "来源已关闭")
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: sources)
    }
}

private struct PreviewLine<Value: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    private let value: Value

    init(symbol: String, tint: Color, title: String, @ViewBuilder value: () -> Value) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                value.font(.body)
            }
            Spacer(minLength: 0)
        }
        .cardRow()
    }
}

private struct EmptyValue: View {
    let reason: String

    var body: some View {
        HStack(spacing: 6) {
            Text("未分享")
            Text("· \(reason)").font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}

@MainActor
private struct MediaDetail: View {
    let media: MediaPresence
    let at: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var playing: Bool { media.playback.state == .playing }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(media.title).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                if let artist = media.artist {
                    Text(artist).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                StatusChip(text: playing ? "播放中" : "已暂停", symbol: playing ? "play.fill" : "pause.fill",
                           tone: playing ? .positive : .neutral)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing && !reduceMotion)
                Text(media.playerName).font(.subheadline).foregroundStyle(.secondary)
            }
            if let progress = media.progressDisplay {
                VStack(alignment: .trailing, spacing: 3) {
                    ProgressView(value: progress.fraction).progressViewStyle(.linear).tint(.pink)
                    Text(progress.label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 接收端概览

@MainActor
private struct DestinationOverview: View {
    @ObservedObject var model: AppModel
    let addDestination: () -> Void

    var body: some View {
        Card {
            if model.configuration.destinations.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.title3).foregroundStyle(.secondary).frame(width: 30)
                    Text("尚未添加接收端。").foregroundStyle(.secondary)
                    Spacer()
                    Button("添加…", action: addDestination).secondaryAction()
                }
                .cardRow()
            } else {
                let destinations = model.configuration.destinations
                ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
                    if index > 0 { CardDivider() }
                    DestinationOverviewRow(destination: destination, status: model.statuses[destination.id])
                }
            }
            CardDivider()
            Footnote("只有收到接收方的确认（ACK）才显示“已确认”；发送本身不等于已同步。")
                .cardRow()
        }
        .animation(.snappy(duration: 0.3), value: model.configuration.destinations)
    }
}

private struct DestinationOverviewRow: View {
    let destination: Destination
    let status: ConnectionStatus?

    var body: some View {
        let presented = PresentedStatus(destination: destination, status: status)
        HStack(spacing: 12) {
            IconBadge(symbol: "antenna.radiowaves.left.and.right", tint: destination.enabled ? .teal : .gray, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name).lineLimit(1)
                if let date = status?.lastAcknowledgedAt, presented.tone == .positive {
                    Text("最近确认 \(date.formatted(date: .omitted, time: .standard))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            StatusChip(text: presented.label, symbol: presented.symbol, tone: presented.tone)
                .symbolEffect(.pulse, options: .repeating, isActive: presented.inFlight)
        }
        .cardRow()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 边界说明

private struct BoundaryNote: View {
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text("暂停时，已启用的接收端仍可收到空快照，以区分“在线但没有活动”和“离线”。每次启动都需要你明确恢复分享。")
                Text("锁屏、权限撤销或来源失效会清空相应内容。网络中断时无法保证撤回立即送达；接收方必须在最后一次有效快照的 45 秒租约到期后清除。")
                Text("Nowbeam 不保存活动历史。但接收方可能另行保存已经收到的数据，无法保证删除对方保存的副本。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        } label: {
            Label("分享边界说明", systemImage: "hand.raised")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 2)
    }
}
