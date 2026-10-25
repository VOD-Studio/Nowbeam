import Foundation

public struct ApplicationPresence: Codable, Equatable, Sendable {
    public var displayName: String
    public init(displayName: String) { self.displayName = displayName }
}

public struct WindowPresence: Codable, Equatable, Sendable {
    public var title: String
    public init(title: String) { self.title = title }
}

public struct Playback: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case playing, paused }
    public var state: State
    public var durationMs: Int64?
    public var positionMs: Int64?
    public var rate: Double?

    public init(state: State, durationMs: Int64?, positionMs: Int64?, rate: Double?) {
        self.state = state
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.rate = state == .paused ? 0 : rate
    }

    private enum CodingKeys: String, CodingKey { case state, durationMs, positionMs, rate }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(State.self, forKey: .state)
        durationMs = try values.decode(Int64?.self, forKey: .durationMs)
        positionMs = try values.decode(Int64?.self, forKey: .positionMs)
        rate = try values.decode(Double?.self, forKey: .rate)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        try values.encode(durationMs, forKey: .durationMs)
        try values.encode(positionMs, forKey: .positionMs)
        try values.encode(rate, forKey: .rate)
    }
}

public struct MediaPresence: Codable, Equatable, Sendable {
    public var sessionId: String
    public var playerName: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var playback: Playback

    public init(sessionId: String, playerName: String, title: String, artist: String?, album: String?, playback: Playback) {
        self.sessionId = sessionId
        self.playerName = playerName
        self.title = title
        self.artist = artist
        self.album = album
        self.playback = playback
    }

    private enum CodingKeys: String, CodingKey { case sessionId, playerName, title, artist, album, playback }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try values.decode(String.self, forKey: .sessionId)
        playerName = try values.decode(String.self, forKey: .playerName)
        title = try values.decode(String.self, forKey: .title)
        artist = try values.decode(String?.self, forKey: .artist)
        album = try values.decode(String?.self, forKey: .album)
        playback = try values.decode(Playback.self, forKey: .playback)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionId, forKey: .sessionId)
        try values.encode(playerName, forKey: .playerName)
        try values.encode(title, forKey: .title)
        try values.encode(artist, forKey: .artist)
        try values.encode(album, forKey: .album)
        try values.encode(playback, forKey: .playback)
    }
}

public struct Sources: Codable, Equatable, Sendable {
    public var application: ApplicationPresence?
    public var window: WindowPresence?
    public var media: MediaPresence?
    public static let empty = Sources()

    public init(application: ApplicationPresence? = nil, window: WindowPresence? = nil, media: MediaPresence? = nil) {
        self.application = application
        self.window = window
        self.media = media
    }
    private enum CodingKeys: String, CodingKey { case application, window, media }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        application = try values.decode(ApplicationPresence?.self, forKey: .application)
        window = try values.decode(WindowPresence?.self, forKey: .window)
        media = try values.decode(MediaPresence?.self, forKey: .media)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(application, forKey: .application)
        try values.encode(window, forKey: .window)
        try values.encode(media, forKey: .media)
    }
}

public enum WireTime {
    public static func string(_ date: Date = Date()) -> String { date.formatted(.iso8601) }
    public static func date(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

public enum WireID {
    public static func make() -> String { UUID().uuidString.lowercased() }
    public static func isValid(_ text: String) -> Bool {
        guard text.utf8.count == 36 else { return false }
        for (index, byte) in text.utf8.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                guard byte == 45 else { return false }
            case 14:
                guard byte == 52 else { return false }
            case 19:
                guard byte == 56 || byte == 57 || byte == 97 || byte == 98 else { return false }
            default:
                guard (48...57).contains(byte) || (97...102).contains(byte) else { return false }
            }
        }
        return true
    }
}

public struct SnapshotMessage: Encodable, Sendable {
    public let protocolVersion = 1
    public let type = "snapshot"
    public let connectionId: String
    public let sequence: Int64
    public let observedAt: String
    public let sources: Sources

    public init(connectionId: String, sequence: Int64, sources: Sources, observedAt: String = WireTime.string()) {
        self.connectionId = connectionId
        self.sequence = sequence
        self.sources = sources
        self.observedAt = observedAt
    }
}

public struct WelcomeMessage: Decodable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let connectionId: String
    public let deviceId: String
    public let serverTime: String
    public let heartbeatIntervalMs: Int
    public let leaseDurationMs: Int
    public let maxMessageBytes: Int

    public var isValid: Bool {
        protocolVersion == 1 && type == "welcome" && WireID.isValid(connectionId)
            && WireID.isValid(deviceId) && WireTime.date(serverTime) != nil
            && heartbeatIntervalMs == 15_000 && leaseDurationMs == 45_000 && maxMessageBytes == 65_536
    }
}

public struct Acknowledgement: Decodable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let connectionId: String
    public let sequence: Int64
    public let receivedAt: String
    public let expiresAt: String
}

public struct ReceiverErrorMessage: Decodable, Sendable {
    public let protocolVersion: Int
    public let type: String
    public let connectionId: String
    public let sequence: Int64?
    public let code: String
}
