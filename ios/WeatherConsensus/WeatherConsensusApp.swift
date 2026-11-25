import SwiftUI

@main
struct WeatherConsensusApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            ContentView()
                .environment(\.nowOverride, DebugLaunch.now)
            #else
            ContentView()
            #endif
        }
    }
}
