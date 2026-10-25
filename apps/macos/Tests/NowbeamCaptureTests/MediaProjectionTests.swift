import Foundation
import Testing
@testable import NowbeamCapture
import NowbeamCore

struct MediaProjectionTests {
    private let player = "com.tencent.QQMusicMac"
    private let wall = Date(timeIntervalSince1970: 1_000)

    private func sample(_ changes: [String: Any] = [:]) throws -> MediaSample {
        var fields: [String: Any] = [
            "bundleIdentifier": player, "title": "测试曲目", "artist": "测试艺人",
            "contentItemIdentifier": "track-a", "playbackState": 1, "playbackRate": 1.0,
            "durationMicros": 120_000_000, "elapsedTimeMicros": 10_000_000,
            "timestampEpochMicros": 1_000_000_000,
        ]
        fields.merge(changes) { _, replacement in replacement }
        return try JSONDecoder().decode(MediaSample.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test func pauseKeepsSessionButNeverAdvancesPosition() throws {
        var projection = MediaProjection()
        let start = ContinuousClock.now
        projection.accept(try sample(), runningApplications: [player], wallTime: wall, instant: start)
        let initial = try #require(projection.current(at: start))
        #expect(projection.current(at: start.advanced(by: .seconds(5)))?.playback.positionMs == 15_000)
        projection.accept(try sample(["playbackState": 2, "playbackRate": 1.0, "elapsedTimeMicros": 15_000_000]),
                          runningApplications: [player], wallTime: wall.addingTimeInterval(5), instant: start.advanced(by: .seconds(5)))
        let paused = try #require(projection.current(at: start.advanced(by: .seconds(20))))
        #expect(paused.sessionId == initial.sessionId)
        #expect(paused.playback.state == .paused)
        #expect(paused.playback.rate == 0)
        #expect(paused.playback.positionMs == 15_000)
    }

    @Test(arguments: [0, 3, 4])
    func nonSessionStatesCannotBecomePausedGhosts(_ state: Int) throws {
        var projection = MediaProjection()
        let start = ContinuousClock.now
        projection.accept(try sample(), runningApplications: [player], wallTime: wall, instant: start)
        let previous = try #require(projection.current(at: start))
        projection.accept(try sample(["playbackState": state]), runningApplications: [player], wallTime: wall, instant: start)
        #expect(projection.current(at: start) == nil)
        projection.accept(try sample(["playbackState": 2]), runningApplications: [player], wallTime: wall, instant: start)
        let resumed = try #require(projection.current(at: start))
        #expect(resumed.sessionId != previous.sessionId)
    }

    @Test func exitedOrUnsupportedPlayerClearsPreviousTrack() throws {
        var projection = MediaProjection()
        let start = ContinuousClock.now
        projection.accept(try sample(), runningApplications: [player], wallTime: wall, instant: start)
        #expect(projection.current(at: start)?.playerName == "QQ 音乐")
        projection.accept(try sample(), runningApplications: [], wallTime: wall, instant: start)
        #expect(projection.current(at: start) == nil)
        projection.accept(try sample(["bundleIdentifier": "other.player"]), runningApplications: ["other.player"], wallTime: wall, instant: start)
        #expect(projection.current(at: start) == nil)
    }

    @Test func missingRateDoesNotInventProgress() throws {
        var projection = MediaProjection()
        let start = ContinuousClock.now
        projection.accept(try sample(["playbackRate": NSNull()]), runningApplications: [player], wallTime: wall, instant: start)
        let value = try #require(projection.current(at: start.advanced(by: .seconds(10))))
        #expect(value.playback.state == .playing)
        #expect(value.playback.rate == nil)
        #expect(value.playback.positionMs == nil)
        #expect(value.playback.durationMs == 120_000)
    }

    @Test func endingAndStaleCollectionCannotBeKeptAliveByNetwork() throws {
        var projection = MediaProjection()
        let start = ContinuousClock.now
        projection.accept(try sample(), runningApplications: [player], wallTime: wall, instant: start)
        #expect(projection.current(at: start.advanced(by: .seconds(30))) == nil)
        projection.accept(try sample(["playbackState": 2, "elapsedTimeMicros": 120_000_000]), runningApplications: [player], wallTime: wall, instant: start)
        #expect(projection.current(at: start) == nil)
        projection.accept(try sample(["elapsedTimeMicros": 119_000_000]), runningApplications: [player], wallTime: wall, instant: start)
        #expect(projection.current(at: start.advanced(by: .seconds(1))) == nil)
    }

    @Test func trackSwitchCreatesIndependentSessionWithoutLosingNeteaseIdentity() throws {
        var projection = MediaProjection()
        let start = ContinuousClock.now
        let netease = "com.netease.163music"
        projection.accept(try sample(["bundleIdentifier": netease]), runningApplications: [netease], wallTime: wall, instant: start)
        let first = try #require(projection.current(at: start))
        projection.accept(try sample(["bundleIdentifier": netease, "contentItemIdentifier": "track-b", "title": "另一首曲目"]), runningApplications: [netease], wallTime: wall, instant: start)
        let second = try #require(projection.current(at: start))
        #expect(second.playerName == "网易云音乐")
        #expect(second.title == "另一首曲目")
        #expect(first.sessionId != second.sessionId)
    }

    @Test func outOfWireRangeNumbersBecomeUnknownInsteadOfPoisoningSnapshot() throws {
        var projection = MediaProjection()
        let start = ContinuousClock.now
        projection.accept(try sample(["playbackState": 2, "durationMicros": Int64.max]), runningApplications: [player], wallTime: wall, instant: start)
        let durationUnknown = try #require(projection.current(at: start))
        #expect(durationUnknown.playback.durationMs == nil)
        #expect(durationUnknown.playback.positionMs == 10_000)
        projection.accept(try sample(["playbackState": 2, "elapsedTimeMicros": Int64.max]), runningApplications: [player], wallTime: wall, instant: start)
        let positionUnknown = try #require(projection.current(at: start))
        #expect(positionUnknown.playback.positionMs == nil)
        #expect(positionUnknown.playback.durationMs == 120_000)
    }

    @Test func publicTextStripsControlsAndCountsUnicodeScalars() {
        #expect(PublicText.clean("\u{0000}A\u{1D11E}B\u{007F}C", limit: 3) == "A\u{1D11E}B")
        #expect(PublicText.clean(" \n\t ", limit: 10) == nil)
    }
}
