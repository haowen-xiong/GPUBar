import Foundation

public enum Platform: String, Codable, CaseIterable, Identifiable, Sendable {
    case qianhai, jiuzhang
    public var id: String { rawValue }
    public var title: String { self == .qianhai ? "前海" : "九章" }
    public var abbreviation: String { self == .qianhai ? "Q" : "J" }
    public var consoleURL: URL {
        URL(string: self == .qianhai ? "https://console.cn-sz-01.qhsgaicc.com/acp" : "https://www.alayanew.com/backend/resource/vks-raw/HTrain")!
    }
}

public struct Credentials: Codable, Sendable {
    public let accessKey: String
    public let secretKey: String
    public init(accessKey: String, secretKey: String) {
        self.accessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public var isValid: Bool {
        !accessKey.isEmpty && !secretKey.isEmpty && !accessKey.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\"" })
    }
}

public enum JobState: String, Codable, Sendable {
    case queued, starting, running, suspended, succeeded, failed, canceled, unknown
    public init(raw: String) {
        switch raw.uppercased() {
        case "WAITING", "QUEUEING", "QUEUING", "PENDING", "QUEUED": self = .queued
        case "CREATING", "STARTING", "INITIALIZING": self = .starting
        case "RUNNING": self = .running
        case "SUSPENDED", "SUSPENDING", "PAUSED": self = .suspended
        case "SUCCEEDED", "SUCCESS": self = .succeeded
        case "FAILED", "ERROR": self = .failed
        case "CANCELED", "CANCELLED", "DELETED": self = .canceled
        default: self = .unknown
        }
    }
    public var title: String {
        switch self {
        case .queued: "排队中"
        case .starting: "启动中"
        case .running: "运行中"
        case .suspended: "已暂停"
        case .succeeded: "已完成"
        case .failed: "失败"
        case .canceled: "已取消"
        case .unknown: "未知状态"
        }
    }
    public var terminal: Bool { [.succeeded, .failed, .canceled].contains(self) }
    public var order: Int {
        switch self {
        case .running: 0
        case .starting: 1
        case .queued: 2
        case .suspended: 3
        case .unknown: 4
        case .failed: 5
        case .succeeded: 6
        case .canceled: 7
        }
    }
}

public struct Job: Identifiable, Codable, Sendable, Equatable {
    public var id: String { platform.rawValue + ":" + nativeID }
    public let platform: Platform
    public let nativeID: String
    public let name: String
    public let rawState: String
    public var state: JobState { JobState(raw: rawState) }
    public var requestedGPUs: Int?
    public var allocatedGPUs: Int?
    public let nodes: Int?
    public let gpuModel: String?
    public let createdAt: Date?
    public let startedAt: Date?
    public let endedAt: Date?
    public let reason: String?
    public init(platform: Platform, nativeID: String, name: String, rawState: String, requestedGPUs: Int? = nil, allocatedGPUs: Int? = nil, nodes: Int? = nil, gpuModel: String? = nil, createdAt: Date? = nil, startedAt: Date? = nil, endedAt: Date? = nil, reason: String? = nil) {
        self.platform = platform; self.nativeID = nativeID; self.name = name; self.rawState = rawState
        self.requestedGPUs = requestedGPUs; self.allocatedGPUs = allocatedGPUs; self.nodes = nodes
        self.gpuModel = gpuModel; self.createdAt = createdAt; self.startedAt = startedAt; self.endedAt = endedAt; self.reason = reason
    }
    public var resourceText: String {
        if let allocatedGPUs { return "已分配 \(allocatedGPUs) GPU" }
        if let requestedGPUs { return "申请 \(requestedGPUs) GPU" }
        return "GPU —"
    }
    public func elapsed(now: Date = Date()) -> String {
        if state == .unknown { return "运行时间未知" }
        if state == .suspended { return "已暂停" }
        if state == .queued || state == .starting {
            guard let createdAt else { return "等待时间未知" }
            return "等待 " + Self.duration(max(0, now.timeIntervalSince(createdAt)))
        }
        guard let startedAt else { return state.terminal ? "运行时间未知" : "等待启动时间" }
        if state.terminal && endedAt == nil { return "运行时间未知" }
        return (state.terminal ? "用时 " : "已运行 ") + Self.duration(max(0, (endedAt ?? now).timeIntervalSince(startedAt)))
    }
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 1 { return "不足 1 分钟" }
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \(minutes % 1440 / 60)h"
    }
    public static func sorted(_ jobs: [Job]) -> [Job] {
        jobs.sorted {
            if $0.state.order != $1.state.order { return $0.state.order < $1.state.order }
            return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }
}

public struct GPUSpec: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let model: String
    public let gpusPerInstance: Int
    public let availableInstances: Int?
    public let availabilityNote: String?
    public init(id: String, model: String, gpusPerInstance: Int, availableInstances: Int?, availabilityNote: String? = nil) {
        self.id = id; self.model = model; self.gpusPerInstance = gpusPerInstance; self.availableInstances = availableInstances
        self.availabilityNote = availabilityNote
    }
}

public struct Capacity: Codable, Sendable, Equatable {
    public let availableGPUs: Int?
    public let totalGPUs: Int?
    public let allocatedGPUs: Int?
    public let model: String
    public let specs: [GPUSpec]
    public let explanation: String
    public init(availableGPUs: Int?, totalGPUs: Int? = nil, allocatedGPUs: Int? = nil, model: String, specs: [GPUSpec] = [], explanation: String) {
        self.availableGPUs = availableGPUs; self.totalGPUs = totalGPUs; self.allocatedGPUs = allocatedGPUs
        self.model = model; self.specs = specs; self.explanation = explanation
    }
}

public struct Snapshot: Codable, Sendable {
    public var capacity: Capacity?
    public var jobs: [Job] = []
    public var capacityAt: Date?
    public var jobsAt: Date?
    public var filter: String = ""
    public var scopeID: String?
    public init() {}
}

public enum CloudError: Error, LocalizedError, Sendable {
    case credentials, http(Int), malformed(String), pagination, network
    public var errorDescription: String? {
        switch self {
        case .credentials: "请在设置中配置 Access Key。"
        case .http(let code): code == 401 || code == 403 ? "凭据无效或没有访问权限（\(code)）。" : "平台请求失败（HTTP \(code)）。"
        case .malformed(let message): "平台数据格式异常：\(message)"
        case .pagination: "任务或节点分页未完整返回，请重新刷新。"
        case .network: "网络连接失败，请检查连接后重试。"
        }
    }
}

public enum APIJSON: Sendable, Decodable {
    case object([String: APIJSON]), array([APIJSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let a = try? c.decode([APIJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: APIJSON].self)) }
    }
    public subscript(_ key: String) -> APIJSON {
        if case .object(let object) = self { return object[key] ?? .null }; return .null
    }
    public var array: [APIJSON]? { if case .array(let value) = self { return value }; return nil }
    public var object: [String: APIJSON]? { if case .object(let value) = self { return value }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var int: Int? {
        if case .number(let value) = self, value.isFinite, value >= Double(Int.min), value < Double(Int.max), value.rounded() == value { return Int(value) }
        if case .string(let value) = self { return Int(value) }; return nil
    }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public func required(_ key: String) throws -> String {
        guard let value = self[key].string, !value.isEmpty else { throw CloudError.malformed("缺少 \(key)") }; return value
    }
    public static func decode(_ data: Data) throws -> APIJSON { try JSONDecoder().decode(APIJSON.self, from: data) }
}

public enum APIDates {
    public static func parse(_ raw: String?, beijing: Bool = false) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        guard beijing else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: raw)
    }
}
