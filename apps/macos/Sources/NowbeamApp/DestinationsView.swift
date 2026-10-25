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
            }
            if model.configuration.destinations.isEmpty {
                Section {
                    ContentUnavailableView("尚未添加接收端", systemImage: "network", description: Text("填写完整 WSS 地址与设备凭证。保存和连接检查都不会自动启用分享。"))
                }
            }
            ForEach(model.configuration.destinations) { destination in
                Section(destination.name) {
                    DestinationRow(model: model, destination: destination,
                        changeEnabled: { enabled in
                            if enabled { enabling = destination }
                            else { model.setDestinationEnabled(destination.id, enabled: false) }
                        },
                        edit: { editor = Editor(destination: destination) },
                        remove: { removing = destination }
                    )
                }
            }
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

    var body: some View {
        Toggle("启用此目的地", isOn: Binding(get: { destination.enabled }, set: changeEnabled))
        Text(destination.endpoint).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        let status = model.statuses[destination.id]
        Label(status?.message ?? "未启用，未发送任何活动。", systemImage: status?.phase == .confirmed ? "checkmark.circle" : "circle")
            .foregroundStyle(status?.phase == .confirmed ? Color.green : Color.secondary)
        if let date = status?.lastAcknowledgedAt {
            LabeledContent("最近一次接收方确认", value: date.formatted(date: .abbreviated, time: .standard))
        }
        if let probeResult { Text(probeResult).font(.callout).textSelection(.enabled) }
        HStack {
            Button(probing ? "检查中…" : "检查连接") {
                probing = true
                probeResult = nil
                Task {
                    do {
                        _ = try await model.probeDestination(destination)
                        probeResult = "身份和协议已验证；没有发送快照，也没有接管已有连接。"
                    } catch { probeResult = model.safeMessage(error) }
                    probing = false
                }
            }
            .disabled(probing)
            if destination.enabled {
                Button("重新连接") { model.reconnect(destination.id) }
            }
            Spacer()
            Button("重新配置…", action: edit)
            Button("移除…", role: .destructive, action: remove)
        }
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
                Button(probing ? "检查中…" : "只检查连接") {
                    probing = true
                    result = nil
                    Task {
                        do {
                            _ = try await DestinationConnection.probe(endpoint: endpoint, token: token, allowLoopback: model.allowLoopback)
                            result = "身份和协议已验证，未发送活动。仍需保存并明确启用。"
                        } catch { result = model.safeMessage(error) }
                        probing = false
                    }
                }
                .disabled(endpoint.isEmpty || token.isEmpty || probing)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存为未启用") {
                    if model.saveDestination(replacing: existing, name: name, endpoint: endpoint, token: token) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
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
