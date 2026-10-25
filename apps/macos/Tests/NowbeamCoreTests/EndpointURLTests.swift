import Foundation
import Testing
@testable import NowbeamCore

struct EndpointURLTests {
    @Test func secureCustomIngestPathIsPreserved() throws {
        let url = try EndpointURL.websocket("wss://receiver.example/custom/ingest", allowLoopback: false)
        #expect(url.absoluteString == "wss://receiver.example/custom/ingest")
        #expect(try EndpointURL.management("https://receiver.example/", allowLoopback: false).scheme == "https")
    }

    @Test(arguments: [
        "wss://user:secret@receiver.example/ingest", "wss://receiver.example/ingest?token=secret",
        "wss://receiver.example/ingest#secret", "https://receiver.example/ingest",
        "wss:///ingest", "wss://receiver.example:0/ingest", "wss://receiver.example:65536/ingest",
        " wss://receiver.example/ingest", "wss://receiver.example/\n", "wss://receiver.example/\\other",
        "ws://localhost/ingest", "ws://127.1/ingest", "ws://2130706433/ingest",
        "ws://%31%32%37.0.0.1/ingest", "ws://127.0.0.1./ingest",
        "ws://127.0.0.2/ingest", "ws://[::ffff:127.0.0.1]/ingest", "ws://192.168.1.2/ingest"
    ])
    func unsafeWebsocketURLsAreRejected(_ text: String) {
        #expect(throws: (any Error).self) { try EndpointURL.websocket(text, allowLoopback: true) }
    }

    @Test func cleartextNeedsBothDebugBuildAndExplicitConsent() throws {
        for text in ["ws://127.0.0.1:8787/api/v1/ingest", "ws://[::1]:8787/api/v1/ingest"] {
            #expect(throws: (any Error).self) { try EndpointURL.websocket(text, allowLoopback: false) }
            #if DEBUG
            #expect(try EndpointURL.websocket(text, allowLoopback: true).scheme == "ws")
            #else
            #expect(throws: (any Error).self) { try EndpointURL.websocket(text, allowLoopback: true) }
            #endif
        }
        #if DEBUG
        #expect(try EndpointURL.management("http://127.0.0.1:8787", allowLoopback: true).scheme == "http")
        #else
        #expect(throws: (any Error).self) { try EndpointURL.management("http://127.0.0.1:8787", allowLoopback: true) }
        #endif
    }

    @Test(arguments: ["https://user@receiver.example", "https://receiver.example?", "https://receiver.example#", "http://localhost:8787"])
    func managementHasTheSameCredentialBoundary(_ text: String) {
        #expect(throws: (any Error).self) { try EndpointURL.management(text, allowLoopback: true) }
    }
}
