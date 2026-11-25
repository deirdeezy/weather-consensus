import SwiftUI

/// Placeholder until the Weather and Consensus tabs are built (docs/BUILD_PLAN.md, Stage 3).
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.hexagonpath")
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Weather Consensus")
                .font(.title2.bold())
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
