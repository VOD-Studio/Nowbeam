import Foundation

public struct ReceiverSettings: Codable, Sendable, Equatable {
    public var publicReadEnabled: Bool
    public var allowedOrigins: [String]

    public init(publicReadEnabled: Bool, allowedOrigins: [String]) {
        self.publicReadEnabled = publicReadEnabled
        self.allowedOrigins = allowedOrigins
    }

    private enum CodingKeys: String, CodingKey { case publicReadEnabled, allowedOrigins }

    public init(from decoder: any Decoder) throws {
        try requireManagementFields(["publicReadEnabled", "allowedOrigins"], decoder: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        publicReadEnabled = try values.decode(Bool.self, forKey: .publicReadEnabled)
        allowedOrigins = try values.decode([String].self, forKey: .allowedOrigins)
    }
}

public struct ReceiverDevice: Decodable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let createdAt: String

    private enum CodingKeys: String, CodingKey { case id, displayName, createdAt }

    public init(from decoder: any Decoder) throws {
        try requireManagementFields(["id", "displayName", "createdAt"], decoder: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        guard WireID.isValid(id), WireTimestamp.date(createdAt) != nil,
              PublicText.clean(displayName, limit: 128) == displayName else { throw TransportError.invalidMessage }
    }
}

public struct CreatedDevice: Decodable, Sendable {
    public let device: ReceiverDevice
    public let token: String
    public let ingestPath: String

    private enum CodingKeys: String, CodingKey { case device, token, ingestPath }

    public init(from decoder: any Decoder) throws {
        try requireManagementFields(["device", "token", "ingestPath"], decoder: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try values.decode(ReceiverDevice.self, forKey: .device)
        token = try values.decode(String.self, forKey: .token)
        ingestPath = try values.decode(String.self, forKey: .ingestPath)
        try validateBearerToken(token)
        guard ingestPath == "/api/v1/ingest" else { throw TransportError.protocolMismatch }
    }
}

public struct ReceiverManagementClient: Sendable {
    private let baseURL: URL
    private let token: String

    public init(baseURL: String, token: String, allowLoopback: Bool) throws {
        self.baseURL = try EndpointURL.management(baseURL, allowLoopback: allowLoopback)
        try validateBearerToken(token)
        self.token = token
    }

    public func bootstrap() async throws -> String {
        let data = try await request(path: "api/v1/setup", method: "POST", body: Data("{}".utf8), expectedStatus: 201)
        return try decode(OwnerCredential.self, data: data).ownerToken
    }

    public func settings() async throws -> ReceiverSettings {
        let data = try await request(path: "api/v1/admin/settings", method: "GET", expectedStatus: 200)
        return try decode(ReceiverSettings.self, data: data)
    }

    public func updateSettings(_ settings: ReceiverSettings) async throws {
        let data = try await request(path: "api/v1/admin/settings", method: "PUT", body: JSONEncoder().encode(settings), expectedStatus: 200)
        _ = try decode(ReceiverSettings.self, data: data)
    }

    public func devices() async throws -> [ReceiverDevice] {
        let data = try await request(path: "api/v1/admin/devices", method: "GET", expectedStatus: 200)
        return try decode(DeviceList.self, data: data).devices
    }

    public func createDevice(displayName: String) async throws -> CreatedDevice {
        guard let name = PublicText.clean(displayName, limit: 128), name == displayName else { throw TransportError.invalidRequest }
        struct DeviceRequest: Encodable { let displayName: String }
        let data = try await request(path: "api/v1/admin/devices", method: "POST", body: JSONEncoder().encode(DeviceRequest(displayName: name)), expectedStatus: 201)
        return try decode(CreatedDevice.self, data: data)
    }

    public func revokeDevice(id: String) async throws {
        guard WireID.isValid(id) else { throw TransportError.invalidRequest }
        _ = try await request(path: "api/v1/admin/devices/\(id)", method: "DELETE", expectedStatus: 204)
    }

    private func request(path: String, method: String, body: Data? = nil, expectedStatus: Int) async throws -> Data {
        guard (body?.count ?? 0) <= 16_384 else { throw TransportError.invalidRequest }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let configuration = privateSessionConfiguration()
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: SessionSecurityDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw TransportError.protocolMismatch }
            guard response.statusCode == expectedStatus else {
                switch response.statusCode {
                case 400, 413, 422: throw TransportError.invalidRequest
                case 404: throw TransportError.deviceNotFound
                case 300...399, 401, 403, 409, 429, 500...599: throw TransportError.httpStatus(response.statusCode)
                default: throw TransportError.managementRejected
                }
            }
            if expectedStatus != 204 {
                guard response.mimeType?.lowercased() == "application/json" else { throw TransportError.invalidMessage }
            }
            // 设备列表可以大于上报消息，但整个响应仍有硬上限，不能无界缓存。
            let maximumResponseBytes = 1_048_576
            guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw TransportError.messageTooLarge }
            var data = Data()
            data.reserveCapacity(min(maximumResponseBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in stream {
                guard data.count < maximumResponseBytes else { throw TransportError.messageTooLarge }
                data.append(byte)
            }
            if expectedStatus == 204, !data.isEmpty { throw TransportError.invalidMessage }
            return data
        } catch {
            throw TransportError.classify(error)
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TransportError.invalidMessage }
    }
}

private struct OwnerCredential: Decodable {
    let ownerToken: String
    private enum CodingKeys: String, CodingKey { case ownerToken }
    init(from decoder: any Decoder) throws {
        try requireManagementFields(["ownerToken"], decoder: decoder)
        ownerToken = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .ownerToken)
        try validateBearerToken(ownerToken)
    }
}

private struct DeviceList: Decodable {
    let devices: [ReceiverDevice]
    private enum CodingKeys: String, CodingKey { case devices }
    init(from decoder: any Decoder) throws {
        try requireManagementFields(["devices"], decoder: decoder)
        devices = try decoder.container(keyedBy: CodingKeys.self).decode([ReceiverDevice].self, forKey: .devices)
        guard Set(devices.map(\.id)).count == devices.count else { throw TransportError.invalidMessage }
    }
}

private struct ManagementKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireManagementFields(_ expected: Set<String>, decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: ManagementKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == expected else { throw TransportError.invalidMessage }
}
