import Foundation

public struct ConnectionStatus: Sendable {
    public enum Phase: Equatable, Sendable { case stopped, connecting, ready, confirmed, retrying, blocked }
    public let phase: Phase
    public let message: String
    public let deviceId: String?
    public let lastAcknowledgedAt: Date?

    public init(phase: Phase, message: String, deviceId: String? = nil, lastAcknowledgedAt: Date? = nil) {
        self.phase = phase
        self.message = message
        self.deviceId = deviceId
        self.lastAcknowledgedAt = lastAcknowledgedAt
    }
}

public actor DestinationConnection {
    private let destination: Destination
    private let token: String
    private let allowLoopback: Bool
    private let snapshot: @Sendable () async -> Sources
    private let status: @Sendable (ConnectionStatus) async -> Void
    private var generation = UUID()
    private var pendingStatus: ConnectionStatus?
    private var statusTask: Task<Void, Never>?
    private var running = false
    private var blocked = false
    private var pending = false
    private var retryAttempt = 0
    private var channel: WebSocketChannel?
    private var welcome: WelcomeMessage?
    private var sequence: Int64 = 0
    private var inFlight: Int64?
    private var awaitingAcknowledgement = false
    private var lastAcknowledgedAt: Date?
    private var receiveTask: Task<Void, Never>?
    private var collectionTask: Task<Void, Never>?
    private var collectionDeadlineTask: Task<Void, Never>?
    private var firstSnapshotDeadlineTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    public init(destination: Destination, token: String, allowLoopback: Bool,
                snapshot: @escaping @Sendable () async -> Sources,
                status: @escaping @Sendable (ConnectionStatus) async -> Void) {
        self.destination = destination
        self.token = token
        self.allowLoopback = allowLoopback
        self.snapshot = snapshot
        self.status = status
    }

    deinit {
        receiveTask?.cancel()
        collectionTask?.cancel()
        collectionDeadlineTask?.cancel()
        firstSnapshotDeadlineTask?.cancel()
        statusTask?.cancel()
        heartbeatTask?.cancel()
        deadlineTask?.cancel()
        retryTask?.cancel()
        channel?.close()
    }

    public func start() async {
        guard !running || blocked else { return }
        running = true
        blocked = false
        retryAttempt = 0
        connect()
    }

    public func requestUpdate(forceReconnect: Bool = false) async {
        guard running, !blocked else { return }
        if forceReconnect {
            // 隐私收紧先撤销旧连接，再重新取投影；绝不等待旧快照确认。
            connect()
        } else {
            pending = true
            sendLatestIfPossible()
        }
    }

    public func stop(clear: Bool = true) async {
        running = false
        blocked = false
        let oldChannel = channel
        let oldWelcome = welcome
        let nextSequence = sequence + 1
        let canWithdraw = clear && inFlight == nil && nextSequence <= ServerMessage.maximumSequence
        invalidate(close: false)
        let stopGeneration = generation
        emit(.stopped, "已停止连接；未能送达的撤回由接收端租约兜底。")
        guard let oldChannel else { return }
        defer { oldChannel.close() }
        guard canWithdraw, let oldWelcome else { return }
        // 退出路径只发空快照，不重新采集，也不与待确认快照并行发送。
        let withdrawal = SnapshotMessage(connectionId: oldWelcome.connectionId, sequence: nextSequence, sources: .empty)
        guard let bytes = try? JSONEncoder().encode(withdrawal), let text = String(data: bytes, encoding: .utf8) else { return }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { oldChannel.close() }
        }
        defer { deadline.cancel() }
        try? await oldChannel.task.send(.string(text))
        if generation == stopGeneration { pending = false }
    }

    public static func probe(endpoint: String, token: String, allowLoopback: Bool) async throws -> WelcomeMessage {
        let channel = try WebSocketChannel(endpoint: endpoint, token: token, allowLoopback: allowLoopback)
        defer { channel.close() }
        do { return try await channel.open() }
        catch { throw TransportError.classify(error, task: channel.task) }
    }

    private func connect() {
        invalidate()
        guard running, !blocked else { return }
        let currentGeneration = generation
        emit(.connecting, "正在验证接收端身份与协议。")
        do {
            let socket = try WebSocketChannel(endpoint: destination.endpoint, token: token, allowLoopback: allowLoopback)
            channel = socket
            receiveTask = Task { [weak self] in
                do {
                    let greeting = try await socket.open()
                    guard await self?.opened(greeting, generation: currentGeneration) == true else { socket.close(); return }
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard let self else { socket.close(); return }
                        await self.received(message, generation: currentGeneration)
                    }
                } catch {
                    await self?.failed(TransportError.classify(error, task: socket.task), generation: currentGeneration)
                }
            }
        } catch {
            failed(TransportError.classify(error), generation: currentGeneration)
        }
    }

    private func opened(_ greeting: WelcomeMessage, generation expected: UUID) -> Bool {
        guard generation == expected, running, !blocked else { return false }
        welcome = greeting
        pending = true
        emit(.ready, "连接已验证，等待接收端确认快照。")
        firstSnapshotDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await self?.firstSnapshotExpired(generation: expected)
        }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await self?.heartbeat(generation: expected)
            }
        }
        sendLatestIfPossible()
        return true
    }

    private func heartbeat(generation expected: UUID) {
        guard generation == expected, running, !blocked else { return }
        pending = true
        sendLatestIfPossible()
    }

    private func sendLatestIfPossible() {
        guard running, !blocked, pending, inFlight == nil, collectionTask == nil,
              let welcome, let channel else { return }
        guard sequence < ServerMessage.maximumSequence else { connect(); return }
        sequence += 1
        let next = sequence
        let expected = generation
        let connectionID = welcome.connectionId
        inFlight = next
        pending = false
        // 采集独立限时；提交发送之后才开始 ACK 的五秒期限。
        collectionDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.collectionExpired(sequence: next, generation: expected)
        }
        let sourceProvider = snapshot
        collectionTask = Task { [weak self] in
            let sources = await sourceProvider()
            await self?.collected(sources, sequence: next, connectionID: connectionID, channel: channel, generation: expected)
        }
    }

    private func collected(_ sources: Sources, sequence next: Int64, connectionID: String,
                           channel socket: WebSocketChannel, generation expected: UUID) async {
        collectionTask = nil
        guard generation == expected else {
            // 不响应取消的旧采集最多保留一个；结束后只重新采集，绝不重发旧结果。
            sendLatestIfPossible()
            return
        }
        await send(sources, sequence: next, connectionID: connectionID, channel: socket, generation: expected)
    }

    private func send(_ sources: Sources, sequence next: Int64, connectionID: String,
                      channel socket: WebSocketChannel, generation expected: UUID) async {
        guard generation == expected, inFlight == next, running, !blocked else { return }
        do {
            try ServerMessage.validate(sources)
            let bytes = try JSONEncoder().encode(SnapshotMessage(connectionId: connectionID, sequence: next, sources: sources))
            guard bytes.count <= 65_536 else { throw TransportError.messageTooLarge }
            guard let text = String(data: bytes, encoding: .utf8) else { throw TransportError.invalidMessage }
            collectionDeadlineTask?.cancel()
            collectionDeadlineTask = nil
            deadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await self?.deadlineExpired(sequence: next, generation: expected)
            }
            awaitingAcknowledgement = true
            emit(.ready, "快照正在发送，尚未获得接收端确认。")
            try await socket.task.send(.string(text))
            if generation == expected {
                firstSnapshotDeadlineTask?.cancel()
                firstSnapshotDeadlineTask = nil
            }
        } catch {
            failed(TransportError.classify(error, task: socket.task), generation: expected)
        }
    }

    private func received(_ message: ServerMessage, generation expected: UUID) {
        guard generation == expected, running, !blocked, let welcome else { return }
        switch message {
        case .welcome:
            failed(.invalidMessage, generation: expected)
        case .ack(let acknowledgement):
            guard awaitingAcknowledgement, acknowledgement.connectionId == welcome.connectionId,
                  acknowledgement.sequence == inFlight else {
                failed(.invalidMessage, generation: expected)
                return
            }
            firstSnapshotDeadlineTask?.cancel()
            firstSnapshotDeadlineTask = nil
            deadlineTask?.cancel()
            deadlineTask = nil
            inFlight = nil
            awaitingAcknowledgement = false
            retryAttempt = 0
            lastAcknowledgedAt = WireTimestamp.date(acknowledgement.receivedAt)
            emit(.confirmed, "接收端已确认当前快照。")
            sendLatestIfPossible()
        case .error(let failure):
            guard failure.connectionId == welcome.connectionId,
                  failure.sequence == nil || failure.sequence == inFlight else {
                failed(.invalidMessage, generation: expected)
                return
            }
            let error: TransportError = switch failure.code {
            case "credential_revoked": .revoked
            case "session_replaced": .replaced
            case "internal_error": .serverUnavailable
            default: .invalidMessage
            }
            failed(error, generation: expected)
        }
    }

    private func firstSnapshotExpired(generation expected: UUID) {
        guard generation == expected, firstSnapshotDeadlineTask != nil else { return }
        failed(.connectionTimeout, generation: expected)
    }

    private func collectionExpired(sequence expectedSequence: Int64, generation expected: UUID) {
        guard generation == expected, inFlight == expectedSequence, !awaitingAcknowledgement else { return }
        failed(.connectionTimeout, generation: expected)
    }

    private func deadlineExpired(sequence expectedSequence: Int64, generation expected: UUID) {
        guard generation == expected, inFlight == expectedSequence, awaitingAcknowledgement else { return }
        failed(.acknowledgementTimeout, generation: expected)
    }

    private func failed(_ error: TransportError, generation expected: UUID) {
        guard generation == expected, running else { return }
        invalidate()
        if !error.permitsRetry {
            blocked = true
            emit(.blocked, error.errorDescription ?? "连接已停止，请检查接收端设置。")
            return
        }
        emit(.retrying, error.errorDescription ?? "连接中断，正在等待重试。")
        let baseDelay = min(30, pow(2, Double(min(retryAttempt, 5))))
        let delay = Double.random(in: max(1, baseDelay * 0.8)...min(30, baseDelay * 1.2))
        retryAttempt = min(retryAttempt + 1, 5)
        let retryGeneration = generation
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retry(generation: retryGeneration)
        }
    }

    private func retry(generation expected: UUID) {
        guard generation == expected, running, !blocked else { return }
        connect()
    }

    private func invalidate(close: Bool = true) {
        generation = UUID()
        receiveTask?.cancel()
        collectionTask?.cancel()
        collectionDeadlineTask?.cancel()
        firstSnapshotDeadlineTask?.cancel()
        heartbeatTask?.cancel()
        deadlineTask?.cancel()
        retryTask?.cancel()
        receiveTask = nil
        // 不丢失仍在执行的采集句柄，避免连续重连积累不响应取消的任务。
        collectionDeadlineTask = nil
        firstSnapshotDeadlineTask = nil
        heartbeatTask = nil
        deadlineTask = nil
        retryTask = nil
        if close { channel?.close() }
        channel = nil
        welcome = nil
        sequence = 0
        inFlight = nil
        awaitingAcknowledgement = false
        pending = false
        lastAcknowledgedAt = nil
        pendingStatus = nil
    }

    private func emit(_ phase: ConnectionStatus.Phase, _ message: String) {
        pendingStatus = ConnectionStatus(phase: phase, message: message, deviceId: welcome?.deviceId, lastAcknowledgedAt: lastAcknowledgedAt)
        guard statusTask == nil else { return }
        let handler = status
        // 一个执行中的回调加一个最新状态槽；跨代次也不允许新回调越过旧回调。
        statusTask = Task { [weak self] in
            while let value = await self?.takeNextStatus() {
                await handler(value)
            }
        }
    }

    private func takeNextStatus() -> ConnectionStatus? {
        guard let value = pendingStatus else {
            statusTask = nil
            return nil
        }
        pendingStatus = nil
        return value
    }
}

private final class WebSocketChannel: Sendable {
    let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate: SessionSecurityDelegate

    init(endpoint: String, token: String, allowLoopback: Bool) throws {
        let url = try EndpointURL.websocket(endpoint, allowLoopback: allowLoopback)
        try validateBearerToken(token)
        delegate = SessionSecurityDelegate()
        let configuration = privateSessionConfiguration()
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("nowbeam.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 65_536
    }

    func open() async throws -> WelcomeMessage {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            delegate.finish(.failure(.connectionTimeout))
            close()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            task.resume()
            try await delegate.waitForOpen()
            guard case .welcome(let greeting) = try await receive() else { throw TransportError.invalidMessage }
            return greeting
        } onCancel: {
            close()
        }
    }

    func receive() async throws -> ServerMessage {
        switch try await task.receive() {
        case .string(let text): return try ServerMessage.decode(text)
        case .data: throw TransportError.invalidMessage
        @unknown default: throw TransportError.invalidMessage
        }
    }

    func close() {
        delegate.finish(.failure(.network))
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

// 服务端 v1 消息全部是扁平对象；在 Codable 解码前拒绝重复键和非法 Unicode 转义。
enum ServerMessage: Sendable {
    case welcome(WelcomeMessage)
    case ack(Acknowledgement)
    case error(ReceiverErrorMessage)
    static let maximumSequence: Int64 = 9_007_199_254_740_991

    static func decode(_ text: String) throws -> ServerMessage {
        guard text.utf8.count <= 65_536 else { throw TransportError.messageTooLarge }
        let data = Data(text.utf8)
        var scanner = FlatObjectScanner(data: data)
        let keys = try scanner.keys()
        let decodingData = scanner.normalizedData ?? data
        let decoder = JSONDecoder()
        struct Kind: Decodable { let type: String; let protocolVersion: Int }
        do {
            let kind = try decoder.decode(Kind.self, from: decodingData)
            guard kind.protocolVersion == 1 else { throw TransportError.protocolMismatch }
            switch kind.type {
            case "welcome":
                guard keys == ["protocolVersion", "type", "connectionId", "deviceId", "serverTime", "heartbeatIntervalMs", "leaseDurationMs", "maxMessageBytes"] else { throw TransportError.invalidMessage }
                let message = try decoder.decode(WelcomeMessage.self, from: decodingData)
                guard message.isValid, WireTimestamp.date(message.serverTime) != nil else { throw TransportError.protocolMismatch }
                return .welcome(message)
            case "ack":
                guard keys == ["protocolVersion", "type", "connectionId", "sequence", "receivedAt", "expiresAt"] else { throw TransportError.invalidMessage }
                let message = try decoder.decode(Acknowledgement.self, from: decodingData)
                guard WireID.isValid(message.connectionId), validSequence(message.sequence),
                      let received = WireTimestamp.date(message.receivedAt), let expires = WireTimestamp.date(message.expiresAt),
                      abs(expires.timeIntervalSince(received) - 45) < 0.0001 else { throw TransportError.invalidMessage }
                return .ack(message)
            case "error":
                guard keys == ["protocolVersion", "type", "connectionId", "sequence", "code"] else { throw TransportError.invalidMessage }
                let message = try decoder.decode(ReceiverErrorMessage.self, from: decodingData)
                guard WireID.isValid(message.connectionId), message.sequence.map(validSequence) ?? true,
                      ["invalid_message", "out_of_order", "sequence_conflict", "credential_revoked", "session_replaced", "internal_error"].contains(message.code) else { throw TransportError.invalidMessage }
                return .error(message)
            default: throw TransportError.invalidMessage
            }
        } catch let error as TransportError { throw error }
        catch { throw TransportError.invalidMessage }
    }

    static func validSequence(_ value: Int64) -> Bool { (1...maximumSequence).contains(value) }

    static func validate(_ sources: Sources) throws {
        func text(_ value: String, limit: Int) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.unicodeScalars.count <= limit
                && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
        }
        if let application = sources.application, !text(application.displayName, limit: 128) { throw TransportError.invalidMessage }
        if let window = sources.window, !text(window.title, limit: 1_024) { throw TransportError.invalidMessage }
        guard let media = sources.media else { return }
        let playback = media.playback
        guard WireID.isValid(media.sessionId), text(media.playerName, limit: 128), text(media.title, limit: 512),
              media.artist.map({ text($0, limit: 512) }) ?? true, media.album.map({ text($0, limit: 512) }) ?? true,
              playback.durationMs.map(validSequence) ?? true,
              playback.positionMs.map({ (0...maximumSequence).contains($0) }) ?? true else { throw TransportError.invalidMessage }
        if let duration = playback.durationMs, let position = playback.positionMs, position > duration { throw TransportError.invalidMessage }
        switch playback.state {
        case .paused:
            guard playback.rate == 0 else { throw TransportError.invalidMessage }
        case .playing:
            if let rate = playback.rate, !rate.isFinite || rate <= 0 || rate > 4 { throw TransportError.invalidMessage }
        }
    }
}

struct FlatObjectScanner {
    let data: Data
    private var offset = 0
    private(set) var normalizedData: Data?
    private var copiedThrough = 0

    init(data: Data) { self.data = data }

    mutating func keys() throws -> Set<String> {
        var result: Set<String> = []
        whitespace()
        try consume(123)
        whitespace()
        if peek == 125 { offset += 1 } else {
            while true {
                let start = offset
                try string()
                let key: String
                do { key = try JSONDecoder().decode(String.self, from: data[start..<offset]) }
                catch { throw TransportError.invalidMessage }
                guard result.insert(key).inserted else { throw TransportError.invalidMessage }
                whitespace()
                try consume(58)
                whitespace()
                if peek == 34 { try string() } else {
                    let start = offset
                    while let byte = peek, byte != 44, byte != 125 {
                        guard byte != 123, byte != 91, byte != 34 else { throw TransportError.invalidMessage }
                        offset += 1
                    }
                    guard offset > start else { throw TransportError.invalidMessage }
                    if ["protocolVersion", "heartbeatIntervalMs", "leaseDurationMs", "maxMessageBytes", "sequence"].contains(key),
                       data[start] == 45 || (48...57).contains(data[start]) {
                        let value = try exactInteger(start..<offset)
                        // 只规范化小数/指数写法，避免旧 Foundation 经 Double 舍入或拒绝合法整数。
                        if data[start..<offset].contains(46) || data[start..<offset].contains(101) || data[start..<offset].contains(69) {
                            if normalizedData == nil {
                                normalizedData = Data()
                                normalizedData?.reserveCapacity(data.count)
                            }
                            normalizedData?.append(data[copiedThrough..<start])
                            normalizedData?.append(contentsOf: String(value).utf8)
                            copiedThrough = offset
                        }
                    }
                }
                whitespace()
                if peek == 125 { offset += 1; break }
                try consume(44)
                whitespace()
            }
        }
        whitespace()
        guard offset == data.count else { throw TransportError.invalidMessage }
        if normalizedData != nil { normalizedData?.append(data[copiedThrough..<data.count]) }
        return result
    }

    private func exactInteger(_ range: Range<Int>) throws -> Int64 {
        var cursor = range.lowerBound
        func byte() -> UInt8? { cursor < range.upperBound ? data[cursor] : nil }
        let negative = byte() == 45
        if negative { cursor += 1 }
        let mantissaStart = cursor
        var digitCount = 0
        var leadingZeros = 0
        var trailingZeros = 0
        func digit(_ value: UInt8) {
            digitCount += 1
            if value == 48 {
                if leadingZeros == digitCount - 1 { leadingZeros += 1 }
                trailingZeros += 1
            } else { trailingZeros = 0 }
        }
        guard let first = byte(), (48...57).contains(first) else { throw TransportError.invalidMessage }
        digit(first)
        cursor += 1
        if first != 48 {
            while let value = byte(), (48...57).contains(value) {
                digit(value)
                cursor += 1
            }
        }
        var fractionDigits = 0
        if byte() == 46 {
            cursor += 1
            while let value = byte(), (48...57).contains(value) {
                digit(value)
                fractionDigits += 1
                cursor += 1
            }
            guard fractionDigits > 0 else { throw TransportError.invalidMessage }
        }
        let mantissaEnd = cursor
        var exponent = 0
        if byte() == 101 || byte() == 69 {
            cursor += 1
            let exponentNegative = byte() == 45
            if byte() == 43 || exponentNegative { cursor += 1 }
            let exponentStart = cursor
            while let value = byte(), (48...57).contains(value) {
                // 消息总长限制已知；更大的指数不可能抵消尾数，饱和即可避免溢出。
                exponent = min(data.count + 17, exponent * 10 + Int(value - 48))
                cursor += 1
            }
            guard cursor > exponentStart else { throw TransportError.invalidMessage }
            if exponentNegative { exponent = -exponent }
        }
        while let value = byte(), [UInt8(32), 9, 10, 13].contains(value) { cursor += 1 }
        guard cursor == range.upperBound else { throw TransportError.invalidMessage }
        if leadingZeros == digitCount { return 0 }
        let significantDigits = digitCount - leadingZeros - trailingZeros
        let zeroSuffix = trailingZeros + exponent - fractionDigits
        guard zeroSuffix >= 0, significantDigits + zeroSuffix <= 16 else { throw TransportError.invalidMessage }
        var value: Int64 = 0
        var digitIndex = 0
        for index in mantissaStart..<mantissaEnd where data[index] != 46 {
            if digitIndex >= leadingZeros, digitIndex < digitCount - trailingZeros {
                value = value * 10 + Int64(data[index] - 48)
            }
            digitIndex += 1
        }
        for _ in 0..<zeroSuffix { value *= 10 }
        guard value <= ServerMessage.maximumSequence else { throw TransportError.invalidMessage }
        return negative ? -value : value
    }

    private var peek: UInt8? { offset < data.count ? data[offset] : nil }

    private mutating func whitespace() {
        while let byte = peek, byte == 32 || byte == 9 || byte == 10 || byte == 13 { offset += 1 }
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard peek == expected else { throw TransportError.invalidMessage }
        offset += 1
    }

    private mutating func string() throws {
        try consume(34)
        while let byte = peek {
            offset += 1
            if byte == 34 { return }
            guard byte >= 32 else { throw TransportError.invalidMessage }
            if byte != 92 { continue }
            guard let escaped = peek else { throw TransportError.invalidMessage }
            offset += 1
            if escaped == 117 {
                let scalar = try hexadecimal()
                if (0xD800...0xDBFF).contains(scalar) {
                    try consume(92)
                    try consume(117)
                    guard (0xDC00...0xDFFF).contains(try hexadecimal()) else { throw TransportError.invalidMessage }
                } else if (0xDC00...0xDFFF).contains(scalar) { throw TransportError.invalidMessage }
            } else if ![34, 92, 47, 98, 102, 110, 114, 116].contains(escaped) { throw TransportError.invalidMessage }
        }
        throw TransportError.invalidMessage
    }

    private mutating func hexadecimal() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = peek else { throw TransportError.invalidMessage }
            let digit: UInt16
            switch byte {
            case 48...57: digit = UInt16(byte - 48)
            case 65...70: digit = UInt16(byte - 55)
            case 97...102: digit = UInt16(byte - 87)
            default: throw TransportError.invalidMessage
            }
            value = value * 16 + digit
            offset += 1
        }
        return value
    }
}

enum WireTimestamp {
    static func date(_ value: String) -> Date? {
        let bytes = value.utf8
        let count = bytes.count
        guard count == 20 || (22...24).contains(count), bytes.last == 90 else { return nil }
        func byte(_ index: Int) -> UInt8 { bytes[bytes.index(bytes.startIndex, offsetBy: index)] }
        for index in 0..<19 {
            let expected: UInt8? = switch index {
            case 4, 7: 45
            case 10: 84
            case 13, 16: 58
            default: nil
            }
            if let expected {
                guard byte(index) == expected else { return nil }
            } else if !(48...57).contains(byte(index)) { return nil }
        }
        if count > 20 {
            guard byte(19) == 46, (20..<(count - 1)).allSatisfy({ (48...57).contains(byte($0)) }) else { return nil }
        }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + Int(byte($1) - 48) } }
        let year = number(0..<4), month = number(5..<7), day = number(8..<10)
        let maximumDay: Int = switch month {
        case 2: year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100)) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
        guard year > 0, (1...12).contains(month), (1...maximumDay).contains(day),
              number(11..<13) < 24, number(14..<16) < 60, number(17..<19) < 60 else { return nil }
        return WireTime.date(value)
    }
}
