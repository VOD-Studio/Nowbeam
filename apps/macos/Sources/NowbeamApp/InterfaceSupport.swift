import AppKit
import NowbeamCore
import SwiftUI

// MARK: - 色调与状态语义

/// 全界面统一的状态色调。颜色之外必须同时有文字和图标，不能只靠色相传达状态。
enum Tone {
    case positive, active, attention, neutral

    var color: Color {
        switch self {
        case .positive: .green
        case .active: .accentColor
        case .attention: .orange
        case .neutral: .secondary
        }
    }

    /// 实心填充用色：中性态用灰色，保证符号可读。
    var fill: Color { self == .neutral ? .gray : color }
}

/// 整体分享的三种呈现：用户暂停、正在分享、系统保护导致不分享。
enum SharingState {
    case sharing, paused, protected

    var tone: Tone {
        switch self {
        case .sharing: .positive
        case .paused: .neutral
        case .protected: .attention
        }
    }

    var symbol: String {
        switch self {
        case .sharing: "dot.radiowaves.left.and.right"
        case .paused: "pause.fill"
        case .protected: "lock.shield.fill"
        }
    }

    var title: String {
        switch self {
        case .sharing: "正在分享允许的来源"
        case .paused: "分享已暂停"
        case .protected: "系统保护中，未分享活动"
        }
    }
}

extension AppModel {
    var sharingState: SharingState {
        guard configuration.sharingEnabled else { return .paused }
        return sessionState.permitsCapture ? .sharing : .protected
    }
}

/// 接收端连接状态的统一呈现。只有收到接收方 ACK 才是“已确认”，发送本身不算。
struct PresentedStatus {
    let label: String
    let symbol: String
    let tone: Tone
    let detail: String?
    var inFlight: Bool { symbol == "arrow.triangle.2.circlepath" }

    init(destination: Destination, status: ConnectionStatus?) {
        let message = status.map(\.message).flatMap { $0.isEmpty ? nil : $0 }
        switch status?.phase {
        case .confirmed:
            (label, symbol, tone, detail) = ("已确认", "checkmark.circle.fill", .positive, nil)
        case .ready, .connecting:
            (label, symbol, tone, detail) = ("连接中", "arrow.triangle.2.circlepath", .active, message ?? "尚未收到接收方确认")
        case .retrying:
            (label, symbol, tone, detail) = ("等待重连", "arrow.clockwise", .attention, message)
        case .blocked:
            (label, symbol, tone, detail) = ("需要处理", "exclamationmark.triangle.fill", .attention, message ?? "需要处理授权或连接问题")
        case .stopped, nil:
            if destination.enabled {
                (label, symbol, tone, detail) = ("启动中", "arrow.triangle.2.circlepath", .active, message)
            } else {
                (label, symbol, tone, detail) = ("未启用", "pause.circle", .neutral, message ?? "未启用，未发送任何活动。")
            }
        }
    }
}

// MARK: - Liquid Glass 封装

// 界面层不直接写 #available：macOS 26+ 用 Liquid Glass，旧系统退回系统材质。
// 约定：玻璃只用于“浮在内容之上”的一层（状态主卡、按钮、状态标签）；内容卡片用材质，避免玻璃叠玻璃。
extension View {
    /// 悬浮玻璃面板。`tint` 给玻璃着色，用于表达状态。
    @ViewBuilder
    func glassPanel(radius: CGFloat = 28, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0.opacity(0.32)) } ?? .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { if let tint { shape.fill(tint.opacity(0.12)) } }
                .overlay { shape.strokeBorder(Color.primary.opacity(0.08)) }
        }
    }

    /// 玻璃胶囊（状态标签）。
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0.opacity(0.38)) } ?? .regular, in: Capsule())
        } else {
            background((tint ?? .secondary).opacity(0.16), in: Capsule())
        }
    }

    /// 主操作：玻璃突出胶囊；旧系统退回 borderedProminent。
    @ViewBuilder
    func prominentAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    /// 次级操作：玻璃胶囊小按钮；旧系统退回 bordered。
    @ViewBuilder
    func secondaryAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
        }
    }

    /// 大号次级按钮（与 `prominentAction` 成对出现时使用）。
    @ViewBuilder
    func glassAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

// MARK: - 版式

/// 随状态变色的环境背景：给玻璃提供可折射的内容，同时让用户一眼看出当前是否在分享。
struct AmbientBackground: View {
    let tone: Tone

    var body: some View {
        let accent = tone.fill
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.62, 0.42], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    accent.opacity(0.30), Color.blue.opacity(0.12), Color.purple.opacity(0.16),
                    Color.teal.opacity(0.10), accent.opacity(0.14), Color.indigo.opacity(0.10),
                    Color.clear, Color.pink.opacity(0.07), accent.opacity(0.12),
                ]
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: tone)
        .accessibilityHidden(true)
    }
}

/// 内容页：可滚动、居中限宽的单列。页面标题交给窗口标题栏（`navigationTitle`），主操作放工具栏。
struct PageScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    private let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                content
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .navigationTitle(title)
    }
}

/// 卡片上方的小节标题。
struct SectionHeader<Trailing: View>: View {
    let title: String
    var caption: String?
    private let trailing: Trailing

    init(_ title: String, caption: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.caption = caption
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let caption {
                    Text(caption).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 6)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, caption: String? = nil) {
        self.init(title, caption: caption, trailing: { EmptyView() })
    }
}

/// 内容卡片：大圆角材质，无内边距，内部由行自己决定留白，分隔线才能贯通。
/// `tint` 用于需要强调的卡片（如公开读取已开启）。
struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(.thinMaterial)
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            .overlay { if let tint { shape.fill(tint.opacity(0.10)) } }
            .overlay { shape.strokeBorder(tint?.opacity(0.35) ?? Color.primary.opacity(0.07), lineWidth: 1) }
            .clipShape(shape)
    }
}

struct CardDivider: View {
    var body: some View { Divider().padding(.leading, 18).opacity(0.7) }
}

extension View {
    /// 卡片里一行的标准留白。
    func cardRow() -> some View {
        padding(.horizontal, 18).padding(.vertical, 13)
    }
}

// MARK: - 小组件

/// 扁平着色图标块：浅色底 + 同色符号，不用渐变和白色符号。
struct IconBadge: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 玻璃胶囊状态标签：着色玻璃 + 图标 + 文字。
struct StatusChip: View {
    let text: String
    let symbol: String
    let tone: Tone

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .glassCapsule(tint: tone == .neutral ? nil : tone.color)
    }
}

/// 卡片底部的细脚注，替代整段说明文字。
struct Footnote: View {
    let text: String
    var symbol = "info.circle"

    init(_ text: String, symbol: String = "info.circle") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// 应用图标；找不到应用时退回占位符号。
struct AppIcon: View {
    let identifier: String
    var size: CGFloat = 28

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 状态徽章与媒体进度

/// 状态徽章：着色圆底 + 同色符号，分享主卡与菜单栏面板共用。
struct SharingBadge: View {
    let state: SharingState
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: state.symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(state.tone.fill)
            .frame(width: size, height: size)
            .background(state.tone.fill.opacity(0.20), in: Circle())
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: state == .sharing && !reduceMotion)
            .accessibilityHidden(true)
    }
}

extension MediaPresence {
    /// 仅在时长与位置都可靠时返回进度；unknown 值不得伪造成固定进度。
    var progressDisplay: (fraction: Double, label: String)? {
        guard let total = playback.durationMs, total > 0, let position = playback.positionMs, position >= 0 else { return nil }
        func clock(_ milliseconds: Int64) -> String {
            let seconds = Int(milliseconds / 1_000)
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return (min(Double(position) / Double(total), 1), "\(clock(position)) / \(clock(total))")
    }
}
