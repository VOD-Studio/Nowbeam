import Foundation
import Testing
@testable import NowbeamCore

struct ReceiverManagementModelTests {
    @Test(arguments: [
        #"{"publicReadEnabled":false,"allowedOrigins":[],"token":"unexpected"}"#,
        #"{"publicReadEnabled":false}"#,
        #"{"publicReadEnabled":"false","allowedOrigins":[]}"#
    ])
    func incompatibleSettingsAreRejected(_ text: String) {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ReceiverSettings.self, from: Data(text.utf8)) }
    }

    @Test(arguments: ["", "a b", "a\r\nAuthorization: other", "中文凭证"])
    func credentialsCannotBecomeAdditionalRequestHeaders(_ token: String) {
        #expect(throws: (any Error).self) {
            try ReceiverManagementClient(baseURL: "https://receiver.example", token: token, allowLoopback: false)
        }
    }

    @Test func outgoingSnapshotsRejectInvalidPlaybackBoundaries() throws {
        let media = MediaPresence(sessionId: "11111111-1111-4111-8111-111111111111", playerName: "测试播放器", title: "测试曲目", artist: nil, album: nil,
                                  playback: Playback(state: .playing, durationMs: 100, positionMs: 101, rate: 1))
        #expect(throws: (any Error).self) { try ServerMessage.validate(Sources(media: media)) }
        var invalid = media
        invalid.playback = Playback(state: .playing, durationMs: nil, positionMs: nil, rate: .nan)
        #expect(throws: (any Error).self) { try ServerMessage.validate(Sources(media: invalid)) }
    }
}
