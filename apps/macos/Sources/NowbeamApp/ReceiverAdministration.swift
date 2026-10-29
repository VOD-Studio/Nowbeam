import AppKit
import Combine
import Foundation
import NowbeamCore

@MainActor
final class ReceiverAdministration: ObservableObject {
    @Published private(set) var receiver: ManagedReceiver?
    @Published private(set) var devices: [ReceiverDevice] = []
    @Published private(set) var issued: CreatedDevice?
    @Published private(set) var busy = false
    @Published private(set) var loaded = false
    @Published var settings = ReceiverSettings(publicReadEnabled: false, allowedOrigins: [])
    @Published var notice: String?
    private(set) var savedSettings = ReceiverSettings(publicReadEnabled: false, allowedOrigins: [])
    private let app: AppModel
    private var generation = UUID()

    init(app: AppModel) { self.app = app }

    func select(_ id: UUID?) async {
        generation = UUID()
        let expected = generation
        receiver = app.configuration.managedReceivers.first { $0.id == id }
        devices = []
        issued = nil
        loaded = false
        notice = nil
        guard let receiver else { busy = false; return }
        busy = true
        defer { if generation == expected { busy = false } }
        do {
            let client = try app.receiverClient(receiver)
            async let currentSettings = client.settings()
            async let currentDevices = client.devices()
            let result = try await (currentSettings, currentDevices)
            guard generation == expected, !Task.isCancelled else { return }
            settings = result.0
            savedSettings = result.0
            devices = result.1
            loaded = true
        } catch {
            if generation == expected, !Task.isCancelled { notice = app.safeMessage(error) }
        }
    }

    private func execute<Result: Sendable>(
        _ operation: @escaping @Sendable (ReceiverManagementClient) async throws -> Result,
        apply: @MainActor (Result) -> Void
    ) async {
        guard !busy, let receiver else { return }
        let expected = generation
        busy = true
        notice = nil
        defer { if generation == expected { busy = false } }
        do {
            let client = try app.receiverClient(receiver)
            let result = try await operation(client)
            guard expected == generation, !Task.isCancelled else { return }
            apply(result)
        } catch {
            if expected == generation { notice = app.safeMessage(error) }
        }
    }

    func saveSettings() async {
        let next = settings
        await execute({ client in
            try await client.updateSettings(next)
            return try await client.settings()
        }, apply: { saved in
            self.settings = saved
            self.savedSettings = saved
            self.notice = saved.publicReadEnabled ? "匿名读取已启用；能访问入口的人均可读取当前状态。" : "匿名读取已关闭。"
        })
    }

    func createDevice(name: String) async {
        await execute({ client in try await client.createDevice(displayName: name) }, apply: { device in
            self.issued = device
            self.devices.append(device.device)
            self.notice = "设备已授权。凭证仅返回一次；尚未添加到接收端，也没有启用分享。"
        })
    }

    func revoke(_ device: ReceiverDevice) async {
        await execute({ client in
            try await client.revokeDevice(id: device.id)
            return device.id
        }, apply: { id in
            self.devices.removeAll { $0.id == id }
            if self.issued?.device.id == id { self.issued = nil }
            self.notice = "设备授权已撤销，服务器已清除其公开活动。"
        })
    }

    func addIssuedToThisMac() {
        guard let issued, let receiver else { return }
        if app.addIssuedDestination(issued, receiver: receiver) {
            self.issued = nil
            notice = "已添加到本机接收端，仍未启用。请到“接收端”明确启用。"
        }
    }

    func copyOwnerCredential() {
        guard let receiver else { return }
        do {
            copyCredential(try app.ownerCredential(receiver))
        } catch { notice = app.safeMessage(error) }
    }

    func copyIssuedCredential() {
        guard let issued else { return }
        copyCredential(issued.token)
    }

    private func copyCredential(_ token: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        notice = "凭证已复制。剪贴板可能被其他应用读取；请存入密码管理器后及时清空。"
    }
}
