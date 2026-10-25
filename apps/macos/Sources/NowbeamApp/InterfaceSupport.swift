import SwiftUI

// MARK: - 玻璃材质降级

// 统一封装 macOS 26 Liquid Glass 与旧系统材质，界面层不直接写 #available 分支。
extension View {
    /// 表面卡片：26+ 液态玻璃，旧系统退回常规材质圆角卡。
    @ViewBuilder
    func surfaceCard(in shape: some Shape = RoundedRectangle(cornerRadius: 16, style: .continuous)) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// 强调主操作按钮：26+ 玻璃突出样式，旧系统退回 borderedProminent。
    @ViewBuilder
    func prominentAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// 次级玻璃操作按钮：旧系统退回 bordered。
    @ViewBuilder
    func glassAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: - 状态语义

enum SharingTone {
    case sharing, paused, protected

    var color: Color {
        switch self {
        case .sharing: .green
        case .paused: .secondary
        case .protected: .orange
        }
    }

    var symbol: String {
        switch self {
        case .sharing: "dot.radiowaves.left.and.right"
        case .paused: "pause.circle"
        case .protected: "lock.shield"
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

// MARK: - 状态徽章

struct StatusBadge: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
    }
}

// MARK: - 复用小组件

struct KeyValueRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
