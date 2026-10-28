import NowbeamCore
import SwiftUI

/// 菜单栏点击后的面板：状态与主操作、准确预览、各接收端概况，一屏看完。
@MainActor
struct StatusPopover: View {
    @ObservedObject var model: AppModel
    let openSettings: (SettingsSection?) -> Void
    let quit: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 18) {
                previewSection
                destinationSection
            }
            .padding(16)
            Divider()
            footer
        }
        .frame(width: 340)
        .animation(.snappy(duration: 0.25), value: confirming)
    }

    // MARK: 状态与主操作

    private var header: some View {
        let state = model.sharingState
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SharingBadge(state: state, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline)
                    Text(subtitle(for: state))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if confirming {
                VStack(alignment: .leading, spacing: 10) {
                    Text("将把下方预览中的允许来源发送给 \(model.enabledDestinationCount) 个已启用的接收端。接收方可能另行保存数据。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("取消") { confirming = false }.frame(maxWidth: .infinity)
                        Button("恢复分享") { model.setSharing(true); confirming = false }
                            .prominentAction().frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            } else {
                primaryAction
            }
        }
        .padding(16)
        .background(LinearGradient(colors: [state.tone.fill.opacity(0.18), state.tone.fill.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom))
    }

    private func subtitle(for state: SharingState) -> String {
        switch state {
        case .sharing: "\(model.confirmedDestinationCount) / \(model.enabledDestinationCount) 个接收端已确认"
        case .paused: model.enabledDestinationCount == 0 ? "尚未启用接收端" : "已启用的接收端只收到空快照"
        case .protected: model.sessionState.description
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.configuration.sharingEnabled {
            Button { model.setSharing(false) } label: {
                Label("暂停分享", systemImage: "pause.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        } else if model.enabledDestinationCount == 0 {
            Button { openSettings(.destinations) } label: {
                Label("添加接收端…", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .prominentAction().controlSize(.large)
        } else {
            Button { confirming = true } label: {
                Label("恢复分享…", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .prominentAction().controlSize(.large)
        }
    }

    // MARK: 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.sharingState == .sharing ? "正在发送" : "恢复后将发送")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let sources = model.currentPreview()
                VStack(alignment: .leading, spacing: 8) {
                    line("macwindow", .blue, sources.application?.displayName)
                    line("text.below.photo", .purple, sources.window?.title)
                    mediaLine(sources.media)
                }
            }
        }
    }

    private func line(_ symbol: String, _ tint: Color, _ value: String?) -> some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, tint: tint, size: 24)
            Text(value ?? "未分享")
                .foregroundStyle(value == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func mediaLine(_ media: MediaPresence?) -> some View {
        if let media {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    IconBadge(symbol: media.playback.state == .playing ? "play.fill" : "pause.fill", tint: .pink, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(media.title).lineLimit(1).truncationMode(.tail)
                        Text(media.artist.map { "\($0) · \(media.playerName)" } ?? media.playerName)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let progress = media.progressDisplay {
                    ProgressView(value: progress.fraction).progressViewStyle(.linear).tint(.pink)
                        .padding(.leading, 34)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            line("music.note", .pink, nil)
        }
    }

    // MARK: 接收端

    private var destinationSection: some View {
        let all = model.configuration.destinations
        return VStack(alignment: .leading, spacing: 8) {
            Text("接收端").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if all.isEmpty {
                Text("尚未配置接收端").foregroundStyle(.secondary)
            }
            ForEach(all.prefix(4)) { destination in
                let presented = PresentedStatus(destination: destination, status: model.statuses[destination.id])
                HStack(spacing: 10) {
                    Circle().fill(presented.tone == .neutral ? Color.secondary.opacity(0.5) : presented.tone.color)
                        .frame(width: 8, height: 8)
                        .frame(width: 24)
                    Text(destination.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(presented.label)
                        .font(.subheadline)
                        .foregroundStyle(presented.tone == .neutral ? .secondary : presented.tone.color)
                }
                .accessibilityElement(children: .combine)
            }
            if all.count > 4 {
                Text("另有 \(all.count - 4) 个接收端，见设置").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Button { openSettings(nil) } label: { Label("设置…", systemImage: "gearshape") }
            Spacer()
            Button(action: quit) { Label("退出", systemImage: "power") }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
