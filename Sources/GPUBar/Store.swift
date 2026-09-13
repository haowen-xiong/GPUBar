import Foundation
import Network
import SwiftUI
import AppKit
import UserNotifications
import GPUBarCore

enum RefreshSection: Sendable {
    case capacity(Capacity), jobs([Job]), failure(String, String)
}

@MainActor
final class AppStore: ObservableObject {
    @Published var snapshots: [Platform: Snapshot] = [:]
    @Published var errors: [Platform: [String: String]] = [:]
    @Published var refreshing: Set<Platform> = []
    @Published var configured: Set<Platform> = []
    @Published var configuration: MonitoringConfiguration
    @Published var filter: String
    @Published var interval: Double
    @Published var notifications: Bool
    @Published var runningOnly: Bool {
        didSet {
            if !preview { UserDefaults.standard.set(runningOnly, forKey: "runningJobsOnly") }
        }
    }
    @Published var notice: String?
    let preview: Bool
    private var tasks: [Platform: Task<Void, Never>] = [:]
    private var timer: Task<Void, Never>?
    private var generations: [Platform: Int] = [:]
    private var nextRefresh: [Platform: Date] = [:]
    private var failures: [Platform: Int] = [:]
    private var initializedJobs: Set<Platform> = []
    private var notified: Set<String> = []
    private var sleeping = false
    private let networkMonitor = NWPathMonitor()
    private var networkWasAvailable: Bool?
    private var observers: [NSObjectProtocol] = []
    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GPUBar/snapshots.json")
    }

    init(preview: Bool = false) {
        self.preview = preview
        let defaults = UserDefaults.standard
        self.configuration = Preferences.configuration()
        self.filter = defaults.string(forKey: "nameFilter") ?? ""
        let saved = defaults.double(forKey: "refreshInterval")
        self.interval = [30.0, 60, 120, 300].contains(saved) ? saved : 60
        self.notifications = defaults.bool(forKey: "notifyOnCompletion")
        self.runningOnly = preview ? false : defaults.bool(forKey: "runningJobsOnly")
        if preview { loadPreview(); return }
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode([Platform: Snapshot].self, from: data) {
            snapshots = cache
            for p in Platform.allCases {
                if snapshots[p]?.scopeID != configuration.cacheKey(p) { snapshots[p] = Snapshot() }
                if snapshots[p]?.filter != filter { snapshots[p]?.jobs = []; snapshots[p]?.jobsAt = nil }
            }
        }
        reloadCredentials()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        })
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let recovered = self.networkWasAvailable == false && available
                self.networkWasAvailable = available
                if recovered { self.refreshAll() }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.haowen.GPUBar.network"))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func reloadCredentials() {
        configured = []
        for platform in Platform.allCases {
            do {
                if let value = try Keychain.load(platform), value.isValid { configured.insert(platform) }
            } catch { errors[platform] = ["credentials": error.localizedDescription] }
        }
    }
    func opened() {
        guard !preview else { return }
        for platform in configured {
            if Date().timeIntervalSince(snapshots[platform]?.capacityAt ?? .distantPast) > 15 || Date().timeIntervalSince(snapshots[platform]?.jobsAt ?? .distantPast) > 15 {
                refresh(platform)
            }
        }
    }
    func refreshAll() { for platform in Platform.allCases { refresh(platform) } }
    private func tick() {
        guard !sleeping, !preview else { return }
        for platform in configured where configuration.isConfigured(platform) && Date() >= (nextRefresh[platform] ?? .distantPast) { refresh(platform) }
    }
    func stale(_ platform: Platform, section: String = "capacity") -> Bool {
        let date = section == "capacity" ? snapshots[platform]?.capacityAt : snapshots[platform]?.jobsAt
        return errors[platform]?[section] != nil || errors[platform]?["credentials"] != nil || errors[platform]?["configuration"] != nil || Date().timeIntervalSince(date ?? .distantPast) > max(interval * 2, 120)
    }
    func refresh(_ platform: Platform) {
        guard !preview, !sleeping, tasks[platform] == nil else { return }
        do { try configuration.validate(platform) }
        catch { errors[platform] = ["configuration": error.localizedDescription]; return }
        let credentials: Credentials
        do {
            guard let value = try Keychain.load(platform), value.isValid else {
                errors[platform] = ["credentials": CloudError.credentials.localizedDescription]; return
            }
            credentials = value; configured.insert(platform)
        } catch { errors[platform] = ["credentials": error.localizedDescription]; return }
        let generation = generations[platform, default: 0]
        let currentFilter = filter
        let api = CloudAPI(platform: platform, credentials: credentials, configuration: configuration)
        let scopeID = configuration.cacheKey(platform)
        refreshing.insert(platform)
        tasks[platform] = Task { [weak self] in
            var anyError = false
            await withTaskGroup(of: RefreshSection.self) { group in
                group.addTask {
                    do { return .capacity(try await api.capacity()) }
                    catch { return .failure("capacity", error.localizedDescription) }
                }
                group.addTask {
                    do { return .jobs(try await api.jobs(filter: currentFilter)) }
                    catch { return .failure("jobs", error.localizedDescription) }
                }
                for await result in group {
                    guard !Task.isCancelled, let self, self.generations[platform, default: 0] == generation else { continue }
                    var snapshot = self.snapshots[platform] ?? Snapshot()
                    var issue = self.errors[platform] ?? [:]
                    issue.removeValue(forKey: "credentials")
                    issue.removeValue(forKey: "configuration")
                    snapshot.scopeID = scopeID
                    switch result {
                    case .capacity(let capacity):
                        snapshot.capacity = capacity; snapshot.capacityAt = Date(); issue.removeValue(forKey: "capacity")
                    case .jobs(let jobs):
                        self.notifyTransitions(platform, previous: snapshot.jobs, current: jobs)
                        snapshot.jobs = jobs; snapshot.jobsAt = Date(); snapshot.filter = currentFilter; issue.removeValue(forKey: "jobs")
                    case .failure(let section, let message):
                        issue[section] = message; anyError = true
                    }
                    self.snapshots[platform] = snapshot; self.errors[platform] = issue
                    self.saveCache()
                }
            }
            guard let self, self.generations[platform, default: 0] == generation else { return }
            self.tasks[platform] = nil; self.refreshing.remove(platform)
            self.failures[platform] = anyError ? min(self.failures[platform, default: 0] + 1, 4) : 0
            let delay = min(900, self.interval * pow(2, Double(self.failures[platform, default: 0])))
            self.nextRefresh[platform] = Date().addingTimeInterval(delay)
        }
    }
    private func invalidate(_ platform: Platform) {
        generations[platform, default: 0] += 1
        tasks[platform]?.cancel(); tasks[platform] = nil
        refreshing.remove(platform); nextRefresh[platform] = .distantPast; failures[platform] = 0
    }
    func apply(configuration: MonitoringConfiguration, filter: String, interval: Double) throws {
        let normalized = configuration.normalized()
        if !normalized.qianhai.subscriptionID.isEmpty || !normalized.qianhai.pool.isEmpty || !normalized.qianhai.workspace.isEmpty {
            try normalized.validate(.qianhai)
        }
        if normalized.jiuzhang.aidcID != nil || !normalized.jiuzhang.regionName.isEmpty { try normalized.validate(.jiuzhang) }
        try Preferences.save(normalized)
        let previousConfiguration = self.configuration
        self.configuration = normalized
        let changed = self.filter != filter.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        self.interval = interval
        UserDefaults.standard.set(self.filter, forKey: "nameFilter")
        UserDefaults.standard.set(interval, forKey: "refreshInterval")
        for platform in Platform.allCases {
            invalidate(platform)
            if previousConfiguration.cacheKey(platform) != normalized.cacheKey(platform) {
                snapshots[platform] = Snapshot(); errors[platform] = [:]; initializedJobs.remove(platform)
            } else if changed {
                snapshots[platform]?.jobs = []; snapshots[platform]?.jobsAt = nil
                snapshots[platform]?.filter = self.filter; initializedJobs.remove(platform)
            }
        }
        saveCache(); refreshAll()
    }
    func saveCredentials(platform: Platform, key: String, secret: String) throws {
        try Keychain.save(Credentials(accessKey: key, secretKey: secret), platform: platform)
        invalidate(platform)
        snapshots[platform] = Snapshot(); errors[platform] = [:]; initializedJobs.remove(platform)
        configured.insert(platform); saveCache(); refresh(platform)
    }
    func removeCredentials(_ platform: Platform) throws {
        try Keychain.delete(platform); invalidate(platform)
        configured.remove(platform); snapshots.removeValue(forKey: platform); errors.removeValue(forKey: platform)
        initializedJobs.remove(platform); saveCache()
    }
    func setNotifications(_ value: Bool) {
        if !value {
            notifications = false; UserDefaults.standard.set(false, forKey: "notifyOnCompletion"); return
        }
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notifications = granted; UserDefaults.standard.set(granted, forKey: "notifyOnCompletion")
                if !granted { notice = "通知权限未开启，可在系统设置中允许 GPUBar 通知。" }
            } catch { notice = "暂时无法开启通知。" }
        }
    }
    private func notifyTransitions(_ platform: Platform, previous: [Job], current: [Job]) {
        defer { initializedJobs.insert(platform) }
        guard notifications, initializedJobs.contains(platform) else { return }
        let old = Dictionary(previous.map { ($0.id, $0.state) }, uniquingKeysWith: { _, new in new })
        for job in current where [.succeeded, .failed].contains(job.state) {
            guard let prior = old[job.id], !prior.terminal else { continue }
            let event = job.id + ":" + job.rawState
            guard notified.insert(event).inserted else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(platform.title) · \(job.state.title)"
            content.body = job.name
            let request = UNNotificationRequest(identifier: event, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }
    private func saveCache() {
        guard !preview else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch { /* In-memory data remains available if disk persistence fails. */ }
    }
    private func sleep() {
        sleeping = true
        for platform in Platform.allCases { invalidate(platform) }
    }
    private func wake() { sleeping = false; refreshAll() }
    private func loadPreview() {
        configured = Set(Platform.allCases)
        configuration = MonitoringConfiguration()
        filter = "demo"
        configuration.qianhai.subscriptionID = "example-subscription"
        configuration.qianhai.pool = "example-pool"
        configuration.qianhai.workspace = "example-workspace"
        configuration.jiuzhang.aidcID = 1
        configuration.jiuzhang.regionName = "示例机房"
        var q = Snapshot()
        q.capacity = Capacity(availableGPUs: 16, totalGPUs: 136, allocatedGPUs: 120, model: "H800", explanation: "ACP 健康节点的 GPU 未分配余量。")
        q.capacityAt = Date(); q.jobsAt = Date()
        q.jobs = [Job(platform: .qianhai, nativeID: "demo-train", name: "demo-model-train", rawState: "RUNNING", requestedGPUs: 8, allocatedGPUs: 8, nodes: 1, createdAt: Date().addingTimeInterval(-8500), startedAt: Date().addingTimeInterval(-8000)),
                  Job(platform: .qianhai, nativeID: "demo-eval", name: "demo-model-eval", rawState: "QUEUEING", requestedGPUs: 4, nodes: 1, createdAt: Date().addingTimeInterval(-720))]
        var j = Snapshot()
        j.capacity = Capacity(availableGPUs: 37, model: "H800A · 80 GB", specs: [1,2,4,8].map { GPUSpec(id: "demo-\($0)", model: "H800A", gpusPerInstance: $0, availableInstances: 37 / $0) }, explanation: "示例机房库存；不同规格共享资源，不相加。")
        j.capacityAt = Date(); j.jobsAt = Date()
        snapshots = [.qianhai: q, .jiuzhang: j]
    }
}
