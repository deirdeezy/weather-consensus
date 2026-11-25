import Foundation
import Observation
import SwiftUI

/// Temperature unit for every high, low and temperature value. The published file is always deg C.
nonisolated enum TemperatureUnit: String, CaseIterable, Sendable {
    case celsius, fahrenheit
}

/// Unit for precipitation amounts. The published file is always mm.
nonisolated enum RainUnit: String, CaseIterable, Sendable {
    case millimetres, inches
}

/// The units the screens draw with, read from `AppSettings` and passed down the view tree.
nonisolated struct UnitChoice: Equatable, Sendable {
    var temperature: TemperatureUnit = .celsius
    var rain: RainUnit = .millimetres

    /// The defaults: deg C and mm.
    static let metric = UnitChoice()
}

extension EnvironmentValues {
    /// Units for every value on screen. Default: deg C and mm.
    @Entry var unitChoice: UnitChoice = .metric
    /// Living sky on (time of day at the place) or off (a calm, fixed sky).
    @Entry var livingSky: Bool = true
}

/// The app's settings. Stored on this phone only, in the app's own `UserDefaults`: never synced,
/// never sent anywhere (no iCloud key-value store, no network). Defaults: deg C, mm, living sky on.
@Observable
final class AppSettings {
    enum Key {
        static let temperatureUnit = "temperatureUnit"
        static let rainUnit = "rainUnit"
        static let livingSky = "livingSky"
        static let all = [temperatureUnit, rainUnit, livingSky]
    }

    @ObservationIgnored private let defaults: UserDefaults

    var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) }
    }

    var rainUnit: RainUnit {
        didSet { defaults.set(rainUnit.rawValue, forKey: Key.rainUnit) }
    }

    var livingSky: Bool {
        didSet { defaults.set(livingSky, forKey: Key.livingSky) }
    }

    /// Reads what was saved; anything missing or unreadable falls back to the default.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        temperatureUnit = defaults.string(forKey: Key.temperatureUnit).flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
        rainUnit = defaults.string(forKey: Key.rainUnit).flatMap(RainUnit.init(rawValue:)) ?? .millimetres
        livingSky = defaults.object(forKey: Key.livingSky) == nil ? true : defaults.bool(forKey: Key.livingSky)
    }

    var units: UnitChoice {
        UnitChoice(temperature: temperatureUnit, rain: rainUnit)
    }
}

/// The app's version and build number, read from the bundle (never typed into the source).
nonisolated enum AppVersion {
    /// "0.1 (1)": marketing version, then the build number in brackets.
    static func text(info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    static var current: String { text(info: Bundle.main.infoDictionary) }
}
