import NowbeamCore
import SwiftUI

@MainActor
struct SourcesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PageScaffold("来源与隐私",
                     subtitle: "前台应用、窗口标题与媒体相互独立，各自开关。关闭一个来源会立即停止读取，而不是读取后在网络层丢弃。") {
            SourceCard(symbol: "macwindow", tint: .blue, title: "前台应用",
                       summary: "只分享当前前台应用的名称。", isOn: binding(\.applicationEnabled)) {
                RuleList(model: model, windowAllowed: false)
                Footnote("隐藏的应用同时不会读取窗口标题；不影响独立的媒体来源。")
            }
            SourceCard(symbol: "text.below.photo", tint: .purple, title: "窗口标题",
                       summary: "默认关闭。需要辅助功能权限，且仅限白名单应用。", isOn: binding(\.windowEnabled)) {
                HStack(spacing: 10) {
                    StatusChip(text: model.accessibilityGranted ? "辅助功能已授权" : "辅助功能未授权",
                               symbol: model.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                               tone: model.accessibilityGranted ? .positive : .attention)
                    Spacer(minLength: 8)
                    if !model.accessibilityGranted {
                        Button("授权辅助功能…") { model.requestAccessibility() }.secondaryAction()
                    }
                }
                Text(model.windowDiagnostic).font(.callout).foregroundStyle(.secondary)
                RuleList(model: model, windowAllowed: true)
                Footnote("只有白名单内、未被隐藏的应用才会读取标题。")
            }
            SourceCard(symbol: "music.note", tint: .pink, title: "媒体",
                       summary: "QQ 音乐、网易云音乐当前选中的播放会话。", isOn: binding(\.mediaEnabled)) {
                Text(model.mediaDiagnostic).font(.callout).foregroundStyle(.secondary)
                Footnote("只读取系统当前选中的有效会话，不读取账号、历史、缓存或音频；接口不可用、停止或退出时媒体为空，不回填旧曲目。")
            }
            ProtectionCard(model: model)
            #if DEBUG
            DebugLoopbackCard(model: model)
            #endif
        }
    }

    private func binding(_ keyPath: WritableKeyPath<SourcePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration.sources[keyPath: keyPath] }, set: { value in
            model.updateSources { $0[keyPath: keyPath] = value }
        })
    }
}

/// 一个来源 = 一张卡：标题行带开关，打开后才展开该来源的规则。
private struct SourceCard<Content: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let summary: String
    @Binding var isOn: Bool
    private let content: Content

    init(symbol: String, tint: Color, title: String, summary: String, isOn: Binding<Bool>,
         @ViewBuilder content: () -> Content) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.summary = summary
        _isOn = isOn
        self.content = content()
    }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconBadge(symbol: symbol, tint: tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
            }
            .padding(16)
            if isOn {
                Divider()
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.28), value: isOn)
    }
}

@MainActor
private struct RuleList: View {
    @ObservedObject var model: AppModel
    let windowAllowed: Bool

    private var identifiers: [String] {
        let preferences = model.configuration.sources
        return (windowAllowed ? preferences.allowedWindowApplications : preferences.hiddenApplications).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(windowAllowed ? "允许读取标题的应用" : "隐藏的应用").font(.subheadline.weight(.semibold))
                Spacer()
                Button(windowAllowed ? "允许一个应用…" : "隐藏一个应用…", systemImage: "plus") {
                    model.addApplicationRule(windowAllowed: windowAllowed)
                }
                .secondaryAction()
            }
            if identifiers.isEmpty {
                Text(windowAllowed ? "白名单为空：不会读取任何窗口标题。" : "尚未隐藏应用。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(identifiers.enumerated()), id: \.element) { index, identifier in
                        if index > 0 { Divider().padding(.leading, 48) }
                        HStack(spacing: 10) {
                            AppIcon(identifier: identifier)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.applicationLabel(identifier))
                                Text(identifier).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Button(windowAllowed ? "撤销允许" : "不再隐藏") {
                                model.updateSources { preferences in
                                    if windowAllowed { preferences.allowedWindowApplications.remove(identifier) }
                                    else { preferences.hiddenApplications.remove(identifier) }
                                }
                            }
                            .secondaryAction()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                }
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .animation(.snappy(duration: 0.25), value: identifiers)
            }
        }
    }
}

@MainActor
private struct ProtectionCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let protected = !model.sessionState.permitsCapture
        Card {
            HStack(spacing: 12) {
                IconBadge(symbol: "lock.shield.fill", tint: protected ? .orange : .green, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("系统保护").font(.headline)
                    Text("锁屏、睡眠或无法确认会话安全时，停止全部采集并只发送空快照。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                StatusChip(text: model.sessionState.description,
                           symbol: protected ? "lock.fill" : "checkmark.circle.fill",
                           tone: protected ? .attention : .positive)
            }
            .padding(16)
            Divider()
            Footnote("锁屏状态依赖系统字典中的未文档化字段；该字段无法确认时按受保护处理，不会默认当作已解锁。")
                .padding(16)
        }
    }
}

#if DEBUG
@MainActor
private struct DebugLoopbackCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconBadge(symbol: "hammer.fill", tint: .gray, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("仅开发构建").font(.headline)
                    Text("允许回环明文开发连接").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("允许回环明文开发连接", isOn: Binding(get: { model.allowLoopback }, set: model.setLoopbackAllowed))
                    .labelsHidden().toggleStyle(.switch)
            }
            .padding(16)
            Divider()
            Footnote("仅允许显式的 127.0.0.1 或 ::1，不放宽证书验证，也不允许局域网或公网明文；Release 构建没有此例外。")
                .padding(16)
        }
    }
}
#endif
