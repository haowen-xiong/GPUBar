import SwiftUI
import AppKit
import GPUBarCore

@main
struct GPUBarLauncher {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--import-credentials") {
            do {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                guard input.count < 64_000 else { throw CloudError.credentials }
                let pairs = try JSONDecoder().decode([String: Credentials].self, from: input)
                for platform in Platform.allCases {
                    if let credentials = pairs[platform.rawValue] { try Keychain.save(credentials, platform: platform) }
                }
                print("Credentials saved to macOS Keychain.")
            } catch { fputs("Credential import failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--import-config") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard data.count < 64_000 else { throw ConfigurationError("配置文件过大。") }
                let config = try JSONDecoder().decode(MonitoringConfiguration.self, from: data).normalized()
                try Preferences.save(config)
                print("Resource configuration saved locally. Restart GPUBar to apply it.")
            } catch { fputs("Configuration import failed.\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--probe") {
            var failed = false
            let config = Preferences.configuration()
            let filter = UserDefaults.standard.string(forKey: "nameFilter") ?? ""
            for platform in Platform.allCases {
                do {
                    guard let credentials = try Keychain.load(platform) else { throw CloudError.credentials }
                    let api = CloudAPI(platform: platform, credentials: credentials, configuration: config)
                    async let capacity = api.capacity()
                    async let jobs = api.jobs(filter: filter)
                    let (resource, tasks) = try await (capacity, jobs)
                    let result = ProbeResult(platform: platform.rawValue, scope: config.scope(platform), capacity: resource, jobs: tasks)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    print(String(decoding: try encoder.encode(result), as: UTF8.self))
                } catch { print("\(platform.rawValue): \(error.localizedDescription)"); failed = true }
            }
            exit(failed ? 1 : 0)
        }
        GPUBarApplication.main()
    }
}
struct ProbeResult: Encodable {
    let platform: String
    let scope: String
    let capacity: Capacity
    let jobs: [Job]
}

struct GPUBarApplication: App {
    @StateObject private var store = AppStore(preview: CommandLine.arguments.contains("--preview"))
    var body: some Scene {
        MenuBarExtra { DashboardView(store: store) } label: { MenuLabel(store: store) }
            .menuBarExtraStyle(.window)
        Window("GPUBar 设置", id: "settings") { SettingsView(store: store) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
        Window("GPUBar", id: "dashboard") { DashboardView(store: store) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(CommandLine.arguments.contains("--dashboard") || store.preview ? .presented : .suppressed)
    }
}
