import Foundation
import NowbeamCore

struct ConfigurationStore {
    private let directory: URL
    private let file: URL

    init() {
        let namespace = Bundle.main.bundleIdentifier ?? "local.nowbeam.development"
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["NOWBEAM_SETTINGS_ROOT"] {
            base = URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        directory = base.appendingPathComponent(namespace, isDirectory: true)
        file = directory.appendingPathComponent("settings.json")
    }

    func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else { return AppConfiguration() }
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard bytes.count <= 1_048_576 else { throw ApplicationError.configuration }
        return try JSONDecoder().decode(AppConfiguration.self, from: bytes)
    }

    func save(_ configuration: AppConfiguration) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

enum ApplicationError: LocalizedError {
    case configuration, missingCredential, invalidName, invalidApplication, unavailableReceiver
    var errorDescription: String? {
        switch self {
        case .configuration: "无法读写本地配置。分享保持关闭，请检查应用数据目录的权限。"
        case .missingCredential: "Keychain 中没有此凭证。请重新授权，不会自动发送活动。"
        case .invalidName: "请填写可用的名称，最长 128 个字符。"
        case .invalidApplication: "此应用没有稳定的 bundle identifier，不能用于隐私规则。"
        case .unavailableReceiver: "所选接收服务已变更，请重新选择。"
        }
    }
}
