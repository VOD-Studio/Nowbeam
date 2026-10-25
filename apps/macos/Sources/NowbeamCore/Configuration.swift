import Foundation

public struct SourcePreferences: Codable, Equatable, Sendable {
    public var applicationEnabled = false
    public var windowEnabled = false
    public var mediaEnabled = false
    public var hiddenApplications: Set<String> = []
    public var allowedWindowApplications: Set<String> = []
    public init() {}
}

public struct Destination: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: String
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, endpoint: String, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.enabled = enabled
    }
    public var credentialAccount: String { "destination.\(id.uuidString.lowercased())" }
}

public struct ManagedReceiver: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public init(id: UUID = UUID(), name: String, baseURL: String) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }
    public var credentialAccount: String { "owner.\(id.uuidString.lowercased())" }
}

public struct AppConfiguration: Codable, Sendable {
    public var sources = SourcePreferences()
    public var sharingEnabled = false
    public var allowLoopbackDevelopment = false
    public var destinations: [Destination] = []
    public var managedReceivers: [ManagedReceiver] = []
    public init() {}
}

public enum PublicText {
    public static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.lazy.filter { $0.value >= 32 && $0.value != 127 }
        let result = String(String.UnicodeScalarView(scalars.prefix(limit)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
