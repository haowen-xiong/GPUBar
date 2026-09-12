import Foundation
import GPUBarCore

enum Preferences {
    static let configurationKey = "platformConfiguration"
    static func configuration() -> MonitoringConfiguration {
        guard let data = UserDefaults.standard.data(forKey: configurationKey),
              let value = try? JSONDecoder().decode(MonitoringConfiguration.self, from: data) else {
            return MonitoringConfiguration()
        }
        return value.normalized()
    }
    static func save(_ configuration: MonitoringConfiguration) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(configuration.normalized()), forKey: configurationKey)
    }
}
