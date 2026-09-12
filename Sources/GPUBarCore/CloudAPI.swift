import Foundation
import CryptoKit

public enum Signing {
    public static func hmac(_ message: String, secret: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8))))
    }
    public static func qianhai(credentials: Credentials, path: String, date: String) -> String {
        let signature = hmac("x-date: \(date)\nGET \(path) HTTP/1.1", secret: credentials.secretKey).base64EncodedString()
        return "hmac accesskey=\"\(credentials.accessKey)\", algorithm=\"hmac-sha256\", headers=\"x-date request-line\", signature=\"\(signature)\""
    }
    public static func jiuzhang(credentials: Credentials, path: String, milliseconds: Int64) -> String {
        let signature = hmac("\(milliseconds)|GET|\(path)", secret: credentials.secretKey).map { String(format: "%02x", $0) }.joined()
        return "alayanew-HMAC-SHA256 \(credentials.accessKey):\(milliseconds):\(signature)"
    }
    public static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct CloudAPI: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    public let platform: Platform
    private let credentials: Credentials
    private let transport: Transport
    private let configuration: MonitoringConfiguration

    public init(platform: Platform, credentials: Credentials, configuration: MonitoringConfiguration, transport: Transport? = nil) {
        self.platform = platform; self.credentials = credentials
        self.configuration = configuration.normalized()
        self.transport = transport ?? Self.network
    }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()
    private static func network(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudError.network }
            return (data, http.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw CloudError.network }
    }
    private func get(_ path: String, query: [(String, String)] = []) async throws -> APIJSON {
        try Task.checkCancellation()
        try configuration.validate(platform)
        guard credentials.isValid else { throw CloudError.credentials }
        let queryText = query.map { Signing.encode($0.0) + "=" + Signing.encode($0.1) }.joined(separator: "&")
        let requestPath = path + (queryText.isEmpty ? "" : "?" + queryText)
        let host = platform == .qianhai ? "https://aec2.cn-sz-01.qhsgaiccapi.com" : "https://api.alayanew.com"
        guard let url = URL(string: host + requestPath) else { throw CloudError.malformed("请求地址") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if platform == .qianhai {
            let date = Signing.httpDate(Date())
            request.setValue(date, forHTTPHeaderField: "X-Date")
            request.setValue(Signing.qianhai(credentials: credentials, path: requestPath, date: date), forHTTPHeaderField: "Authorization")
        } else {
            let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
            request.setValue(Signing.jiuzhang(credentials: credentials, path: path, milliseconds: milliseconds), forHTTPHeaderField: "Authorization")
        }
        let (data, status) = try await transport(request)
        guard (200..<300).contains(status) else { throw CloudError.http(status) }
        guard data.count <= 16_000_000, let json = try? APIJSON.decode(data) else { throw CloudError.malformed("不是有效的 JSON") }
        if platform == .jiuzhang {
            guard json["status"].int == 200 else { throw CloudError.http(json["status"].int ?? 502) }
            return json["data"]
        }
        if let code = json["code"].int, code != 0 { throw CloudError.malformed("平台拒绝请求（\(code)）") }
        return json
    }

    private func qPages(path: String, key: String) async throws -> [APIJSON] {
        var token = "1", tokens: Set<String> = [], rows: [APIJSON] = []
        for _ in 0..<100 {
            guard tokens.insert(token).inserted else { throw CloudError.pagination }
            let json = try await get(path, query: [("page_size", "100"), ("page_token", token)])
            guard let page = json[key].array else { throw CloudError.malformed("缺少 \(key)") }
            rows += page
            let next = json["next_page_token"].string ?? ""
            if next.isEmpty {
                if let total = json["total_size"].int, rows.count < total { throw CloudError.pagination }
                return rows
            }
            if page.isEmpty { throw CloudError.pagination }
            token = next
        }
        throw CloudError.pagination
    }

    public func capacity() async throws -> Capacity {
        if platform == .jiuzhang {
            return try Parsing.jiuzhangCapacity(await get("/api/osm/v1/product/list-for-training-task", query: [("aidcId", String(configuration.jiuzhang.aidcID ?? 0))]), aidcID: configuration.jiuzhang.aidcID ?? 0)
        }
        async let nodes = qPages(path: configuration.qianhai.poolRoot + "/acns", key: "acns")
        async let observations = get(configuration.qianhai.poolRoot + "/observe", query: [("page_size", "100"), ("page_token", "1")])
        let (nodeList, observed) = try await (nodes, observations)
        // /observe has nested observations.acns and pagination, unlike the node list.
        guard var meters = observed["observations"]["acns"].array else { throw CloudError.malformed("缺少节点资源观测") }
        var next = observed["next_page_token"].string ?? ""
        var tokens: Set<String> = ["1"]
        while !next.isEmpty {
            guard tokens.count < 100, tokens.insert(next).inserted else { throw CloudError.pagination }
            let page = try await get(configuration.qianhai.poolRoot + "/observe", query: [("page_size", "100"), ("page_token", next)])
            guard let items = page["observations"]["acns"].array, !items.isEmpty else { throw CloudError.pagination }
            meters += items; next = page["next_page_token"].string ?? ""
        }
        if let total = observed["total_size"].int, meters.count < total { throw CloudError.pagination }
        return try Parsing.qianhaiCapacity(nodes: nodeList, observations: meters)
    }

    public func jobs(filter: String) async throws -> [Job] {
        if platform == .qianhai {
            let rows = try await qPages(path: configuration.qianhai.taskRoot, key: "training_jobs")
            var jobs = try rows.filter {
                $0["resource_pool"]["name"].string == configuration.qianhai.pool && Parsing.matches($0["display_name"].string, filter: filter)
            }.map(Parsing.qianhaiJob)
            // Worker verification is limited to matching live tasks, four at a time.
            let live = jobs.indices.filter { [.running, .starting].contains(jobs[$0].state) }
            for start in stride(from: 0, to: live.count, by: 4) {
                let indices = Array(live[start..<min(start + 4, live.count)])
                let batch = indices.map { ($0, jobs[$0].nativeID) }
                let updates = await withTaskGroup(of: (Int, Int?).self, returning: [(Int, Int?)].self) { group in
                    for (index, id) in batch {
                        group.addTask {
                            do {
                                let workers = try await qPages(path: configuration.qianhai.taskRoot + "/" + Signing.encode(id) + "/workers", key: "workers")
                                return (index, Parsing.workerGPUs(workers))
                            } catch { return (index, nil) }
                        }
                    }
                    var values: [(Int, Int?)] = []
                    for await value in group { values.append(value) }
                    return values
                }
                for (index, count) in updates { jobs[index].allocatedGPUs = count }
            }
            try Task.checkCancellation()
            return Job.sorted(Array(Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest }).values))
        }
        var rows: [APIJSON] = [], seenPages: Set<String> = []
        for page in 1...100 {
            let json = try await get("/api/osm/v1/training/instance/list", query: [("pageNo", String(page)), ("pageSize", "100")])
            guard let items = json["records"].array, let total = json["totalRows"].int else { throw CloudError.malformed("任务分页") }
            let marker = items.compactMap { $0["id"].string }.joined(separator: ",")
            guard items.isEmpty || seenPages.insert(marker).inserted else { throw CloudError.pagination }
            rows += items
            if rows.count >= total {
                let jobs = try rows.filter { $0["aidcId"].int == configuration.jiuzhang.aidcID && Parsing.matches($0["name"].string, filter: filter) }.map(Parsing.jiuzhangJob)
                return Job.sorted(Array(Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest }).values))
            }
            if items.isEmpty { throw CloudError.pagination }
        }
        throw CloudError.pagination
    }
}

public enum Parsing {
    public static func matches(_ name: String?, filter: String) -> Bool {
        guard let name else { return false }
        return filter.isEmpty || name.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    public static func jiuzhangCapacity(_ json: APIJSON, aidcID: Int) throws -> Capacity {
        guard let rows = json.array else { throw CloudError.malformed("规格列表") }
        let specs = try rows.filter { $0["aidcId"].int == aidcID && ($0["gpuCount"].int ?? 0) > 0 }.map { row in
            let issue = row["ext"]["stockError"].string.flatMap { $0.isEmpty ? nil : $0 }
            return GPUSpec(id: try row.required("productCode"), model: row["gpuName"].string ?? "GPU", gpusPerInstance: row["gpuCount"].int!,
                           availableInstances: issue == nil ? row["remainingCount"].int.flatMap { $0 >= 0 ? $0 : nil } : nil,
                           availabilityNote: issue)
        }.sorted { $0.gpusPerInstance < $1.gpusPerInstance }
        // Never sum overlapping 1/2/4/8 GPU SKUs. A single 1-GPU SKU is the reference count.
        let singleGPU = specs.filter { $0.gpusPerInstance == 1 }
        let available = singleGPU.count == 1 ? singleGPU[0].availableInstances : nil
        return Capacity(availableGPUs: available, model: specs.first?.model ?? "GPU", specs: specs,
                        explanation: "按所选机房 1 卡规格库存显示卡数；各规格共享库存，不相加。此数值未验证节点是否可调度，CPU、内存、节点限制和任务配额仍可能阻止启动。")
    }
    public static func qianhaiCapacity(nodes: [APIJSON], observations: [APIJSON]) throws -> Capacity {
        var meters: [String: APIJSON] = [:]
        for meter in observations {
            let id = try meter.required("uid")
            guard meters.updateValue(meter, forKey: id) == nil else { throw CloudError.malformed("重复节点观测") }
        }
        var free = 0, total = 0, used = 0, models = Set<String>(), visited = Set<String>()
        for node in nodes {
            let id = try node.required("uid")
            guard visited.insert(id).inserted else { throw CloudError.malformed("重复节点") }
            let properties = node["properties"]
            guard node["deleted"].bool != true else { continue }
            let count = properties["resources"]["device"]["number"].int
            guard let count, count >= 0 else { throw CloudError.malformed("GPU 数量") }
            total += count
            if count > 0, let model = properties["resources"]["device"]["type"].string { models.insert(model) }
            guard node["state"].string == "ACTIVE", properties["available_status"].string == "ENABLED",
                  properties["status"].string == "READY", (properties["hardware_anomaly_info"].array ?? []).isEmpty else { continue }
            guard let meter = meters[id], let capacity = meter["capacity"]["device"].int,
                  let allocated = meter["allocated"]["device"].int, capacity >= 0, allocated >= 0 else {
                throw CloudError.malformed("节点观测不完整")
            }
            free += max(0, min(capacity, count) - allocated)
            used += allocated
        }
        return Capacity(availableGPUs: free, totalGPUs: total, allocatedGPUs: used,
                        model: models.sorted().joined(separator: " / "),
                        explanation: "ACP 集群健康、已启用节点的 GPU 未分配余量。实际调度还受 CPU、内存和节点碎片影响。")
    }
    private static func gpuLimit(_ json: APIJSON) -> Int? {
        guard let object = json.object else { return nil }
        let gpuKeys = object.keys.filter { $0 == "nvidia.com/gpu" || $0.hasPrefix("nvidia.com/gpu-") }
        if !gpuKeys.isEmpty {
            let values = gpuKeys.compactMap { object[$0]?.int }
            return values.count == gpuKeys.count ? values.reduce(0, +) : nil
        }
        return json["device"].int
    }
    public static func workerGPUs(_ rows: [APIJSON]) -> Int? {
        guard !rows.isEmpty else { return nil }
        var total = 0
        for worker in rows {
            // A terminal historical worker is not a currently allocated GPU.
            if ["Succeeded", "Failed"].contains(worker["phase"].string ?? "") { continue }
            guard worker["phase"].string == "Running", let containers = worker["containers"].array else { return nil }
            for container in containers {
                let limits = container["resources"]["limits"]
                guard let count = gpuLimit(limits), count >= 0 else { return nil }
                total += count
            }
        }
        return total
    }
    public static func qianhaiJob(_ row: APIJSON) throws -> Job {
        let roles = row["roles"].array ?? []
        var gpus = 0, nodes = 0, complete = !roles.isEmpty
        for role in roles {
            guard let replicas = role["total_replicas"].int, let specs = role["resource_spec"].array, !specs.isEmpty else { complete = false; continue }
            nodes += replicas
            for spec in specs {
                guard let count = gpuLimit(spec["limits"]), let copies = spec["replicas"].int ?? (specs.count == 1 ? replicas : nil) else { complete = false; continue }
                gpus += count * copies
            }
        }
        return Job(platform: .qianhai, nativeID: try row.required("name"), name: try row.required("display_name"), rawState: try row.required("state"),
                   requestedGPUs: complete ? gpus : nil, nodes: nodes > 0 ? nodes : nil,
                   createdAt: APIDates.parse(row["create_time"].string), startedAt: APIDates.parse(row["start_time"].string), endedAt: APIDates.parse(row["complete_time"].string),
                   reason: row["reason"].string ?? row["message"].string)
    }
    public static func jiuzhangJob(_ row: APIJSON) throws -> Job {
        let resource = row["resource"]
        let nodes = resource["workerCount"].int, perNode = resource["gpuCount"].int
        let total = nodes.flatMap { n in perNode.map { n * $0 } }
        return Job(platform: .jiuzhang, nativeID: try row.required("id"), name: try row.required("name"), rawState: try row.required("status"),
                   requestedGPUs: total, nodes: nodes, gpuModel: resource["gpuName"].string,
                   createdAt: APIDates.parse(row["createdTime"].string, beijing: true), startedAt: APIDates.parse(row["startTime"].string, beijing: true),
                   endedAt: APIDates.parse(row["endTime"].string ?? row["finishTime"].string, beijing: true),
                   reason: row["reason"].string ?? row["message"].string)
    }
}
