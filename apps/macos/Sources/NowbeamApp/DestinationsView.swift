import NowbeamCore
import SwiftUI

@MainActor
struct DestinationsView: View {
    private struct Editor: Identifiable {
        let id = UUID()
        let destination: Destination?
    }
    @ObservedObject var model: AppModel
    @State private var editor: Editor?
    @State private var enabling: Destination?
    @State private var removing: Destination?

    var body: some View {
        Form {
            Section {
                Text("软件直接连接每个目的地，不经过强制中转。第三方只需实现 Nowbeam v1 上报协议，不必实现接收服务管理 API。")
                    .foregroundStyle(.secondary)
                Button("添加接收端…", systemImage: "plus") { editor = Editor(destination: nil) }
                    .glassAction()
            }
            if model.configuration.destinations.isEmpty {
                Section {
                    ContentUnavailableView("尚未添加接收端", systemImage: "network", description: Text("填写完整 WSS 地址与设备凭证。保存和连接检查都不会自动启用分享。"))
                }
            }
            ForEach(model.configuration.destinations) { destination in
                Section {
                    DestinationRow(model: model, destination: destination,
                        changeEnabled: { enabled in
                            if enabled { enabling = destination }
                            else { model.setDestinationEnabled(destination.id, enabled: false) }
                        },
                        edit: { editor = Editor(destination: destination) },
                        remove: { removing = destination }
                    )
                    .padding(.vertical, 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } header: {
                    Text(destination.name)
                }
            }
            .animation(.snappy(duration: 0.3), value: model.configuration.destinations)
        }
        .formStyle(.grouped)
        .sheet(item: $editor) { context in DestinationEditor(model: model, existing: context.destination) }
        .alert("启用此接收端？", isPresented: Binding(get: { enabling != nil }, set: { if !$0 { enabling = nil } }), presenting: enabling) { destination in
            Button("启用") { model.setDestinationEnabled(destination.id, enabled: true); enabling = nil }
            Button("取消", role: .cancel) { enabling = nil }
        } message: { destination in
            Text("目的地：\(destination.name)。整体分享开启时会立即发送允许的来源；整体暂停时只发送空快照。")
        }
        .alert("移除接收端？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { destination in
            Button("移除", role: .destructive) { model.removeDestination(destination); removing = nil }
            Button("取消", role: .cancel) { removing = nil }
        } message: { _ in
            Text("会清空并关闭本机连接、删除本机凭证。不等于撤销服务器设备；需要全局撤销时，请使用对应服务的管理功能。")
        }
    }
}

@MainActor
private struct DestinationRow: View {
    @ObservedObject var model: AppModel
    let destination: Destination
    let changeEnabled: @MainActor @Sendable (Bool) -> Void
    let edit: () -> Void
    let remove: () -> Void
    @State private var probing = false
    @State private var probeResult: String?

    private var status: ConnectionStatus? { model.statuses[destination.id] }
    private var confirmed: Bool { status?.phase == .confirmed }

    private var statusBadge: StatusBadge {
        switch status?.phase {
        case .confirmed: StatusBadge(text: "已确认", symbol: "checkmark.circle.fill", color: .green)
        case .ready, .connecting: StatusBadge(text: status?.message ?? "连接中，尚未确认", symbol: "link", color: .accentColor)
        case .retrying: StatusBadge(text: status?.message ?? "等待重连", symbol: "arrow.clockwise", color: .orange)
        case .blocked: StatusBadge(text: status?.message ?? "需要处理授权或连接问题", symbol: "exclamationmark.triangle", color: .orange)
        default: StatusBadge(text: status?.message ?? "未启用，未发送任何活动。", symbol: "circle.dashed", color: .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: confirmed ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(destination.enabled ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.3), value: destination.enabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.name).font(.headline)
                    Text(destination.endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Toggle("启用此目的地", isOn: Binding(get: { destination.enabled }, set: changeEnabled))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .fixedSize()
            }
            statusBadge
                .symbolEffect(.bounce, value: status?.phase)
                .symbolEffect(.pulse, options: .repeating, isActive: status?.phase == .connecting || status?.phase == .retrying)
            if let date = status?.lastAcknowledgedAt {
                KeyValueRow(label: "最近一次接收方确认", value: date.formatted(date: .abbreviated, time: .standard))
            }
            if let probeResult {
                Text(probeResult)
                    .font(.callout)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 8) {
                Button {
                    probing = true
                    probeResult = nil
                    Task {
                        do {
                            _ = try await model.probeDestination(destination)
                            probeResult = "身份和协议已验证；没有发送快照，也没有接管已有连接。"
                        } catch { probeResult = model.safeMessage(error) }
                        probing = false
                    }
                } label: {
                    Label(probing ? "检查中…" : "检查连接", systemImage: probing ? "hourglass" : "stethoscope")
                }
                .glassAction()
                .disabled(probing)
                if destination.enabled {
                    Button { model.reconnect(destination.id) } label: {
                        Label("重新连接", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .glassAction()
                }
                Spacer(minLength: 8)
                Menu {
                    Button("重新配置…", systemImage: "slider.horizontal.3", action: edit)
                    Button("移除…", systemImage: "trash", role: .destructive, action: remove)
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .animation(.snappy(duration: 0.25), value: probeResult)
        .animation(.snappy(duration: 0.25), value: status?.phase)
    }
}

@MainActor
private struct DestinationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let existing: Destination?
    @State private var name = ""
    @State private var endpoint = ""
    @State private var token = ""
    @State private var probing = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "添加接收端" : "重新配置接收端").font(.title2.weight(.semibold))
            Form {
                TextField("本地名称", text: $name)
                TextField("完整 WSS 地址", text: $endpoint, prompt: Text("wss://receiver.example/api/v1/ingest"))
                    .autocorrectionDisabled()
                SecureField("设备上报凭证", text: $token)
                    .autocorrectionDisabled()
            }
            Text("凭证仅存入 Keychain。保存后保持未启用；地址或身份变化不会自动迁移已有分享许可。替换时会关闭旧连接并删除旧凭证。")
                .font(.callout).foregroundStyle(.secondary)
            if let result { Text(result).font(.callout).textSelection(.enabled) }
            HStack {
                Button {
                    probing = true
                    result = nil
                    Task {
                        do {
                            _ = try await DestinationConnection.probe(endpoint: endpoint, token: token, allowLoopback: model.allowLoopback)
                            result = "身份和协议已验证，未发送活动。仍需保存并明确启用。"
                        } catch { result = model.safeMessage(error) }
                        probing = false
                    }
                } label: {
                    Label(probing ? "检查中…" : "只检查连接", systemImage: "stethoscope")
                }
                .glassAction()
                .disabled(endpoint.isEmpty || token.isEmpty || probing)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存为未启用") {
                    if model.saveDestination(replacing: existing, name: name, endpoint: endpoint, token: token) { dismiss() }
                }
                .prominentAction()
                .disabled(name.isEmpty || endpoint.isEmpty || token.isEmpty || probing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(probing)
        .onAppear {
            name = existing?.name ?? ""
            endpoint = existing?.endpoint ?? ""
        }
    }
}
