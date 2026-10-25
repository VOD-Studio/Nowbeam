import AppKit
import Combine
import Foundation
import NowbeamCapture
import NowbeamCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var configuration: AppConfiguration
    @Published private(set) var preview = Sources.empty
    @Published private(set) var sessionState = SessionGuard.State.unavailable
    @Published private(set) var windowDiagnostic = "窗口来源已关闭"
    @Published private(set) var mediaDiagnostic = "媒体来源已关闭"
    @Published private(set) var statuses: [UUID: ConnectionStatus] = [:]
    @Published var errorMessage: String?

    private let store = ConfigurationStore()
    private let credentials = KeychainStore(service: (Bundle.main.bundleIdentifier ?? "local.nowbeam.development") + ".credentials")
    private let desktop = DesktopCollector()
    private let media = MediaCollector()
    private let session = SessionGuard()
    private var connections: [UUID: DestinationConnection] = [:]
    private var connectionGenerations: [UUID: UUID] = [:]
    private var sleeping = false
    private var terminating = false
    private var updateTask: Task<Void, Never>?
    private var pendingPrivacyReset = false

    var allowLoopback: Bool {
        #if DEBUG
        configuration.allowLoopbackDevelopment
        #else
        false
        #endif
    }
    var enabledDestinationCount: Int { configuration.destinations.filter(\.enabled).count }
    var confirmedDestinationCount: Int { statuses.values.filter { $0.phase == .confirmed }.count }

    init() {
        do {
            var loaded = try store.load()
            // 每次启动明确恢复分享；磁盘写入失败也不会在下次启动意外恢复旧许可。
            loaded.sharingEnabled = false
            configuration = loaded
        } catch {
            configuration = AppConfiguration()
            errorMessage = ApplicationError.configuration.localizedDescription
        }
        desktop.onChange = { [weak self] in self?.captureChanged() }
        media.onChange = { [weak self] in self?.captureChanged() }
        session.onChange = { [weak self] state in
            guard let self else { return }
            self.sessionState = state
            self.configureCapture()
            self.captureChanged()
            self.notifyConnections(forceReconnect: true)
        }
        session.onSleep = { [weak self] in
            guard let self else { return }
            self.sleeping = true
            self.reconcileConnections()
        }
        session.onWake = { [weak self] in
            guard let self else { return }
            self.sleeping = false
            self.configureCapture()
            self.reconcileConnections()
        }
        desktop.start()
        session.start()
        configureCapture()
        reconcileConnections()
    }

    func currentPreview() -> Sources {
        guard session.state.permitsCapture, !terminating else { return .empty }
        return Sources(application: desktop.application, window: desktop.window, media: media.current)
    }

    private func configureCapture() {
        let suspended = !session.state.permitsCapture || terminating
        desktop.configure(configuration.sources, suspended: suspended)
        media.configure(enabled: configuration.sources.mediaEnabled && !suspended)
    }

    private func captureChanged() {
        let next = currentPreview()
        let changed = preview != next
        let tightened = (preview.application != nil && next.application == nil)
            || (preview.window != nil && next.window == nil) || (preview.media != nil && next.media == nil)
        preview = next
        windowDiagnostic = desktop.windowDiagnostic
        mediaDiagnostic = configuration.sources.mediaEnabled && (!session.state.permitsCapture || terminating)
            ? "系统暂停采集" : media.diagnostic
        if changed && configuration.sharingEnabled { notifyConnections(forceReconnect: tightened) }
    }

    private func snapshot(for id: UUID, generation: UUID) async -> Sources {
        session.refresh()
        guard connectionGenerations[id] == generation, configuration.sharingEnabled,
              session.state.permitsCapture, !sleeping, !terminating else { return .empty }
        desktop.refresh()
        let currentMedia = await media.freshValue()
        // 异步采集期间可能已锁屏、禁用目的地或更改规则，必须再次检查。
        session.refresh()
        guard connectionGenerations[id] == generation, configuration.sharingEnabled,
              session.state.permitsCapture, !sleeping, !terminating else { return .empty }
        desktop.refresh()
        return Sources(application: desktop.application, window: desktop.window, media: configuration.sources.mediaEnabled ? currentMedia : nil)
    }

    private func notifyConnections(forceReconnect: Bool) {
        guard !terminating else { return }
        pendingPrivacyReset = pendingPrivacyReset || forceReconnect
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            await Task.yield()
            guard let self, !self.terminating, !Task.isCancelled else { return }
            let reset = self.pendingPrivacyReset
            self.pendingPrivacyReset = false
            self.updateTask = nil
            for connection in self.connections.values {
                await connection.requestUpdate(forceReconnect: reset)
            }
        }
    }

    private func reconcileConnections() {
        let desired = Set(configuration.destinations.filter { $0.enabled && !sleeping && !terminating }.map(\.id))
        for id in Array(connections.keys) where !desired.contains(id) {
            let removed = connections.removeValue(forKey: id)
            connectionGenerations.removeValue(forKey: id)
            statuses[id] = ConnectionStatus(phase: .stopped, message: "已停止；离线撤回由 45 秒租约兜底。")
            if let removed { Task { await removed.stop() } }
        }
        for destination in configuration.destinations where desired.contains(destination.id) && connections[destination.id] == nil {
            do {
                guard let token = try credentials.load(account: destination.credentialAccount) else { throw ApplicationError.missingCredential }
                let id = destination.id
                let generation = UUID()
                connectionGenerations[id] = generation
                let connection = DestinationConnection(
                    destination: destination, token: token, allowLoopback: allowLoopback,
                    snapshot: { [weak self] in await self?.snapshot(for: id, generation: generation) ?? .empty },
                    status: { [weak self] status in
                        await MainActor.run {
                            guard let self, self.connectionGenerations[id] == generation else { return }
                            self.statuses[id] = status
                        }
                    }
                )
                connections[id] = connection
                Task { [weak self] in
                    guard self?.connectionGenerations[id] == generation else { return }
                    await connection.start()
                    if self?.connectionGenerations[id] != generation { await connection.stop() }
                }
            } catch {
                statuses[destination.id] = ConnectionStatus(phase: .blocked, message: safeMessage(error))
            }
        }
    }

    @discardableResult
    private func commit(_ next: AppConfiguration, privacyCritical: Bool = true, resetConnections: Bool = false) -> Bool {
        let saved: Bool
        do {
            try store.save(next)
            configuration = next
            saved = true
        } catch {
            if privacyCritical { configuration = next }
            configuration.sharingEnabled = false
            errorMessage = "无法保存配置，当前分享已暂停。隐私收紧立即生效；下次启动仍需手动恢复分享。"
            saved = false
        }
        configureCapture()
        captureChanged()
        reconcileConnections()
        if resetConnections || !saved { notifyConnections(forceReconnect: true) }
        return saved
    }

    func setSharing(_ enabled: Bool) {
        var next = configuration
        next.sharingEnabled = enabled
        commit(next, resetConnections: true)
    }

    func updateSources(_ change: (inout SourcePreferences) -> Void) {
        var next = configuration
        change(&next.sources)
        commit(next, resetConnections: true)
    }

    func requestAccessibility() { desktop.requestAccessibility() }

    func addApplicationRule(windowAllowed: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = windowAllowed ? "允许读取窗口" : "隐藏此应用"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK else { return }
                guard let url = panel.url, let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
                    self.report(ApplicationError.invalidApplication)
                    return
                }
                self.updateSources { preferences in
                    if windowAllowed { preferences.allowedWindowApplications.insert(identifier) }
                    else { preferences.hiddenApplications.insert(identifier) }
                }
            }
        }
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func applicationLabel(_ identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        return FileManager.default.displayName(atPath: url.path)
    }

    func setDestinationEnabled(_ id: UUID, enabled: Bool) {
        var next = configuration
        guard let index = next.destinations.firstIndex(where: { $0.id == id }) else { return }
        next.destinations[index].enabled = enabled
        commit(next)
    }

    func saveDestination(replacing existing: Destination?, name: String, endpoint: String, token: String) -> Bool {
        do {
            guard let label = PublicText.clean(name, limit: 128), label == name else { throw ApplicationError.invalidName }
            let url = try EndpointURL.websocket(endpoint, allowLoopback: allowLoopback)
            let destination = Destination(name: label, endpoint: url.absoluteString)
            try credentials.save(token, account: destination.credentialAccount)
            var next = configuration
            if let existing { next.destinations.removeAll { $0.id == existing.id } }
            next.destinations.append(destination)
            guard commit(next, privacyCritical: false) else {
                try? credentials.delete(account: destination.credentialAccount)
                return false
            }
            if let existing { try credentials.delete(account: existing.credentialAccount) }
            return true
        } catch { report(error); return false }
    }

    func removeDestination(_ destination: Destination) {
        var next = configuration
        next.destinations.removeAll { $0.id == destination.id }
        commit(next)
        do { try credentials.delete(account: destination.credentialAccount) } catch { report(error) }
        statuses.removeValue(forKey: destination.id)
    }

    func probeDestination(_ destination: Destination) async throws -> WelcomeMessage {
        guard let token = try credentials.load(account: destination.credentialAccount) else { throw ApplicationError.missingCredential }
        return try await DestinationConnection.probe(endpoint: destination.endpoint, token: token, allowLoopback: allowLoopback)
    }

    func reconnect(_ id: UUID) {
        guard let connection = connections[id], let expected = connectionGenerations[id] else {
            reconcileConnections()
            return
        }
        let blocked = statuses[id]?.phase == .blocked
        Task { [weak self] in
            guard self?.connectionGenerations[id] == expected else { return }
            if blocked { await connection.start() }
            else { await connection.requestUpdate(forceReconnect: true) }
            if self?.connectionGenerations[id] != expected { await connection.stop() }
        }
    }

    func setLoopbackAllowed(_ allowed: Bool) {
        #if DEBUG
        var next = configuration
        next.allowLoopbackDevelopment = allowed
        commit(next)
        // 旧 actor 持有旧的传输策略，不能让关闭开发例外只影响新目标。
        let previous = connections.values
        connections.removeAll()
        connectionGenerations.removeAll()
        for connection in previous { Task { await connection.stop() } }
        reconcileConnections()
        #endif
    }

    func saveReceiver(name: String, baseURL: String, token: String) throws -> ManagedReceiver {
        guard let label = PublicText.clean(name, limit: 128), label == name else { throw ApplicationError.invalidName }
        let url = try EndpointURL.management(baseURL, allowLoopback: allowLoopback)
        let receiver = ManagedReceiver(name: label, baseURL: url.absoluteString)
        try credentials.save(token, account: receiver.credentialAccount)
        var next = configuration
        next.managedReceivers.append(receiver)
        guard commit(next, privacyCritical: false) else {
            try? credentials.delete(account: receiver.credentialAccount)
            throw ApplicationError.configuration
        }
        return receiver
    }

    func receiverClient(_ receiver: ManagedReceiver) throws -> ReceiverManagementClient {
        guard configuration.managedReceivers.contains(where: { $0.id == receiver.id }) else { throw ApplicationError.unavailableReceiver }
        guard let token = try credentials.load(account: receiver.credentialAccount) else { throw ApplicationError.missingCredential }
        return try ReceiverManagementClient(baseURL: receiver.baseURL, token: token, allowLoopback: allowLoopback)
    }

    func ownerCredential(_ receiver: ManagedReceiver) throws -> String {
        guard let token = try credentials.load(account: receiver.credentialAccount) else { throw ApplicationError.missingCredential }
        return token
    }

    func removeReceiver(_ receiver: ManagedReceiver) {
        var next = configuration
        next.managedReceivers.removeAll { $0.id == receiver.id }
        commit(next)
        do { try credentials.delete(account: receiver.credentialAccount) } catch { report(error) }
    }

    func addIssuedDestination(_ created: CreatedDevice, receiver: ManagedReceiver) -> Bool {
        do {
            let base = try EndpointURL.management(receiver.baseURL, allowLoopback: allowLoopback)
            guard var components = URLComponents(url: base.appendingPathComponent("api/v1/ingest"), resolvingAgainstBaseURL: false) else { throw ApplicationError.unavailableReceiver }
            components.scheme = base.scheme == "https" ? "wss" : "ws"
            guard let endpoint = components.url?.absoluteString,
                  let name = PublicText.clean(receiver.name + " · " + created.device.displayName, limit: 128) else {
                throw ApplicationError.unavailableReceiver
            }
            return saveDestination(replacing: nil, name: name, endpoint: endpoint, token: created.token)
        } catch { report(error); return false }
    }

    func safeMessage(_ error: Error) -> String {
        if error is ApplicationError || error is TransportError || error is KeychainError {
            return error.localizedDescription
        }
        return "操作未完成。请检查权限和连接设置后重试；不会自动放宽安全要求。"
    }

    func report(_ error: Error) { errorMessage = safeMessage(error) }

    func shutdown() async {
        terminating = true
        updateTask?.cancel()
        updateTask = nil
        desktop.stop()
        media.stop()
        session.stop()
        preview = .empty
        let previous = Array(connections.values)
        connections.removeAll()
        connectionGenerations.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for connection in previous { group.addTask { await connection.stop() } }
        }
    }
}
