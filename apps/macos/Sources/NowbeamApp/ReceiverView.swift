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
        Form {
            Section {
                Text("仅用于可选的 Nowbeam 独立接收服务。第三方目的地的账号、凭证和公开策略由对方管理，不需要连接这里。")
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("接收服务", selection: $selectedID) {
                        Text("选择一个服务").tag(UUID?.none)
                        ForEach(model.configuration.managedReceivers) { receiver in
                            Text(receiver.name).tag(Optional(receiver.id))
                        }
                    }
                    Button("连接服务…") { connecting = true }
                }
            }
            if let receiver = administration.receiver {
                Section("管理连接") {
                    KeyValueRow(label: "服务地址", value: receiver.baseURL, monospaced: true)
                    if administration.busy { ProgressView("正在与接收服务通信…") }
                    if let notice = administration.notice {
                        Label(notice, systemImage: "bubble.left.and.text.bubble.right")
                            .font(.callout).textSelection(.enabled)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    HStack(spacing: 8) {
                        Button { Task { await administration.select(receiver.id) } } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .glassAction()
                        Button {
                            administration.copyOwnerCredential()
                        } label: {
                            Label("复制管理凭证", systemImage: "doc.on.doc")
                        }
                        .glassAction()
                        Spacer(minLength: 8)
                        Button("移除本机管理连接…", role: .destructive) { confirmRemoval = true }
                    }
                    .disabled(administration.busy)
                }
                .animation(.snappy(duration: 0.25), value: administration.notice)
                if administration.loaded {
                    Section("公开读取") {
                        Toggle("允许匿名读取当前状态", isOn: $administration.settings.publicReadEnabled)
                        Text("关闭时仅所有者可读取。开启后，任何能访问 API 的人均可能读取所有获准设备的当前状态。")
                            .foregroundStyle(.secondary)
                        TextField("允许的浏览器 Origin，每行一个", text: origins, axis: .vertical)
                            .lineLimit(2...5).autocorrectionDisabled()
                        Text("CORS 只是浏览器跨域规则，不是身份验证。留空不会禁止无 Origin 的客户端读取。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("保存公开设置") {
                            if administration.settings.publicReadEnabled && !administration.savedSettings.publicReadEnabled {
                                confirmPublic = true
                            } else { Task { await administration.saveSettings() } }
                        }
                        .prominentAction()
                    }
                    .disabled(administration.busy)
                    Section("授权设备") {
                        HStack(spacing: 8) {
                            TextField("公开设备名称", text: $deviceName)
                            Button("签发设备凭证") { Task { await administration.createDevice(name: deviceName) } }
                                .prominentAction()
                                .disabled(deviceName.isEmpty || administration.issued != nil)
                        }
                        Text("设备名由你填写，不自动使用主机名或硬件标识。设备凭证只用于上报，不能管理实例。")
                            .font(.callout).foregroundStyle(.secondary)
                        if let issued = administration.issued {
                            IssuedDeviceCard(issued: issued, administration: administration)
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                        if administration.devices.isEmpty {
                            Text("尚未授权设备；签发凭证不会自动分享任何活动。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(administration.devices) { device in
                            DeviceRow(device: device, revoke: { revoking = device })
                                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                        .animation(.snappy(duration: 0.3), value: administration.devices.map(\.id))
                    }
                    .disabled(administration.busy)
                    .animation(.snappy(duration: 0.3), value: administration.issued != nil)
                }
            } else {
                Section {
                    ContentUnavailableView("没有选中的管理连接", systemImage: "server.rack", description: Text("输入服务地址，以及部署时的初始化令牌或已有管理凭证。普通上报凭证不能用在这里。"))
                }
            }
        }
        .formStyle(.grouped)
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
                selectedID = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除本机保存的管理凭证，不删除服务器或撤销设备。请先确认已安全备份管理凭证；初始化令牌不能再次用于登录。")
        }
    }

    private var origins: Binding<String> {
        Binding(get: { administration.settings.allowedOrigins.joined(separator: "\n") }, set: { value in
            administration.settings.allowedOrigins = value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        })
    }
}

@MainActor
private struct IssuedDeviceCard: View {
    let issued: CreatedDevice
    @ObservedObject var administration: ReceiverAdministration

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("新授权设备", value: issued.device.displayName)
            SecureField("一次性返回的设备凭证", text: .constant(issued.token))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button {
                    administration.copyIssuedCredential()
                } label: {
                    Label("复制设备凭证", systemImage: "doc.on.doc")
                }
                .glassAction()
                Button {
                    administration.addIssuedToThisMac()
                } label: {
                    Label("添加到本机接收端，暂不启用", systemImage: "plus.viewfinder")
                }
                .prominentAction()
            }
            Label("刷新页面后不会再次显示此凭证。为其他设备签发时，请安全传递后再刷新。", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

@MainActor
private struct DeviceRow: View {
    let device: ReceiverDevice
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer.and.iphone")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                Text(device.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("撤销…", role: .destructive, action: revoke)
        }
    }
}

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
        VStack(alignment: .leading, spacing: 16) {
            Text("连接 Nowbeam 接收服务").font(.title2.weight(.semibold))
            Form {
                TextField("本地名称", text: $name)
                TextField("服务地址", text: $baseURL, prompt: Text("https://receiver.example"))
                    .autocorrectionDisabled()
                Toggle("这是尚未初始化的新实例", isOn: $initialize)
                SecureField(initialize ? "部署时配置的初始化令牌" : "所有者管理凭证", text: $token)
                    .autocorrectionDisabled()
            }
            .disabled(busy || unsavedOwner != nil)
            Text("首次初始化只可执行一次，会返回独立管理凭证。不会开放匿名读取，也不会自动创建设备或开始分享。")
                .font(.callout).foregroundStyle(.secondary)
            if let notice { Text(notice).font(.callout).textSelection(.enabled) }
            if let unsavedOwner {
                SecureField("尚未成功保存的管理凭证", text: .constant(unsavedOwner))
                Button("复制并安全备份管理凭证") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(unsavedOwner, forType: .string)
                }
                Text("初始化已完成，但本机保存失败。请先备份，不能再用初始化令牌登录。剪贴板可能被其他应用读取。")
                    .font(.callout).foregroundStyle(.secondary)
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
        .padding(24).frame(width: 560)
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
