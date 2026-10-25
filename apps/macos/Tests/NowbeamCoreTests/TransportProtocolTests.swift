import Foundation
import Testing
@testable import NowbeamCore

struct TransportProtocolTests {
    private let connectionID = "11111111-1111-4111-8111-111111111111"

    @Test func welcomeAcceptsOnlyTheFixedVersionOneContract() throws {
        let text = #"{"protocolVersion":1,"type":"welcome","connectionId":"11111111-1111-4111-8111-111111111111","deviceId":"22222222-2222-4222-8222-222222222222","serverTime":"2026-10-25T12:00:00.123Z","heartbeatIntervalMs":15000,"leaseDurationMs":45000,"maxMessageBytes":65536}"#
        guard case .welcome(let welcome) = try ServerMessage.decode(text) else {
            Issue.record("有效欢迎消息没有被识别")
            return
        }
        #expect(welcome.deviceId == "22222222-2222-4222-8222-222222222222")
        for changed in [
            text.replacingOccurrences(of: "15000", with: "10000"),
            text.replacingOccurrences(of: "2026-10-25", with: "2026-02-30"),
            text.replacingOccurrences(of: ".123Z", with: ".1234Z"),
            text.replacingOccurrences(of: ".123Z", with: "+00:00"),
            text.replacingOccurrences(of: "{", with: #"{"unexpected":null,"#)
        ] {
            #expect(throws: (any Error).self) { try ServerMessage.decode(changed) }
        }
    }

    @Test func ackRequiresAnExactLeaseAndSafeInteger() throws {
        let valid = #"{"protocolVersion":1,"type":"ack","connectionId":"11111111-1111-4111-8111-111111111111","sequence":1,"receivedAt":"2026-10-25T12:00:00Z","expiresAt":"2026-10-25T12:00:45Z"}"#
        guard case .ack(let ack) = try ServerMessage.decode(valid) else {
            Issue.record("有效确认消息没有被识别")
            return
        }
        #expect(ack.connectionId == connectionID)
        for changed in [
            valid.replacingOccurrences(of: "12:00:45", with: "12:00:46"),
            valid.replacingOccurrences(of: #""sequence":1"#, with: #""sequence":0"#),
            valid.replacingOccurrences(of: #""sequence":1"#, with: #""sequence":9007199254740992"#),
            valid.replacingOccurrences(of: #""sequence":1"#, with: #""sequence":1.5"#)
        ] {
            #expect(throws: (any Error).self) { try ServerMessage.decode(changed) }
        }
    }

    @Test(arguments: [
        "1.0000000000000001", "0.99999999999999999", "10000000000000001e-16",
        "9007199254740990.9", "9007199254740991.1", "9007199254740992.0",
        "9.007199254740992e15", "1e999999999999999999999", "1e-999999999999999999999"
    ])
    func rawNonIntegersAndUnsafeSequencesAreRejected(_ number: String) {
        for type in ["ack", "error"] {
            let suffix = type == "ack"
                ? #""receivedAt":"2026-10-25T12:00:00Z","expiresAt":"2026-10-25T12:00:45Z""#
                : #""code":"internal_error""#
            let text = #"{"protocolVersion":1,"type":"\#(type)","connectionId":"\#(connectionID)","sequence":\#(number),\#(suffix)}"#
            #expect(throws: (any Error).self) { try ServerMessage.decode(text) }
        }
    }

    @Test(arguments: [
        ("1.0", Int64(1)), ("1e0", Int64(1)), ("10e-1", Int64(1)),
        ("0.001e3", Int64(1)), ("1.0000000000000000000000", Int64(1)),
        ("1e+0000000000000000000000", Int64(1)),
        ("9007199254740991.0", Int64(9_007_199_254_740_991)),
        ("9.007199254740991e15", Int64(9_007_199_254_740_991)),
        ("9007199254740991000e-3", Int64(9_007_199_254_740_991))
    ])
    func exactDecimalAndExponentIntegersRemainValid(_ number: String, _ expected: Int64) throws {
        let text = #"{"protocolVersion":1.0,"type":"ack","connectionId":"\#(connectionID)","sequence":\#(number),"receivedAt":"2026-10-25T12:00:00Z","expiresAt":"2026-10-25T12:00:45Z"}"#
        guard case .ack(let message) = try ServerMessage.decode(text) else {
            Issue.record("有效整数确认消息没有被识别")
            return
        }
        #expect(message.sequence == expected)
        let error = #"{"protocolVersion":1e0,"type":"error","connectionId":"\#(connectionID)","sequence":\#(number),"code":"internal_error"}"#
        guard case .error(let failure) = try ServerMessage.decode(error) else {
            Issue.record("有效整数错误消息没有被识别")
            return
        }
        #expect(failure.sequence == expected)
    }

    @Test func welcomeValidatesEveryRawNumericFieldExactly() throws {
        let text = #"{"protocolVersion":1,"type":"welcome","connectionId":"11111111-1111-4111-8111-111111111111","deviceId":"22222222-2222-4222-8222-222222222222","serverTime":"2026-10-25T12:00:00Z","heartbeatIntervalMs":15000,"leaseDurationMs":45000,"maxMessageBytes":65536}"#
        for (field, value) in [
            ("protocolVersion", "1"), ("heartbeatIntervalMs", "15000"),
            ("leaseDurationMs", "45000"), ("maxMessageBytes", "65536")
        ] {
            let keyValue = "\"\(field)\":\(value)"
            for invalid in [value + ".0000000000000001", value + "00000000000000001e-17"] {
                #expect(throws: (any Error).self) {
                    try ServerMessage.decode(text.replacingOccurrences(of: keyValue, with: "\"\(field)\":\(invalid)"))
                }
            }
            for valid in [value + ".0", value + "e0", value + "0e-1"] {
                guard case .welcome = try ServerMessage.decode(
                    text.replacingOccurrences(of: keyValue, with: "\"\(field)\":\(valid)")
                ) else {
                    Issue.record("合法整数形式没有被识别")
                    return
                }
            }
        }
    }

    @Test(arguments: [
        #"{"protocolVersion":1,"type":"error","type":"error","connectionId":"11111111-1111-4111-8111-111111111111","sequence":null,"code":"internal_error"}"#,
        #"{"protocolVersion":1,"type":"error","\u0074ype":"error","connectionId":"11111111-1111-4111-8111-111111111111","sequence":null,"code":"internal_error"}"#,
        #"{"protocolVersion":1,"type":"error","connectionId":"11111111-1111-4111-8111-111111111111","code":"internal_error"}"#,
        #"{"protocolVersion":1,"type":"error","connectionId":"11111111-1111-4111-8111-111111111111","sequence":null,"code":"unknown_error"}"#,
        #"{"protocolVersion":1,"type":"error","connectionId":"11111111-1111-4111-8111-111111111111","sequence":null,"code":"\uD800"}"#,
        #"{"protocolVersion":1,"type":"error","connectionId":"11111111-1111-4111-8111-111111111111","sequence":null,"code":"\uDC00"}"#,
        #"{"protocolVersion":1,"type":"error","connectionId":"11111111-1111-4111-8111-111111111111","sequence":null,"code":{}}"#,
        #"[]"#
    ])
    func malformedMessagesFailClosed(_ text: String) {
        #expect(throws: (any Error).self) { try ServerMessage.decode(text) }
    }

    @Test func limitsApplyToUTF8BytesBeforeParsing() {
        #expect(throws: TransportError.messageTooLarge) { try ServerMessage.decode(String(repeating: "中", count: 21_846)) }
    }

    @Test func permanentFailuresNeverInviteAutomaticRetry() {
        for error in [TransportError.authentication, .certificate, .protocolMismatch, .invalidMessage, .messageTooLarge, .replaced, .revoked, .redirectRejected] {
            #expect(!error.permitsRetry)
        }
        #expect(TransportError.network.permitsRetry)
        #expect(TransportError.acknowledgementTimeout.permitsRetry)
    }

    @Test func onlyRecognizedTransientTransportErrorsCanRetry() {
        #expect(TransportError.classify(URLError(.serverCertificateUntrusted)) == .certificate)
        #expect(TransportError.classify(URLError(.userAuthenticationRequired)) == .authentication)
        #expect(TransportError.classify(URLError(.networkConnectionLost)) == .network)
        let disconnected = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTCONN.rawValue))
        #expect(TransportError.classify(disconnected) == .network)
        #expect(!TransportError.classify(NSError(domain: "unknown", code: 1)).permitsRetry)
    }
}
