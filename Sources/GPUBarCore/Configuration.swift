import Foundation

/// Resource identifiers only. API credentials live separately in Keychain.
public struct MonitoringConfiguration: Codable, Equatable, Sendable {
    public var qianhai = QianhaiConfiguration()
    public var jiuzhang = JiuzhangConfiguration()
    public init() {}

    public func validate(_ platform: Platform) throws {
        switch platform {
        case .qianhai: try qianhai.validate()
        case .jiuzhang: try jiuzhang.validate()
        }
    }
    public func isConfigured(_ platform: Platform) -> Bool {
        (try? validate(platform)) != nil
    }
    public func scope(_ platform: Platform) -> String {
        switch platform {
        case .qianhai: "ACP · \(qianhai.pool.isEmpty ? "未设置资源池" : qianhai.pool)"
        case .jiuzhang:
            if let id = jiuzhang.aidcID {
                "极核训练 · \(jiuzhang.regionName.isEmpty ? "机房 \(id)" : jiuzhang.regionName)"
            } else { "极核训练 · 未设置机房" }
        }
    }
    /// Used to reject cache entries from a different resource scope.
    public func cacheKey(_ platform: Platform) -> String {
        switch platform {
        case .qianhai: qianhai.poolRoot + "|" + qianhai.taskRoot
        case .jiuzhang: "aidc:\(jiuzhang.aidcID.map(String.init) ?? "unset")"
        }
    }
    public func normalized() -> Self {
        var result = self
        result.qianhai.subscriptionID = qianhai.subscriptionID.trimmed
        result.qianhai.resourceGroup = qianhai.resourceGroup.trimmed
        result.qianhai.nodeZone = qianhai.nodeZone.trimmed
        result.qianhai.taskZone = qianhai.taskZone.trimmed
        result.qianhai.pool = qianhai.pool.trimmed
        result.qianhai.workspace = qianhai.workspace.trimmed
        result.jiuzhang.regionName = jiuzhang.regionName.trimmed
        return result
    }
}

public struct QianhaiConfiguration: Codable, Equatable, Sendable {
    public var subscriptionID = ""
    public var resourceGroup = "default"
    public var nodeZone = "cn-sz-01a"
    public var taskZone = "cn-sz-01z"
    public var pool = ""
    public var workspace = ""
    public init() {}

    public func validate() throws {
        for value in [subscriptionID, resourceGroup, nodeZone, taskZone, pool, workspace] {
            guard !value.isEmpty, value.utf8.count <= 256,
                  value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else {
                throw ConfigurationError("请设置前海订阅、资源组、可用区、资源池和工作空间；标识仅支持字母、数字、短横线和下划线。")
            }
        }
    }
    public var poolRoot: String {
        "/compute/aec2/data/v1/subscriptions/\(subscriptionID)/resourceGroups/\(resourceGroup)/zones/\(nodeZone)/aec2s/\(pool)"
    }
    public var taskRoot: String {
        "/compute/acp/data/v2/subscriptions/\(subscriptionID)/resourceGroups/\(resourceGroup)/zones/\(taskZone)/workspaces/\(workspace)/trainingJobs"
    }
}

public struct JiuzhangConfiguration: Codable, Equatable, Sendable {
    public var aidcID: Int?
    public var regionName = ""
    public init() {}
    public func validate() throws {
        guard let aidcID, aidcID > 0 else { throw ConfigurationError("请设置九章智算中心 ID（正整数）。") }
    }
}

public struct ConfigurationError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
