import NowbeamCore
import SwiftUI

@MainActor
struct DestinationsView: View {
    private struct Editor: Identifiable {
        let id = UUID()
        let destination: Destination?
    }
    @ObservedObject var model: AppModel
    var navigate: (SettingsSection) -> Void = { _ in }
    @State private var editor: Editor?
    @State private var enabling: Destination?
    @State private var removing: Destination?

    var body: some View {
        PageScaffold("接收端",
                     subtitle: "软件直接连接每个接收端，不经过强制中转；第三方只需实现 Nowbeam v1 上报协议，无需实现接收服务管理 API。") {
            if model.configuration.destinations.isEmpty {
                EmptyDestinations(add: { editor = Editor(destination: nil) }, openService: { navigate(.receiver) })
            } else {
                VStack(spacing: 14) {
                    ForEach(model.configuration.destinations) { destination in
                        DestinationCard(model: model, destination: destination,
                            changeEnabled: { enabled in
                                if enabled { enabling = destination }
                                else { model.setDestinationEnabled(destination.id, enabled: false) }
                            },
                            edit: { editor = Editor(destination: destination) },
                            remove: { removing = destination }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                Footnote("每个接收端有独立的设备身份、凭证、连接和错误；一个失败不会影响另一个。新添加或替换的接收端默认不启用。")
            }
        }
        .toolbar {
            if !model.configuration.destinations.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = Editor(destination: nil) } label: { Label("添加接收端…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: model.configuration.destinations)
        .sheet(item: $editor) { context in DestinationEditor(model: model, existing: context.destination) }
        .alert("启用此接收端？", isPresented: Binding(get: { enabling != nil }, set: { if !$0 { enabling = nil } }), presenting: enabling) { destination in
            Button("启用") { model.setDestinationEnabled(destination.id, enabled: true); enabling = nil }
            Button("取消", role: .cancel) { enabling = nil }
        } message: { destination in
            Text("接收端：\(destination.name)。整体分享开启时会立即发送允许的来源；整体暂停时只发送空快照。")
        }
        .alert("移除接收端？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { destination in
            Button("移除", role: .destructive) { model.removeDestination(destination); removing = nil }
            Button("取消", role: .cancel) { removing = nil }
        } message: { _ in
            Text("会清空并关闭本机连接、删除本机凭证。不等于撤销服务器设备；需要全局撤销时，请使用对应服务的管理功能。")
        }
    }
}

private struct EmptyDestinations: View {
    let add: () -> Void
    let openService: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 14) {
                IconBadge(symbol: "antenna.radiowaves.left.and.right", tint: .teal, size: 52)
                VStack(spacing: 6) {
                    Text("还没有接收端").font(.title3.weight(.semibold))
                    Text("填写接收方提供的完整 wss:// 地址和设备凭证。保存与连接检查都不会自动启用，也不会开始分享。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
                Button("添加接收端…", systemImage: "plus", action: add)
                    .prominentAction()
                    .controlSize(.large)
                HStack(spacing: 4) {
                    Text("没有自己的接收端？").foregroundStyle(.secondary)
                    Button("使用自托管的 Nowbeam 接收服务", action: openService).buttonStyle(.link)
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .padding(.horizontal, 20)
        }
    }
}

@MainActor
private struct DestinationCard: View {
    @ObservedObject var model: AppModel
    let destination: Destination
    let changeEnabled: @MainActor @Sendable (Bool) -> Void
    let edit: () -> Void
    let remove: () -> Void
    @State private var probing = false
    @State private var probeResult: String?

    private var status: ConnectionStatus? { model.statuses[destination.id] }

    var body: some View {
        let presented = PresentedStatus(destination: destination, status: status)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    IconBadge(symbol: "antenna.radiowaves.left.and.right", tint: destination.enabled ? .teal : .gray, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destination.name).font(.headline).lineLimit(1)
                        Text(destination.endpoint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Toggle("启用此接收端", isOn: Binding(get: { destination.enabled }, set: changeEnabled))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HStack(spacing: 8) {
                    StatusChip(text: presented.label, symbol: presented.symbol, tone: presented.tone)
                        .symbolEffect(.pulse, options: .repeating, isActive: presented.inFlight)
                    if let date = status?.lastAcknowledgedAt {
                        Text("最近确认 \(date.formatted(date: .omitted, time: .standard))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let detail = presented.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(presented.tone == .attention ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let probeResult {
                    Label(probeResult, systemImage: "stethoscope")
                        .font(.callout)
                        .textSelection(.enabled)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Divider()
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
                        Label(probing ? "检查中…" : "检查连接", systemImage: "stethoscope")
                    }
                    .secondaryAction()
                    .disabled(probing)
                    if destination.enabled {
                        Button { model.reconnect(destination.id) } label: {
                            Label("重新连接", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .secondaryAction()
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Button("重新配置…", systemImage: "slider.horizontal.3", action: edit)
                        Button("移除…", systemImage: "trash", role: .destructive, action: remove)
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(16)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconBadge(symbol: "antenna.radiowaves.left.and.right", tint: .teal, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "添加接收端" : "重新配置接收端").font(.title3.weight(.semibold))
                    Text("凭证仅存入 Keychain。").font(.callout).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("本地名称", text: $name, prompt: Text("例如：个人博客"))
                TextField("完整 WSS 地址", text: $endpoint, prompt: Text("wss://receiver.example/api/v1/ingest"))
                    .autocorrectionDisabled()
                SecureField("设备上报凭证", text: $token)
                    .autocorrectionDisabled()
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Footnote("保存后保持未启用；地址或身份变化不会自动迁移已有分享许可。替换时会关闭旧连接并删除旧凭证。")
            if let result {
                Label(result, systemImage: "stethoscope").font(.callout).textSelection(.enabled)
            }
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
        .padding(24).frame(width: 540)
        .interactiveDismissDisabled(probing)
        .onAppear {
            name = existing?.name ?? ""
            endpoint = existing?.endpoint ?? ""
        }
    }
}
