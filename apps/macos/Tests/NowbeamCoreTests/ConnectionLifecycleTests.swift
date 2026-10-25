import Foundation
import Network
import Testing
@testable import NowbeamCore

#if DEBUG
struct ConnectionLifecycleTests {
    @Test func slowCollectionDoesNotConsumeTheAcknowledgementWindow() async throws {
        let receiver = try LoopbackReceiver(acknowledgementDelay: .milliseconds(1_500))
        await receiver.start()
        let ready = await eventually { await receiver.endpoint != nil }
        #expect(ready)
        guard let endpoint = await receiver.endpoint else { await receiver.stop(); return }
        let statuses = StatusDeliveryGate()
        let connection = DestinationConnection(
            destination: Destination(name: "期限回归", endpoint: endpoint),
            token: "synthetic-transport-test-token", allowLoopback: true,
            snapshot: {
                try? await Task.sleep(for: .seconds(4))
                return .empty
            },
            status: { await statuses.receive($0) }
        )
        await connection.start()
        let confirmed = await eventually(timeout: .seconds(7)) { await statuses.lastPhase == .confirmed }
        #expect(confirmed)
        #expect(await receiver.connectionCount == 1)
        #expect(await receiver.sequences == [1])
        await connection.stop(clear: false)
        await receiver.stop()
    }

    @Test func suspendedOldStatusCannotOverwriteStopped() async throws {
        let receiver = try LoopbackReceiver()
        await receiver.start()
        let ready = await eventually { await receiver.endpoint != nil }
        #expect(ready)
        guard let endpoint = await receiver.endpoint else { await receiver.stop(); return }
        let statuses = StatusDeliveryGate(holdFirstConfirmation: true)
        let connection = DestinationConnection(
            destination: Destination(name: "状态串行回归", endpoint: endpoint),
            token: "synthetic-transport-test-token", allowLoopback: true,
            snapshot: { .empty }, status: { await statuses.receive($0) }
        )
        await connection.start()
        let held = await eventually { await statuses.isHolding }
        #expect(held)
        await connection.stop(clear: false)
        // 给错误实现独立启动的 stopped 回调执行机会，但不要求新状态越过旧回调。
        try? await Task.sleep(for: .milliseconds(100))
        await statuses.release()
        let stopped = await eventually { await statuses.isStoppedAndIdle }
        #expect(stopped)
        #expect(await statuses.maximumConcurrentCallbacks == 1)
        #expect(await statuses.lastPhase == .stopped)
        await receiver.stop()
    }

    @Test func privacyReconnectDiscardsCancelledCollectionAndDoesNotMultiplyCollectors() async throws {
        let receiver = try LoopbackReceiver()
        await receiver.start()
        let ready = await eventually { await receiver.endpoint != nil }
        #expect(ready)
        guard let endpoint = await receiver.endpoint else { await receiver.stop(); return }
        let collector = CollectionGate()
        let statuses = StatusDeliveryGate()
        let connection = DestinationConnection(
            destination: Destination(name: "来源清除回归", endpoint: endpoint),
            token: "synthetic-transport-test-token", allowLoopback: true,
            snapshot: { await collector.collect() }, status: { await statuses.receive($0) }
        )
        await connection.start()
        let held = await eventually { await collector.calls == 1 }
        #expect(held)
        await connection.requestUpdate(forceReconnect: true)
        let reconnected = await eventually { await receiver.connectionCount == 2 }
        #expect(reconnected)
        for _ in 0..<20 { await connection.requestUpdate() }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await collector.calls == 1)
        await collector.release()
        let confirmed = await eventually { await statuses.lastPhase == .confirmed }
        #expect(confirmed)
        #expect(await collector.maximumConcurrentCalls == 1)
        #expect(await receiver.sequences == [1])
        #expect(await receiver.onlyEmptySources)
        await connection.stop(clear: false)
        await receiver.stop()
    }

    @Test func expiredCollectionClosesConnectionWithoutSendingItsLateResult() async throws {
        let receiver = try LoopbackReceiver()
        await receiver.start()
        let ready = await eventually { await receiver.endpoint != nil }
        #expect(ready)
        guard let endpoint = await receiver.endpoint else { await receiver.stop(); return }
        let collector = CollectionGate(holdDuration: .seconds(8))
        let statuses = StatusDeliveryGate()
        let connection = DestinationConnection(
            destination: Destination(name: "采集期限回归", endpoint: endpoint),
            token: "synthetic-transport-test-token", allowLoopback: true,
            snapshot: { await collector.collect() }, status: { await statuses.receive($0) }
        )
        await connection.start()
        let timedOut = await eventually(timeout: .seconds(6)) { await statuses.lastPhase == .retrying }
        #expect(timedOut)
        #expect(await receiver.sequences.isEmpty)
        await connection.stop(clear: false)
        await collector.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await receiver.sequences.isEmpty)
        #expect(await collector.maximumConcurrentCalls == 1)
        await receiver.stop()
    }

    @Test func missingAcknowledgementStillTimesOutFiveSecondsAfterSubmission() async throws {
        let receiver = try LoopbackReceiver(acknowledgementDelay: .seconds(7))
        await receiver.start()
        let ready = await eventually { await receiver.endpoint != nil }
        #expect(ready)
        guard let endpoint = await receiver.endpoint else { await receiver.stop(); return }
        let statuses = StatusDeliveryGate()
        let connection = DestinationConnection(
            destination: Destination(name: "确认期限回归", endpoint: endpoint),
            token: "synthetic-transport-test-token", allowLoopback: true,
            snapshot: { .empty }, status: { await statuses.receive($0) }
        )
        await connection.start()
        let timedOut = await eventually(timeout: .seconds(6)) { await statuses.lastPhase == .retrying }
        #expect(timedOut)
        #expect(await receiver.sequences == [1])
        await connection.stop(clear: false)
        await receiver.stop()
    }

    @Test func ordinaryUpdatesCoalesceWhileOneSnapshotAwaitsAcknowledgement() async throws {
        let receiver = try LoopbackReceiver(acknowledgementDelay: .milliseconds(500))
        await receiver.start()
        let ready = await eventually { await receiver.endpoint != nil }
        #expect(ready)
        guard let endpoint = await receiver.endpoint else { await receiver.stop(); return }
        let counter = SnapshotCounter()
        let connection = DestinationConnection(
            destination: Destination(name: "单在途回归", endpoint: endpoint),
            token: "synthetic-transport-test-token", allowLoopback: true,
            snapshot: { await counter.collect() }, status: { _ in }
        )
        await connection.start()
        let firstSent = await eventually { await receiver.sequences == [1] }
        #expect(firstSent)
        for _ in 0..<20 { await connection.requestUpdate() }
        #expect(await counter.calls == 1)
        let latestSent = await eventually { await receiver.sequences == [1, 2] }
        #expect(latestSent)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(await counter.calls == 2)
        #expect(await receiver.sequences == [1, 2])
        await connection.stop(clear: false)
        await receiver.stop()
    }
}

private func eventually(timeout: Duration = .seconds(3), _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private actor StatusDeliveryGate {
    private let holdFirstConfirmation: Bool
    private var released = false
    private var didHold = false
    private(set) var isHolding = false
    private(set) var activeCallbacks = 0
    private(set) var maximumConcurrentCallbacks = 0
    private(set) var lastPhase: ConnectionStatus.Phase?
    var isStoppedAndIdle: Bool { lastPhase == .stopped && activeCallbacks == 0 }

    init(holdFirstConfirmation: Bool = false) { self.holdFirstConfirmation = holdFirstConfirmation }

    func receive(_ value: ConnectionStatus) async {
        activeCallbacks += 1
        maximumConcurrentCallbacks = max(maximumConcurrentCallbacks, activeCallbacks)
        if holdFirstConfirmation, value.phase == .confirmed, !didHold {
            didHold = true
            isHolding = true
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !released, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            isHolding = false
        }
        lastPhase = value.phase
        activeCallbacks -= 1
    }

    func release() { released = true }
}

private actor SnapshotCounter {
    private(set) var calls = 0
    func collect() -> Sources {
        calls += 1
        return .empty
    }
}

private actor CollectionGate {
    private let holdDuration: Duration
    private var released = false
    private var activeCalls = 0
    private(set) var calls = 0
    private(set) var maximumConcurrentCalls = 0

    init(holdDuration: Duration = .seconds(3)) { self.holdDuration = holdDuration }

    func collect() async -> Sources {
        calls += 1
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        let first = calls == 1
        if first {
            let deadline = ContinuousClock.now.advanced(by: holdDuration)
            while !released, ContinuousClock.now < deadline {
                // 独立短任务模拟不响应取消的采集器；gate 自身始终有界。
                await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
            }
        }
        activeCalls -= 1
        return first ? Sources(application: ApplicationPresence(displayName: "不可重放的旧来源"), window: nil, media: nil) : .empty
    }

    func release() { released = true }
}

private actor LoopbackReceiver {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Nowbeam.transport-regression")
    private let acknowledgementDelay: Duration
    private var connections: [NWConnection] = []
    private var acknowledgements: [Task<Void, Never>] = []
    private var stopped = false
    private(set) var endpoint: String?
    private(set) var connectionCount = 0
    private(set) var sequences: [Int64] = []
    private(set) var onlyEmptySources = true

    init(acknowledgementDelay: Duration = .zero) throws {
        self.acknowledgementDelay = acknowledgementDelay
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 65_536
        options.setClientRequestHandler(DispatchQueue(label: "Nowbeam.transport-regression.handshake")) { protocols, _ in
            NWProtocolWebSocket.Response(status: protocols.contains("nowbeam.v1") ? .accept : .reject, subprotocol: "nowbeam.v1")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { Task { await self?.ready() } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: queue)
    }

    private func ready() {
        if !stopped, let port = listener.port { endpoint = "ws://127.0.0.1:\(port.rawValue)/ingest" }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        connections.append(connection)
        connectionCount += 1
        let connectionID = UUID().uuidString.lowercased()
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { Task { await self?.welcome(connection, connectionID: connectionID) } }
        }
        connection.start(queue: queue)
    }

    private func welcome(_ connection: NWConnection, connectionID: String) {
        guard !stopped else { return }
        send(#"{"protocolVersion":1,"type":"welcome","connectionId":"\#(connectionID)","deviceId":"22222222-2222-4222-8222-222222222222","serverTime":"2026-10-25T12:00:00Z","heartbeatIntervalMs":15000,"leaseDurationMs":45000,"maxMessageBytes":65536}"#, to: connection)
        receive(connection, connectionID: connectionID)
    }

    private func receive(_ connection: NWConnection, connectionID: String) {
        guard !stopped else { return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard error == nil, let data else { return }
            Task { await self?.received(data, connection: connection, connectionID: connectionID) }
        }
    }

    private func received(_ data: Data, connection: NWConnection, connectionID: String) {
        guard !stopped,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sequence = object["sequence"] as? NSNumber else { return }
        let number = sequence.int64Value
        sequences.append(number)
        if let sources = object["sources"] as? [String: Any] {
            onlyEmptySources = onlyEmptySources && ["application", "window", "media"].allSatisfy { sources[$0] is NSNull }
        } else { onlyEmptySources = false }
        let delay = acknowledgementDelay
        acknowledgements.append(Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.acknowledge(number, connection: connection, connectionID: connectionID)
        })
        receive(connection, connectionID: connectionID)
    }

    private func acknowledge(_ sequence: Int64, connection: NWConnection, connectionID: String) {
        guard !stopped else { return }
        send(#"{"protocolVersion":1,"type":"ack","connectionId":"\#(connectionID)","sequence":\#(sequence),"receivedAt":"2026-10-25T12:00:00Z","expiresAt":"2026-10-25T12:00:45Z"}"#, to: connection)
    }

    private func send(_ text: String, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nowbeam-test", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    func stop() {
        stopped = true
        acknowledgements.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
        listener.cancel()
        acknowledgements.removeAll()
        connections.removeAll()
    }
}
#endif
