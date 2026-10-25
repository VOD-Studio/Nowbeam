import Foundation
import NowbeamCore

public struct MediaSample: Decodable, Sendable {
    public let bundleIdentifier: String?
    public let parentApplicationBundleIdentifier: String?
    public let title: String?
    public let artist: String?
    public let album: String?
    public let contentItemIdentifier: String?
    public let playbackState: Int?
    public let durationMicros: Int64?
    public let elapsedTimeMicros: Int64?
    public let timestampEpochMicros: Int64?
    public let playbackRate: Double?
}

public struct MediaProjection: Sendable {
    private struct Identity: Equatable, Sendable {
        let player: String
        let track: String?
        let title: String?
        let artist: String?
    }

    private var identity: Identity?
    private var presence: MediaPresence?
    private var anchor: ContinuousClock.Instant?

    public init() {}

    public mutating func clear() {
        identity = nil
        presence = nil
        anchor = nil
    }

    public mutating func accept(
        _ sample: MediaSample?, runningApplications: Set<String>,
        wallTime: Date = Date(), instant: ContinuousClock.Instant = .now
    ) {
        guard let sample,
              let bundle = supportedBundle(sample), runningApplications.contains(bundle),
              let title = PublicText.clean(sample.title, limit: 512),
              sample.playbackState == 1 || sample.playbackState == 2 else {
            clear()
            return
        }
        let state: Playback.State = sample.playbackState == 1 ? .playing : .paused
        let rate: Double?
        if state == .paused {
            rate = 0
        } else if let reported = sample.playbackRate, reported.isFinite, reported > 0, reported <= 4 {
            rate = reported
        } else {
            rate = nil
        }
        let duration = sample.durationMicros.flatMap { value -> Int64? in
            guard value >= 1_000 else { return nil }
            let milliseconds = value / 1_000
            return milliseconds <= 9_007_199_254_740_991 ? milliseconds : nil
        }
        var position = sample.elapsedTimeMicros.flatMap { value -> Int64? in
            guard value >= 0 else { return nil }
            let milliseconds = value / 1_000
            return milliseconds <= 9_007_199_254_740_991 ? milliseconds : nil
        }
        if state == .playing, let base = position {
            if let timestamp = sample.timestampEpochMicros, let rate {
                let elapsed = wallTime.timeIntervalSince1970 - Double(timestamp) / 1_000_000
                if elapsed.isFinite && elapsed >= -2 && elapsed < 31_536_000 {
                    let projected = Double(base) + max(0, elapsed) * 1_000 * rate
                    position = projected <= 9_007_199_254_740_991 ? Int64(projected) : nil
                } else {
                    position = nil
                }
            } else {
                position = nil
            }
        }
        if let duration, let position, position >= duration {
            clear()
            return
        }
        let artist = PublicText.clean(sample.artist, limit: 512)
        let track = PublicText.clean(sample.contentItemIdentifier, limit: 512)
        let nextIdentity = Identity(player: bundle, track: track, title: track == nil ? title : nil, artist: track == nil ? artist : nil)
        let sessionId = nextIdentity == identity ? (presence?.sessionId ?? WireID.make()) : WireID.make()
        identity = nextIdentity
        presence = MediaPresence(
            sessionId: sessionId,
            playerName: bundle == "com.tencent.QQMusicMac" ? "QQ 音乐" : "网易云音乐",
            title: title, artist: artist, album: PublicText.clean(sample.album, limit: 512),
            playback: Playback(state: state, durationMs: duration, positionMs: position, rate: rate)
        )
        anchor = instant
    }

    public func current(at instant: ContinuousClock.Instant = .now) -> MediaPresence? {
        guard var value = presence, let anchor else { return nil }
        let age = anchor.duration(to: instant).components
        let elapsedMs = Double(age.seconds) * 1_000 + Double(age.attoseconds) / 1_000_000_000_000_000
        guard elapsedMs >= 0, elapsedMs < 30_000 else { return nil }
        if value.playback.state == .playing, let position = value.playback.positionMs, let rate = value.playback.rate {
            let projected = Double(position) + elapsedMs * rate
            guard projected <= 9_007_199_254_740_991 else { return nil }
            if let duration = value.playback.durationMs, projected >= Double(duration) { return nil }
            value.playback.positionMs = Int64(projected)
        }
        return value
    }

    private func supportedBundle(_ sample: MediaSample) -> String? {
        for identifier in [sample.bundleIdentifier, sample.parentApplicationBundleIdentifier] {
            if identifier == "com.tencent.QQMusicMac" || identifier == "com.netease.163music" { return identifier }
        }
        return nil
    }
}
