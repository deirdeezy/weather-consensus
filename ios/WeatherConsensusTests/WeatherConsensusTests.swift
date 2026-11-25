import Foundation
import Testing
@testable import WeatherConsensus

/// Placeholder so the Swift Testing target builds. Real tests arrive with the JSON reader.
struct WeatherConsensusTests {
    @Test func appModuleLoads() {
        #expect(Bundle.main.bundleIdentifier != nil)
    }
}
