import SwiftUI

@main
struct TrainBoardApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 14) {
                Text("🚆 Train Board").font(.title2.bold())
                Text("Right-click your desktop → Edit Widgets →\nadd a Train Board widget.\n\nRight-click a widget → Edit Train Board\nto choose its station. Add as many as you like.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Link("Made by @joseph_moylan2", destination: URL(string: "https://x.com/joseph_moylan2")!)
                    .font(.caption)
            }
            .padding(30)
            .frame(width: 360)
        }
        .windowResizability(.contentSize)
    }
}
