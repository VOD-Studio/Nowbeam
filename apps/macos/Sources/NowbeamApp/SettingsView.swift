import NowbeamCore
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case preview = "分享与预览", sources = "来源与隐私", destinations = "接收端", receiver = "接收服务管理"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .preview: "dot.radiowaves.left.and.right"
        case .sources: "hand.raised.fill"
        case .destinations: "antenna.radiowaves.left.and.right"
        case .receiver: "server.rack"
        }
    }

    var tint: Color {
        switch self {
        case .preview: .blue
        case .sources: .indigo
        case .destinations: .teal
        case .receiver: .gray
        }
    }
}

/// 让菜单栏等窗口之外的入口能指定设置窗口停在哪一页。
@MainActor
final class SettingsNavigator: ObservableObject {
    @Published var selection: SettingsSection? = .preview

    init() {
        #if DEBUG
        // 仅开发构建：用环境变量直接停在某一页，便于截图验收各页外观。
        switch ProcessInfo.processInfo.environment["NOWBEAM_DEBUG_SECTION"] {
        case "sources": selection = .sources
        case "destinations": selection = .destinations
        case "receiver": selection = .receiver
        default: break
        }
        #endif
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigator: SettingsNavigator

    private func row(_ section: SettingsSection) -> some View {
        Label {
            Text(section.rawValue)
        } icon: {
            Image(systemName: section.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(section.tint)
        }
        .tag(section)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $navigator.selection) {
                Section("分享") {
                    row(.preview)
                    row(.sources)
                }
                Section("连接") {
                    row(.destinations)
                    row(.receiver)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .safeAreaInset(edge: .bottom) { SidebarFooter(model: model) }
        } detail: {
            Group {
                switch navigator.selection ?? .preview {
                case .preview: SharingView(model: model, navigate: { navigator.selection = $0 })
                case .sources: SourcesView(model: model)
                case .destinations: DestinationsView(model: model, navigate: { navigator.selection = $0 })
                case .receiver: ReceiverView(model: model)
                }
            }
            .background { AmbientBackground(tone: model.sharingState.tone) }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// 侧栏底部的全局状态：任何页面都能看到当前是否在分享。
@MainActor
private struct SidebarFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let state = model.sharingState
        HStack(spacing: 8) {
            Circle().fill(state.tone.fill).frame(width: 8, height: 8)
            Text(state.title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCapsule(tint: state.tone == .neutral ? nil : state.tone.fill)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .animation(.snappy(duration: 0.3), value: state)
        .accessibilityElement(children: .combine)
    }
}
