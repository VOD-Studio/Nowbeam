import Foundation

public enum EndpointURL {
    public static func websocket(_ text: String, allowLoopback: Bool) throws -> URL {
        try validated(text, secureScheme: "wss", developmentScheme: "ws", allowLoopback: allowLoopback)
    }

    public static func management(_ text: String, allowLoopback: Bool) throws -> URL {
        try validated(text, secureScheme: "https", developmentScheme: "http", allowLoopback: allowLoopback)
    }

    private static func validated(_ text: String, secureScheme: String, developmentScheme: String, allowLoopback: Bool) throws -> URL {
        guard !text.isEmpty, !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }),
              let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty, !host.contains("%"),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = parts.url else { throw TransportError.invalidEndpoint }
        if scheme == secureScheme { return url }
        #if DEBUG
        if allowLoopback, scheme == developmentScheme,
           parts.percentEncodedHost == "127.0.0.1" || parts.percentEncodedHost == "[::1]" || parts.percentEncodedHost == "::1" { return url }
        #endif
        throw TransportError.insecureEndpoint
    }
}

public enum TransportError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint, insecureEndpoint, invalidCredential, redirectRejected
    case authentication, certificate, protocolMismatch, invalidMessage, messageTooLarge
    case acknowledgementTimeout, connectionTimeout, replaced, revoked, serverUnavailable, network
    case invalidRequest, managementRejected, alreadyInitialized, deviceNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "接收端地址无效，不能包含凭证、查询参数或片段。"
        case .insecureEndpoint: "请使用安全连接；明文连接仅限显式开启的本机开发模式。"
        case .invalidCredential: "凭证格式无效，请重新输入接收端颁发的凭证。"
        case .redirectRejected: "接收端要求重定向，已阻止转发凭证；请核对完整地址。"
        case .authentication: "接收端拒绝认证，请重新授权。"
        case .certificate: "安全连接验证失败，请检查接收端证书。"
        case .protocolMismatch: "接收端不兼容 Nowbeam 第一版协议，请核对地址。"
        case .invalidMessage: "接收端消息不符合协议，已停止连接。"
        case .messageTooLarge: "消息超过协议大小限制，已停止连接。"
        case .acknowledgementTimeout: "接收端未及时确认，正在重新建立连接。"
        case .connectionTimeout: "接收端连接超时，正在等待重试。"
        case .replaced: "此凭证已被另一连接使用，已停止自动重连。"
        case .revoked: "设备凭证已撤销，请重新授权。"
        case .serverUnavailable: "接收端暂时不可用，正在等待重试。"
        case .network: "网络连接中断，正在等待重试。"
        case .invalidRequest: "管理请求无效，请检查输入。"
        case .managementRejected: "接收端拒绝了管理请求。"
        case .alreadyInitialized: "接收服务已经初始化，请使用已有的所有者凭证。"
        case .deviceNotFound: "设备不存在或已撤销。"
        }
    }

    var permitsRetry: Bool {
        switch self {
        case .network, .serverUnavailable, .connectionTimeout, .acknowledgementTimeout: true
        default: false
        }
    }

    static func classify(_ error: any Error, task: URLSessionTask? = nil) -> TransportError {
        if let known = error as? TransportError { return known }
        if let status = (task?.response as? HTTPURLResponse)?.statusCode, status != 101, !(200...299).contains(status) {
            return httpStatus(status)
        }
        if let socket = task as? URLSessionWebSocketTask {
            switch socket.closeCode.rawValue {
            case 4001: return .revoked
            case 4002: return .replaced
            case 1009: return .messageTooLarge
            case 1002, 1003, 1007, 1008: return .invalidMessage
            case 1011: return .serverUnavailable
            case 1010: return .protocolMismatch
            case 1000, 1001, 1006, 4003: return .network
            default: break
            }
        }
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain, let rawCode = Int32(exactly: failure.code),
           let code = POSIXErrorCode(rawValue: rawCode) {
            switch code {
            case .ENOTCONN, .ECONNRESET, .ECONNABORTED, .ECONNREFUSED, .ETIMEDOUT,
                 .ENETDOWN, .ENETRESET, .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH, .EPIPE:
                return .network
            default: return .protocolMismatch
            }
        }
        guard failure.domain == NSURLErrorDomain else { return .protocolMismatch }
        switch failure.code {
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired, NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return .certificate
        case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
            return .authentication
        case NSURLErrorTimedOut: return .connectionTimeout
        case NSURLErrorBadServerResponse, NSURLErrorCannotParseResponse, NSURLErrorUnsupportedURL:
            return .protocolMismatch
        case NSURLErrorDataLengthExceedsMaximum: return .messageTooLarge
        case NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorCancelled:
            return .network
        default: return .protocolMismatch
        }
    }

    static func httpStatus(_ status: Int) -> TransportError {
        switch status {
        case 300...399: .redirectRejected
        case 401, 403: .authentication
        case 409: .alreadyInitialized
        case 429, 500...599: .serverUnavailable
        default: .protocolMismatch
        }
    }
}

// 凭证只进入请求头。拒绝空白和非 ASCII 字符，避免请求头注入或隐式修正。
func validateBearerToken(_ token: String) throws {
    guard !token.isEmpty, token.utf8.count <= 8_192,
          token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw TransportError.invalidCredential }
}

func privateSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 10
    return configuration
}

// Foundation 在不同队列回调；只有握手结果由锁保护，不保存消息正文或凭证。
final class SessionSecurityDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, TransportError>?
    private var waiter: CheckedContinuation<Void, any Error>?

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result.mapError { $0 as any Error })
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ outcome: Result<Void, TransportError>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(with: outcome.mapError { $0 as any Error })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        finish(.failure(.redirectRejected))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            finish(.failure(.authentication))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
        guard protocolName == "nowbeam.v1",
              (webSocketTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Extensions") == nil else {
            finish(.failure(.protocolMismatch))
            webSocketTask.cancel(with: .protocolError, reason: nil)
            return
        }
        finish(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(.failure(TransportError.classify(error ?? URLError(.badServerResponse), task: task)))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.failure(TransportError.classify(URLError(.networkConnectionLost), task: webSocketTask)))
    }
}
