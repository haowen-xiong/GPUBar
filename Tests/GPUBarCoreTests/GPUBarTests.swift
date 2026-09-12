import Foundation
import GPUBarCore

private func json(_ value: Any) throws -> APIJSON {
    try APIJSON.decode(JSONSerialization.data(withJSONObject: value))
}
private func response(_ value: Any, status: Int = 200) throws -> (Data, Int) {
    (try JSONSerialization.data(withJSONObject: value), status)
}
private let testCredentials = Credentials(accessKey: "example-access-key", secretKey: "secret")

private let testConfiguration: MonitoringConfiguration = {
    var config = MonitoringConfiguration()
    config.qianhai.subscriptionID = "example-subscription"
    config.qianhai.resourceGroup = "example-group"
    config.qianhai.nodeZone = "example-node-zone"
    config.qianhai.taskZone = "example-task-zone"
    config.qianhai.pool = "example-pool"
    config.qianhai.workspace = "example-workspace"
    config.jiuzhang.aidcID = 7
    return config
}()

@MainActor final class GPUBarTests {
    func testSenseCoreSignatureMatchesExistingVerifiedFixture() {
        let auth = Signing.qianhai(credentials: testCredentials, path: "/requests", date: "Thu, 22 Jun 2017 17:15:21 GMT")
        XCTAssertEqual(auth, "hmac accesskey=\"example-access-key\", algorithm=\"hmac-sha256\", headers=\"x-date request-line\", signature=\"IXlgb2baHcvPrV7a/C+hKS+E5oHIQXXyz4k4maWws50=\"")
        XCTAssertNotEqual(Signing.qianhai(credentials: testCredentials, path: "/requests?a=1&b=2", date: "fixed"), Signing.qianhai(credentials: testCredentials, path: "/requests?b=2&a=1", date: "fixed"))
    }
    func testJiuzhangSignsTimestampAndPath() {
        let credentials = Credentials(accessKey: "test-access", secretKey: "test-secret")
        XCTAssertEqual(Signing.jiuzhang(credentials: credentials, path: "/api/osm/v1/product/list-for-training-task", milliseconds: 123456),
                       "alayanew-HMAC-SHA256 test-access:123456:" + "75b861affb0513a335904a768af94f065b1fe0eb2fe980b5223883b151db639b")
    }
    func testDateParsingRespectsPlatformTimezones() {
        XCTAssertEqual(APIDates.parse("2026-09-12 08:00:00", beijing: true), APIDates.parse("2026-09-12T00:00:00Z"))
        XCTAssertNotNil(APIDates.parse("2026-09-12T00:00:00.123456Z"))
        XCTAssertNil(APIDates.parse("invalid"))
        XCTAssertNil(APIDates.parse("2026-09-12 08:00:00"))
    }
    func testNameFilterIgnoresCaseAndDoesNotSearchOtherFields() {
        XCTAssertTrue(Parsing.matches("experiment-DEMO-eval", filter: "demo"))
        XCTAssertFalse(Parsing.matches("unrelated", filter: "demo"))
        XCTAssertFalse(Parsing.matches(nil, filter: "demo"))
    }
    func testJiuzhangInventoryDoesNotSumSharedSKUsOrOtherRegions() throws {
        let specs: [[String: Any]] = [
            ["aidcId": 7, "productCode": "gpu1", "gpuCount": "1", "gpuName": "H800A", "remainingCount": 37],
            ["aidcId": 7, "productCode": "gpu8", "gpuCount": "8", "gpuName": "H800A", "remainingCount": 4],
            ["aidcId": 99, "productCode": "other", "gpuCount": "1", "remainingCount": 1000]
        ]
        let capacity = try Parsing.jiuzhangCapacity(json(specs), aidcID: 7)
        XCTAssertEqual(capacity.availableGPUs, 37)
        XCTAssertEqual(capacity.specs.count, 2)
        XCTAssertNil(capacity.totalGPUs)
    }
    func testMissingInventoryIsUnknownNotZero() throws {
        let capacity = try Parsing.jiuzhangCapacity(json([["aidcId": 7, "productCode": "gpu8", "gpuCount": "8"]]), aidcID: 7)
        XCTAssertNil(capacity.availableGPUs)
        XCTAssertNil(capacity.specs[0].availableInstances)
    }
    func node(_ id: String, enabled: Bool = true, healthy: Bool = true) -> [String: Any] {
        ["uid": id, "state": "ACTIVE", "deleted": false, "properties": [
            "available_status": enabled ? "ENABLED" : "DISABLED", "status": healthy ? "READY" : "NOT_READY",
            "hardware_anomaly_info": [], "resources": ["device": ["number": 8, "type": "H800"]]
        ]]
    }
    func testQianhaiCountsOnlyHealthyEnabledNodeHeadroom() throws {
        let nodes = try [node("good"), node("disabled", enabled: false), node("bad", healthy: false)].map(json)
        let meters = try [["uid": "good", "capacity": ["device": "8"], "allocated": ["device": "2"]]].map(json)
        let capacity = try Parsing.qianhaiCapacity(nodes: nodes, observations: meters)
        XCTAssertEqual(capacity.availableGPUs, 6)
        XCTAssertEqual(capacity.totalGPUs, 24)
    }
    func testMissingObservationFailsInsteadOfInventingFreeResources() throws {
        XCTAssertThrowsError(try Parsing.qianhaiCapacity(nodes: [json(node("missing"))], observations: []))
    }
    func testGPUAliasLimitsAreNotDoubleCounted() throws {
        let workers = try json([["phase": "Running", "containers": [["resources": ["limits": ["device": "8", "nvidia.com/gpu": "8"]]]]]]).array!
        XCTAssertEqual(Parsing.workerGPUs(workers), 8)
        XCTAssertNil(Parsing.workerGPUs(try json([["phase": "Pending", "containers": []]]).array!))
    }
    func testMultiNodeRequestUsesTotalReplicas() throws {
        let row: [String: Any] = ["name": "task", "display_name": "demo-test", "state": "QUEUEING", "roles": [[
            "total_replicas": 4, "resource_spec": [["limits": ["device": "8", "nvidia.com/gpu": "8"]]]
        ]]]
        let job = try Parsing.qianhaiJob(json(row))
        XCTAssertEqual(job.requestedGPUs, 32)
        XCTAssertNil(job.allocatedGPUs)
        XCTAssertEqual(job.nodes, 4)
    }
    func testUnknownStateAndSuspensionAreNotCompletion() {
        XCTAssertEqual(JobState(raw: "new-platform-state"), .unknown)
        let unknown = Job(platform: .jiuzhang, nativeID: "unknown-state", name: "demo", rawState: "NotStarted", startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(unknown.elapsed(), "运行时间未知")
        XCTAssertFalse(JobState(raw: "SUSPENDED").terminal)
        XCTAssertFalse(JobState(raw: "Starting").terminal)
        XCTAssertTrue(JobState(raw: "Succeeded").terminal)
    }
    func testFinishedJobsDoNotContinueAccumulatingRuntime() {
        let start = Date(timeIntervalSince1970: 1000)
        let job = Job(platform: .qianhai, nativeID: "x", name: "demo", rawState: "SUCCEEDED", startedAt: start, endedAt: start.addingTimeInterval(7200))
        XCTAssertEqual(job.elapsed(now: start.addingTimeInterval(100000)), "用时 2h 0m")
        let unknownEnd = Job(platform: .jiuzhang, nativeID: "y", name: "demo", rawState: "Succeeded", startedAt: start)
        XCTAssertEqual(unknownEnd.elapsed(now: Date()), "运行时间未知")
    }
    func testQianhaiPaginationAndPoolFilter() async throws {
        let mock = MockTransport(responses: [
            try response(["training_jobs": [qJob("a", "DEMO-a")], "next_page_token": "2", "total_size": 3]),
            try response(["training_jobs": [qJob("b", "demo-b"), qJob("c", "demo-other-pool", pool: "other")], "next_page_token": "", "total_size": 3])
        ])
        let api = CloudAPI(platform: .qianhai, credentials: testCredentials, configuration: testConfiguration, transport: { try await mock.send($0) })
        let jobs = try await api.jobs(filter: "demo")
        XCTAssertEqual(Set(jobs.map(\.nativeID)), ["a", "b"])
        let requests = await mock.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url!.path, "/compute/acp/data/v2/subscriptions/example-subscription/resourceGroups/example-group/zones/example-task-zone/workspaces/example-workspace/trainingJobs")
        XCTAssertTrue(requests[1].url!.absoluteString.contains("page_token=2"))
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        for request in requests {
            let url = request.url!
            let signedPath = url.path + "?" + url.query!
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), Signing.qianhai(credentials: testCredentials, path: signedPath, date: request.value(forHTTPHeaderField: "X-Date")!))
        }
    }
    func testRepeatedOrIncompletePagesAreErrors() async throws {
        for payloads in [
            [["training_jobs": [qJob("a", "demo")], "next_page_token": "1", "total_size": 2]],
            [["training_jobs": [qJob("a", "demo")], "next_page_token": "", "total_size": 2]]
        ] {
            let mock = MockTransport(responses: try payloads.map { try response($0) })
            do {
                _ = try await CloudAPI(platform: .qianhai, credentials: testCredentials, configuration: testConfiguration, transport: { try await mock.send($0) }).jobs(filter: "demo")
                XCTFail("Incomplete pagination must fail")
            } catch { XCTAssertTrue(error is CloudError) }
        }
    }
    func testJiuzhangFiltersConfiguredRegionAndSignsPathWithoutQuery() async throws {
        let rows: [[String: Any]] = [
            ["id": "a", "name": "demo-yes", "aidcId": 7, "status": "Running"],
            ["id": "b", "name": "demo-other", "aidcId": 12, "status": "Running"],
            ["id": "c", "name": "colleague", "aidcId": 7, "status": "Running"]
        ]
        let mock = MockTransport(responses: [try response(["status": 200, "data": ["records": rows, "totalRows": 3]])])
        let jobs = try await CloudAPI(platform: .jiuzhang, credentials: testCredentials, configuration: testConfiguration, transport: { try await mock.send($0) }).jobs(filter: "demo")
        XCTAssertEqual(jobs.map(\.nativeID), ["a"])
        let request = await mock.requests[0]
        let authorization = request.value(forHTTPHeaderField: "Authorization")!
        let timestamp = Int64(authorization.split(separator: ":")[1])!
        XCTAssertEqual(authorization, Signing.jiuzhang(credentials: testCredentials, path: request.url!.path, milliseconds: timestamp))
    }
    func testHTTPFailuresDoNotLeakResponseOrCredentials() async throws {
        let mock = MockTransport(responses: [(Data("secret-server-message".utf8), 403)])
        do {
            _ = try await CloudAPI(platform: .jiuzhang, credentials: testCredentials, configuration: testConfiguration, transport: { try await mock.send($0) }).capacity()
            XCTFail("403 must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("secret-server-message"))
            XCTAssertTrue(error.localizedDescription.contains("403"))
        }
    }
    func testUnconfiguredPlatformsCannotSendRequests() async throws {
        let config = MonitoringConfiguration()
        for platform in Platform.allCases {
            XCTAssertFalse(config.isConfigured(platform))
            let mock = MockTransport(responses: [])
            let api = CloudAPI(platform: platform, credentials: testCredentials, configuration: config, transport: { try await mock.send($0) })
            do { _ = try await api.capacity(); XCTFail("Unconfigured capacity must fail") }
            catch { XCTAssertTrue(error is ConfigurationError) }
            do { _ = try await api.jobs(filter: ""); XCTFail("Unconfigured jobs must fail") }
            catch { XCTAssertTrue(error is ConfigurationError) }
            let requests = await mock.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }
    func testIdentifiersCannotEscapeTheirResourcePath() throws {
        for invalid in ["../other", "pool/other", "pool?admin=true", "pool#other", "pool%2Fother", "pool\nother"] {
            var config = testConfiguration
            config.qianhai.pool = invalid
            XCTAssertThrowsError(try config.validate(.qianhai))
        }
        var config = testConfiguration
        config.qianhai.pool = "  example-pool  "
        XCTAssertEqual(config.normalized().qianhai.pool, "example-pool")
        try config.normalized().validate(.qianhai)
        config.jiuzhang.aidcID = 0
        XCTAssertThrowsError(try config.validate(.jiuzhang))
    }
    func testScopeChangesInvalidateCacheIdentity() {
        var config = testConfiguration
        let qKey = config.cacheKey(.qianhai), jKey = config.cacheKey(.jiuzhang)
        config.qianhai.workspace = "other-workspace"
        XCTAssertNotEqual(config.cacheKey(.qianhai), qKey)
        XCTAssertEqual(config.cacheKey(.jiuzhang), jKey)
        config.jiuzhang.regionName = "Display label"
        XCTAssertEqual(config.cacheKey(.jiuzhang), jKey)
        config.jiuzhang.aidcID = 8
        XCTAssertNotEqual(config.cacheKey(.jiuzhang), jKey)
    }
    func testJiuzhangCapacityQueriesConfiguredRegion() async throws {
        let mock = MockTransport(responses: [try response(["status": 200, "data": [
            ["aidcId": 7, "productCode": "example-single", "gpuCount": "1", "remainingCount": 5],
            ["aidcId": 11, "productCode": "other-single", "gpuCount": "1", "remainingCount": 99]
        ]])])
        let api = CloudAPI(platform: .jiuzhang, credentials: testCredentials, configuration: testConfiguration, transport: { try await mock.send($0) })
        let capacity = try await api.capacity()
        XCTAssertEqual(capacity.availableGPUs, 5)
        let request = await mock.requests[0]
        XCTAssertEqual(request.url!.query, "aidcId=7")
    }
    func testInventoryErrorCannotBePresentedAsAvailable() throws {
        let capacity = try Parsing.jiuzhangCapacity(json([
            ["aidcId": 7, "productCode": "gpu1", "gpuCount": "1", "remainingCount": 37, "ext": ["stockError": "Inventory unavailable"]]
        ]), aidcID: 7)
        XCTAssertNil(capacity.availableGPUs)
        XCTAssertNil(capacity.specs[0].availableInstances)
        XCTAssertEqual(capacity.specs[0].availabilityNote, "Inventory unavailable")
    }
    private func qJob(_ id: String, _ name: String, pool: String = "example-pool") -> [String: Any] {
        ["name": id, "display_name": name, "state": "SUCCEEDED", "resource_pool": ["name": pool]]
    }
}

actor MockTransport {
    var responses: [(Data, Int)]
    var requests: [URLRequest] = []
    init(responses: [(Data, Int)]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, Int) {
        requests.append(request)
        guard !responses.isEmpty else { throw CloudError.network }
        return responses.removeFirst()
    }
}

@MainActor private var failures = 0
@MainActor private func check(_ condition: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if !condition { failures += 1; print("FAIL \(file):\(line) \(message)") }
}
@MainActor private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a == b, "\(a) != \(b)", file: file, line: line) }
@MainActor private func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a != b, file: file, line: line) }
@MainActor private func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { check(value, file: file, line: line) }
@MainActor private func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { check(!value, file: file, line: line) }
@MainActor private func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { check(value == nil, file: file, line: line) }
@MainActor private func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { check(value != nil, file: file, line: line) }
@MainActor private func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { check(false, message, file: file, line: line) }
@MainActor private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); check(false, "Expected error", file: file, line: line) } catch {}
}
@main struct Checks {
    @MainActor static func run(_ name: String, body: () async throws -> Void) async {
        let before = failures
        do { try await body() } catch { XCTFail("\(name): \(error)") }
        print("\(failures == before ? "PASS" : "FAIL") \(name)")
    }
    @MainActor static func main() async {
        let suite = GPUBarTests()
        await run("testSenseCoreSignatureMatchesExistingVerifiedFixture") { suite.testSenseCoreSignatureMatchesExistingVerifiedFixture() }
        await run("testJiuzhangSignsTimestampAndPath") { suite.testJiuzhangSignsTimestampAndPath() }
        await run("testDateParsingRespectsPlatformTimezones") { suite.testDateParsingRespectsPlatformTimezones() }
        await run("testNameFilterIgnoresCaseAndDoesNotSearchOtherFields") { suite.testNameFilterIgnoresCaseAndDoesNotSearchOtherFields() }
        await run("testJiuzhangInventoryDoesNotSumSharedSKUsOrOtherRegions") { try suite.testJiuzhangInventoryDoesNotSumSharedSKUsOrOtherRegions() }
        await run("testMissingInventoryIsUnknownNotZero") { try suite.testMissingInventoryIsUnknownNotZero() }
        await run("testQianhaiCountsOnlyHealthyEnabledNodeHeadroom") { try suite.testQianhaiCountsOnlyHealthyEnabledNodeHeadroom() }
        await run("testMissingObservationFailsInsteadOfInventingFreeResources") { try suite.testMissingObservationFailsInsteadOfInventingFreeResources() }
        await run("testGPUAliasLimitsAreNotDoubleCounted") { try suite.testGPUAliasLimitsAreNotDoubleCounted() }
        await run("testMultiNodeRequestUsesTotalReplicas") { try suite.testMultiNodeRequestUsesTotalReplicas() }
        await run("testUnknownStateAndSuspensionAreNotCompletion") { suite.testUnknownStateAndSuspensionAreNotCompletion() }
        await run("testFinishedJobsDoNotContinueAccumulatingRuntime") { suite.testFinishedJobsDoNotContinueAccumulatingRuntime() }
        await run("testQianhaiPaginationAndPoolFilter") { try await suite.testQianhaiPaginationAndPoolFilter() }
        await run("testRepeatedOrIncompletePagesAreErrors") { try await suite.testRepeatedOrIncompletePagesAreErrors() }
        await run("testJiuzhangFiltersConfiguredRegionAndSignsPathWithoutQuery") { try await suite.testJiuzhangFiltersConfiguredRegionAndSignsPathWithoutQuery() }
        await run("testHTTPFailuresDoNotLeakResponseOrCredentials") { try await suite.testHTTPFailuresDoNotLeakResponseOrCredentials() }
        await run("testUnconfiguredPlatformsCannotSendRequests") { try await suite.testUnconfiguredPlatformsCannotSendRequests() }
        await run("testIdentifiersCannotEscapeTheirResourcePath") { try suite.testIdentifiersCannotEscapeTheirResourcePath() }
        await run("testScopeChangesInvalidateCacheIdentity") { suite.testScopeChangesInvalidateCacheIdentity() }
        await run("testJiuzhangCapacityQueriesConfiguredRegion") { try await suite.testJiuzhangCapacityQueriesConfiguredRegion() }
        await run("testInventoryErrorCannotBePresentedAsAvailable") { try suite.testInventoryErrorCannotBePresentedAsAvailable() }
        print("21 checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
