import AppKit
import NowbeamCore
import SwiftUI

@MainActor
struct ReceiverView: View {
    @ObservedObject var model: AppModel
    @StateObject private var administration: ReceiverAdministration
    @State private var selectedID: UUID?
    @State private var connecting = false
    @State private var confirmPublic = false
    @State private var confirmRemoval = false
    @State private var revoking: ReceiverDevice?
    @State private var deviceName = "此设备"

    init(model: AppModel) {
        self.model = model
        _administration = StateObject(wrappedValue: ReceiverAdministration(app: model))
    }

    var body: some View {
        PageScaffold("接收服务管理",
                     subtitle: "仅用于可选的 Nowbeam 独立接收服务。第三方接收端的账号、凭证和公开策略由对方管理，不需要连接这里。") {
            if let receiver = administration.receiver {
                ServiceCard(model: model, administration: administration, receiver: receiver,
                            selectedID: $selectedID, confirmRemoval: $confirmRemoval)
                if administration.loaded {
                    PublicReadCard(administration: administration, confirmPublic: $confirmPublic)
                    DevicesCard(administration: administration, deviceName: $deviceName, revoking: $revoking)
                }
            } else {
                EmptyService(connect: { connecting = true })
            }
        }
        .toolbar {
            if !model.configuration.managedReceivers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { connecting = true } label: { Label("连接服务…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = model.configuration.managedReceivers.first?.id }
        }
        .task(id: selectedID) { await administration.select(selectedID) }
        .sheet(isPresented: $connecting) {
            ReceiverConnectSheet(model: model) { receiver in selectedID = receiver.id }
        }
        .alert("允许任何人读取当前状态？", isPresented: $confirmPublic) {
            Button("开启匿名读取", role: .destructive) { Task { await administration.saveSettings() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("客户端分享与匿名公开是两项独立授权。开启后，访问者不需要凭证；CORS 不能阻止第三方保存副本。")
        }
        .alert("撤销设备授权？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), presenting: revoking) { device in
            Button("撤销", role: .destructive) { Task { await administration.revoke(device) }; revoking = nil }
            Button("取消", role: .cancel) { revoking = nil }
        } message: { device in
            Text("\(device.displayName) 的所有连接会关闭、公开活动会清除，原凭证不再有效。恢复使用需要重新授权。")
        }
        .alert("移除本机管理连接？", isPresented: $confirmRemoval) {
            Button("移除", role: .destructive) {
                if let receiver = administration.receiver { model.removeReceiver(receiver) }
                selectedID = model.configuration.managedReceivers.first { $0.id != selectedID }?.id
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除本机保存的管理凭证，不删除服务器或撤销设备。请先确认已安全备份管理凭证；初始化令牌不能再次用于登录。")
        }
    }
}

// MARK: - 空状态

private struct EmptyService: View {
    let connect: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 14) {
                IconBadge(symbol: "server.rack", tint: .gray, size: 52)
                VStack(spacing: 6) {
                    Text("还没有连接接收服务").font(.title3.weight(.semibold))
                    Text("输入服务地址，以及部署时的初始化令牌或已有的所有者管理凭证。普通上报凭证不能用在这里。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
                Button("连接服务…", systemImage: "link", action: connect)
                    .prominentAction()
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - 管理连接

@MainActor
private struct ServiceCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var administration: ReceiverAdministration
    let receiver: ManagedReceiver
    @Binding var selectedID: UUID?
    @Binding var confirmRemoval: Bool

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconBadge(symbol: "server.rack", tint: .gray, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    if model.configuration.managedReceivers.count > 1 {
                        Picker("接收服务", selection: $selectedID) {
                            ForEach(model.configuration.managedReceivers) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Text(receiver.name).font(.headline).lineLimit(1)
                    }
                    Text(receiver.baseURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if administration.busy { ProgressView().controlSize(.small) }
                Button { Task { await administration.select(receiver.id) } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .secondaryAction()
                .disabled(administration.busy)
                Menu {
                    Button("复制管理凭证", systemImage: "doc.on.doc") { administration.copyOwnerCredential() }
                    Button("移除本机管理连接…", systemImage: "trash", role: .destructive) { confirmRemoval = true }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(administration.busy)
            }
            .padding(16)
            if let notice = administration.notice {
                Divider()
                Label(notice, systemImage: "bubble.left.fill")
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: administration.notice)
    }
}

// MARK: - 公开读取

@MainActor
private struct PublicReadCard: View {
    @ObservedObject var administration: ReceiverAdministration
    @Binding var confirmPublic: Bool

    private var dirty: Bool { administration.settings != administration.savedSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("公开读取")
            Card(tint: administration.settings.publicReadEnabled ? .orange : nil) {
                HStack(spacing: 12) {
                    IconBadge(symbol: "globe", tint: administration.settings.publicReadEnabled ? .orange : .blue, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允许匿名读取当前状态").font(.headline)
                        Text(administration.settings.publicReadEnabled
                             ? "已开启：任何能访问 API 的人都可能读取所有获准设备的当前状态。"
                             : "关闭时仅所有者可读取。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("允许匿名读取当前状态", isOn: $administration.settings.publicReadEnabled)
                        .labelsHidden().toggleStyle(.switch)
                }
                .padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("允许的浏览器 Origin").font(.subheadline.weight(.semibold))
                    TextField("每行一个，例如 https://blog.example", text: origins, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                        .autocorrectionDisabled()
                    Footnote("CORS 只是浏览器跨域规则，不是身份验证。留空不会禁止无 Origin 的客户端读取。")
                }
                .padding(16)
                Divider()
                HStack {
                    if dirty { Label("有未保存的更改", systemImage: "circle.fill").font(.subheadline).foregroundStyle(.orange) }
                    Spacer()
                    Button("保存公开设置") {
                        if administration.settings.publicReadEnabled && !administration.savedSettings.publicReadEnabled {
                            confirmPublic = true
                        } else { Task { await administration.saveSettings() } }
                    }
                    .prominentAction()
                    .disabled(!dirty)
                }
                .padding(16)
            }
        }
        .disabled(administration.busy)
    }

    private var origins: Binding<String> {
        Binding(get: { administration.settings.allowedOrigins.joined(separator: "\n") }, set: { value in
            administration.settings.allowedOrigins = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        })
    }
}

// MARK: - 授权设备

@MainActor
private struct DevicesCard: View {
    @ObservedObject var administration: ReceiverAdministration
    @Binding var deviceName: String
    @Binding var revoking: ReceiverDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("授权设备", caption: "设备名由你填写，不自动使用主机名或硬件标识。设备凭证只用于上报，不能管理实例。")
            Card {
                HStack(spacing: 10) {
                    TextField("公开设备名称", text: $deviceName)
                        .textFieldStyle(.roundedBorder)
                    Button("签发设备凭证") { Task { await administration.createDevice(name: deviceName) } }
                        .prominentAction()
                        .disabled(deviceName.isEmpty || administration.issued != nil)
                }
                .padding(16)
                if let issued = administration.issued {
                    Divider()
                    IssuedDeviceNotice(issued: issued, administration: administration)
                        .padding(16)
                        .transition(.opacity)
                }
                Divider()
                if administration.devices.isEmpty {
                    Text("尚未授权设备；签发凭证不会自动分享任何活动。")
                        .font(.callout).foregroundStyle(.secondary)
                        .cardRow()
                } else {
                    ForEach(Array(administration.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { CardDivider() }
                        DeviceRow(device: device, revoke: { revoking = device })
                    }
                }
            }
            .animation(.snappy(duration: 0.3), value: administration.devices.map(\.id))
            .animation(.snappy(duration: 0.3), value: administration.issued != nil)
        }
        .disabled(administration.busy)
    }
}

@MainActor
private struct IssuedDeviceNotice: View {
    let issued: CreatedDevice
    @ObservedObject var administration: ReceiverAdministration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("已为“\(issued.device.displayName)”签发凭证", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
            SecureField("一次性返回的设备凭证", text: .constant(issued.token))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button { administration.copyIssuedCredential() } label: {
                    Label("复制设备凭证", systemImage: "doc.on.doc")
                }
                .secondaryAction()
                Button { administration.addIssuedToThisMac() } label: {
                    Label("添加到本机接收端，暂不启用", systemImage: "plus.viewfinder")
                }
                .secondaryAction()
            }
            Footnote("此凭证只显示这一次，离开本页或刷新后无法再次查看。为其他设备签发时，请先安全传递。", symbol: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(14)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@MainActor
private struct DeviceRow: View {
    let device: ReceiverDevice
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: "laptopcomputer", tint: .teal, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                Text(device.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("撤销…", role: .destructive, action: revoke).secondaryAction()
        }
        .cardRow()
    }
}

// MARK: - 连接服务

@MainActor
private struct ReceiverConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let connected: (ManagedReceiver) -> Void
    @State private var name = ""
    @State private var baseURL = ""
    @State private var token = ""
    @State private var initialize = false
    @State private var busy = false
    @State private var notice: String?
    @State private var unsavedOwner: String?
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                IconBadge(symbol: "server.rack", tint: .gray, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接 Nowbeam 接收服务").font(.title3.weight(.semibold))
                    Text("首次初始化只可执行一次，会返回独立的所有者管理凭证。").font(.callout).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField("本地名称", text: $name, prompt: Text("例如：家里的服务器"))
                TextField("服务地址", text: $baseURL, prompt: Text("https://receiver.example"))
                    .autocorrectionDisabled()
                Toggle("这是尚未初始化的新实例", isOn: $initialize)
                SecureField(initialize ? "部署时配置的初始化令牌" : "所有者管理凭证", text: $token)
                    .autocorrectionDisabled()
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(busy || unsavedOwner != nil)
            Footnote("初始化不会开放匿名读取，也不会自动创建设备或开始分享。")
            if let notice { Label(notice, systemImage: "bubble.left.fill").font(.callout).textSelection(.enabled) }
            if let unsavedOwner {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("尚未成功保存的管理凭证", text: .constant(unsavedOwner))
                        .textFieldStyle(.roundedBorder)
                    Button("复制并安全备份管理凭证") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(unsavedOwner, forType: .string)
                    }
                    .secondaryAction()
                    Footnote("初始化已完成，但本机保存失败。请先备份，不能再用初始化令牌登录。剪贴板可能被其他应用读取。",
                             symbol: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(14)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) {
                    if unsavedOwner != nil { confirmDiscard = true } else { dismiss() }
                }
                .disabled(busy).keyboardShortcut(.cancelAction)
                Button(initialize ? "初始化并保存" : "验证并保存") {
                    busy = true
                    notice = nil
                    Task { await connect() }
                }
                .prominentAction().keyboardShortcut(.defaultAction)
                .disabled(busy || name.isEmpty || baseURL.isEmpty || token.isEmpty)
            }
        }
        .padding(24).frame(width: 540)
        .interactiveDismissDisabled(busy || unsavedOwner != nil)
        .alert("关闭尚未保存的凭证？", isPresented: $confirmDiscard) {
            Button("已安全备份，关闭", role: .destructive) { dismiss() }
            Button("返回备份", role: .cancel) {}
        } message: {
            Text("管理凭证只返回一次。未保存又没有备份时，你将失去这个实例的管理权限。")
        }
    }

    private func connect() async {
        defer { busy = false }
        do {
            var owner = unsavedOwner ?? token
            let client = try ReceiverManagementClient(baseURL: baseURL, token: owner, allowLoopback: model.allowLoopback)
            if initialize && unsavedOwner == nil {
                owner = try await client.bootstrap()
                unsavedOwner = owner
                initialize = false
                token = owner
            } else {
                _ = try await client.settings()
            }
            let receiver = try model.saveReceiver(name: name, baseURL: baseURL, token: owner)
            unsavedOwner = nil
            connected(receiver)
            dismiss()
        } catch { notice = model.safeMessage(error) }
    }
}
