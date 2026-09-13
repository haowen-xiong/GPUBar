import SwiftUI
import AppKit
import ServiceManagement
import GPUBarCore

extension Platform {
    var tint: Color { self == .qianhai ? Color(red: 0.13, green: 0.48, blue: 0.88) : Color(red: 0.45, green: 0.36, blue: 0.82) }
}
extension JobState {
    var color: Color {
        switch self {
        case .running, .succeeded: .green
        case .queued, .starting: .orange
        case .failed: .red
        default: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .running: "play.circle.fill"
        case .queued: "clock"
        case .starting: "circle.dotted"
        case .suspended: "pause.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .canceled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

struct MenuLabel: View {
    @ObservedObject var store: AppStore
    private var platforms: [Platform] {
        Platform.allCases.filter { store.configured.contains($0) && store.configuration.isConfigured($0) }
    }
    private var title: String {
        platforms.map { platform in
            let value = store.snapshots[platform]?.capacity?.availableGPUs.map(String.init) ?? "—"
            return "\(platform.abbreviation) \(value)"
        }.joined(separator: " · ")
    }
    var body: some View {
        if platforms.isEmpty {
            Image(systemName: "square.stack.3d.up.fill")
                .accessibilityLabel("GPUBar")
                .help("GPUBar：点击配置平台")
        } else {
            // Keep all platforms in one Text for native status-item extraction.
            Text(title)
                .monospacedDigit()
                .fixedSize()
                .opacity(platforms.contains { store.stale($0) } ? 0.55 : 1)
                .accessibilityLabel("GPUBar GPU 资源摘要：\(title)")
                .help("GPUBar：点击查看资源与任务")
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: AppStore
    @State private var selected = "overview"
    @State private var selectedJob: Job?
    @Environment(\.openWindow) private var openWindow
    private var platforms: [Platform] { selected == "overview" ? Platform.allCases : Platform.allCases.filter { $0.rawValue == selected } }
    private var recentJobs: [Job] {
        Array(platforms.flatMap { store.snapshots[$0]?.jobs ?? [] }
            .filter { !store.runningOnly || $0.state == .running }.sorted {
            let left = $0.createdAt ?? .distantPast
            let right = $1.createdAt ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }.prefix(10))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 17)).foregroundStyle(.secondary)
                Text("GPUBar").font(.system(size: 17, weight: .semibold))
                if store.preview { Text("预览").font(.caption).foregroundStyle(.orange) }
                Spacer()
                if !store.refreshing.isEmpty { ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 18) }
                Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("立即刷新").accessibilityLabel("立即刷新")
            }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 13)
            Picker("平台", selection: $selected) {
                Text("总览").tag("overview")
                ForEach(Platform.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(platforms) { platform in
                        CapacityCard(platform: platform, store: store, expanded: selected != "overview")
                    }
                    HStack {
                        Text("最近任务").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("仅运行中", isOn: $store.runningOnly)
                            .toggleStyle(.checkbox).controlSize(.small)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.top, 4).padding(.horizontal, 2)
                    ForEach(platforms) { platform in
                        if let error = store.errors[platform]?["jobs"] {
                            Label("\(platform.title)：\(error)", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if recentJobs.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark.circle").font(.system(size: 23)).foregroundStyle(.tertiary)
                            Text(emptyTitle).font(.system(size: 12, weight: .medium))
                            Text(emptySubtitle).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 17)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(recentJobs) { job in
                                Button { selectedJob = job } label: { JobRow(job: job, stale: store.stale(job.platform, section: "jobs")) }
                                    .buttonStyle(.plain)
                                if job.id != recentJobs.last?.id { Divider().padding(.leading, 37) }
                            }
                        }.background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(.horizontal, 16).padding(.bottom, 14)
            }.frame(height: 520)
            Divider()
            HStack {
                Button { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) } label: { Label("设置", systemImage: "gearshape") }
                    .buttonStyle(.borderless)
                Spacer()
                Text("每 \(Int(store.interval)) 秒刷新").foregroundStyle(.tertiary)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless).help("退出 GPUBar").accessibilityLabel("退出 GPUBar")
            }.font(.system(size: 11)).padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 392)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.opened() }
        .sheet(item: $selectedJob) { job in JobDetail(job: job, scope: store.configuration.scope(job.platform)) }
    }
    private var emptyTitle: String {
        if platforms.allSatisfy({ !store.configured.contains($0) }) { return "连接平台以查看任务" }
        if platforms.allSatisfy({ store.snapshots[$0]?.jobsAt == nil }) { return store.refreshing.isEmpty ? "尚未获取任务" : "正在读取任务…" }
        if platforms.contains(where: { store.errors[$0]?["jobs"] != nil }) { return "任务查询未完成" }
        return store.runningOnly ? "没有运行中的任务" : "没有匹配的任务"
    }
    private var emptySubtitle: String {
        if platforms.allSatisfy({ !store.configured.contains($0) }) { return "在设置中连接要查看的平台。" }
        return store.runningOnly ? "取消勾选可查看其他状态的任务。" : "可在设置中调整任务筛选。"
    }
}

struct CapacityCard: View {
    let platform: Platform
    @ObservedObject var store: AppStore
    let expanded: Bool
    @Environment(\.openWindow) private var openWindow
    private var snapshot: Snapshot { store.snapshots[platform] ?? Snapshot() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    Text(platform.abbreviation).font(.system(size: 12, weight: .bold)).foregroundStyle(platform.tint)
                        .frame(width: 25, height: 25).background(platform.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(platform.title).font(.system(size: 13, weight: .semibold))
                        Text(store.configuration.scope(platform)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let date = snapshot.capacityAt {
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Text(date, style: .relative).font(.system(size: 10)).foregroundStyle(store.stale(platform) ? .orange : .secondary)
                    }.help("上次资源更新：\(date.formatted())")
                }
            }
            if store.configured.contains(platform) || snapshot.capacity != nil {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(snapshot.capacity?.availableGPUs.map(String.init) ?? "—")
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(store.stale(platform) ? .secondary : .primary)
                    Text(platform == .jiuzhang ? "GPU 库存参考" : "GPU 未分配").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(modelLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                if let free = snapshot.capacity?.availableGPUs, let total = snapshot.capacity?.totalGPUs, total > 0 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(platform.tint.opacity(0.10))
                            Capsule().fill(platform.tint.opacity(store.stale(platform) ? 0.35 : 0.85))
                                .frame(width: max(0, geometry.size.width * min(1, max(0, Double(free) / Double(total)))))
                        }
                    }.frame(height: 5).accessibilityLabel("总量 \(total) GPU，未分配 \(free) GPU")
                    Text("总量 \(total) · 健康节点未分配 \(free)").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if let specs = snapshot.capacity?.specs, !specs.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(specs) { spec in
                            VStack(spacing: 3) {
                                Text("\(spec.gpusPerInstance) 卡规格").foregroundStyle(.secondary)
                                Text(spec.availableInstances.map { "\($0) 份" } ?? (spec.availabilityNote == nil ? "—" : "异常")).fontWeight(.medium)
                                    .help(spec.availabilityNote ?? "规格库存份数")
                            }.font(.system(size: 10)).frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(platform.tint.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                HStack(spacing: 10) {
                    Text("运行 \(snapshot.jobsAt == nil ? "—" : String(snapshot.jobs.filter { $0.state == .running }.count))")
                    Text("排队 \(snapshot.jobsAt == nil ? "—" : String(snapshot.jobs.filter { $0.state == .queued || $0.state == .starting }.count))")
                    Spacer()
                    if store.stale(platform) && snapshot.capacityAt != nil { Text("数据已过期").foregroundStyle(.orange) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                .opacity(snapshot.jobsAt == nil ? 0.4 : 1)
                if let error = store.errors[platform]?["capacity"] ?? store.errors[platform]?["credentials"] ?? store.errors[platform]?["configuration"] {
                    Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange)
                }
                if expanded && platform == .jiuzhang {
                    Text("库存不等于可调度数量").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if expanded, let explanation = snapshot.capacity?.explanation {
                    Text(explanation).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("尚未连接").font(.system(size: 14, weight: .medium)).padding(.top, 4)
                if let error = store.errors[platform]?["credentials"] { Text(error).font(.caption).foregroundStyle(.orange) }
                Button("配置平台") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(platform.tint)
            }
        }.padding(13).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.055), lineWidth: 0.5))
    }
    private var modelLabel: String {
        let raw = snapshot.capacity?.model ?? "GPU"
        return raw.replacingOccurrences(of: "NVIDIA-", with: "").replacingOccurrences(of: "-NV-", with: " · ")
    }
}

struct JobRow: View {
    let job: Job
    let stale: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: job.state.symbol).foregroundStyle(job.state.color).font(.system(size: 13)).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(job.name)
                    Spacer(minLength: 3)
                    Text(job.state == .unknown ? job.rawState : job.state.title).font(.system(size: 10)).foregroundStyle(job.state.color)
                }
                HStack(spacing: 4) {
                    Text(job.platform.title); Text("·"); Text(job.resourceText); Text("·")
                    TimelineView(.periodic(from: .now, by: 30)) { context in Text(job.elapsed(now: context.date)) }
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(11).contentShape(Rectangle()).opacity(stale ? 0.55 : 1)
    }
}

struct JobDetail: View {
    let job: Job
    let scope: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(job.state.title, systemImage: job.state.symbol).foregroundStyle(job.state.color); Spacer(); Button("完成") { dismiss() } }
            Text(job.name).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                row("平台", scope)
                row("任务 ID", job.nativeID)
                row("资源", job.resourceText)
                if let nodes = job.nodes { row("节点", String(nodes)) }
                if let created = job.createdAt { row("创建", created.formatted(date: .abbreviated, time: .standard)) }
                if let started = job.startedAt { row("启动", started.formatted(date: .abbreviated, time: .standard)) }
                if let ended = job.endedAt { row("结束", ended.formatted(date: .abbreviated, time: .standard)) }
                row("状态", job.rawState)
                if let reason = job.reason, !reason.isEmpty { row("详情", reason) }
            }.font(.system(size: 11))
            Text("平台状态不代表训练完成百分比。未返回实际资源分配时显示申请数量。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button(copied ? "已复制" : "复制 ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(job.nativeID, forType: .string); copied = true }
                Spacer()
                Link("打开平台控制台 ↗", destination: job.platform.consoleURL)
            }
        }.padding(20).frame(width: 360)
    }
    func row(_ name: String, _ value: String) -> some View {
        GridRow(alignment: .top) { Text(name).foregroundStyle(.secondary); Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }
}

struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var configuration = MonitoringConfiguration()
    @State private var filter = ""
    @State private var interval: Double = 60
    @State private var loginEnabled = false
    @State private var message: String?
    var body: some View {
        Form {
            Section("监控范围") {
                DisclosureGroup("前海 ACP 资源范围") {
                    TextField("订阅 ID", text: $configuration.qianhai.subscriptionID)
                    TextField("资源组", text: $configuration.qianhai.resourceGroup)
                    TextField("节点可用区", text: $configuration.qianhai.nodeZone)
                    TextField("任务可用区", text: $configuration.qianhai.taskZone)
                    TextField("资源池标识", text: $configuration.qianhai.pool)
                    TextField("工作空间标识", text: $configuration.qianhai.workspace)
                    Text("从自己的 ACP 配置中获取标识。当前支持前海深圳 API，资源池标识应使用 API 名称。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("九章智算中心") {
                    TextField("智算中心 ID", value: $configuration.jiuzhang.aidcID, format: .number.grouping(.never))
                    TextField("显示名称（可选）", text: $configuration.jiuzhang.regionName)
                    Text("使用账号可访问的 aidcId；显示名称仅用于标注，不参与查询。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("任务名称包含", text: $filter)
                Text("忽略大小写；留空显示范围内所有任务。名称匹配仅用于展示，不代表资源归属。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("刷新间隔", selection: $interval) {
                    Text("30 秒").tag(30.0); Text("60 秒").tag(60.0); Text("2 分钟").tag(120.0); Text("5 分钟").tag(300.0)
                }
                Button("保存监控设置") {
                    do { try store.apply(configuration: configuration, filter: filter, interval: interval); message = "监控设置已保存。" }
                    catch { message = error.localizedDescription }
                }
            }
            Section("平台凭据") {
                ForEach(Platform.allCases) { CredentialEditor(platform: $0, store: store) }
                Text("凭据仅保存在本机 macOS 钥匙串中，用于直接调用相应平台的查询 API。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("通用") {
                Toggle("任务完成或失败时通知", isOn: Binding(get: { store.notifications }, set: { store.setNotifications($0) }))
                Toggle("登录时启动 GPUBar", isOn: Binding(get: { loginEnabled }, set: { value in
                    do {
                        if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginEnabled = SMAppService.mainApp.status == .enabled
                    } catch { message = "登录启动设置失败：请将应用放入 Applications 后重试。" }
                }))
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("在系统设置中允许登录启动") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
        }.formStyle(.grouped).frame(width: 510, height: 680)
        .disabled(store.preview)
        .onAppear { configuration = store.configuration; filter = store.filter; interval = store.interval; loginEnabled = SMAppService.mainApp.status == .enabled }
    }
}

struct CredentialEditor: View {
    let platform: Platform
    @ObservedObject var store: AppStore
    @State private var expanded = false
    @State private var key = ""
    @State private var secret = ""
    @State private var message: String?
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            SecureField("Access Key", text: $key)
            SecureField("Secret Key", text: $secret)
            HStack {
                Button("保存并连接") {
                    do { try store.saveCredentials(platform: platform, key: key, secret: secret); key = ""; secret = ""; message = "已安全保存，正在连接。" }
                    catch { message = error.localizedDescription }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if store.configured.contains(platform) {
                    Button("移除凭据", role: .destructive) { do { try store.removeCredentials(platform); message = "凭据已移除。" } catch { message = error.localizedDescription } }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } label: {
            HStack { Text(platform.title); Spacer(); Text(store.configured.contains(platform) ? "已配置" : "未配置").font(.caption).foregroundStyle(store.configured.contains(platform) ? .green : .secondary) }
        }
    }
}
