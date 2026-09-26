import SwiftUI
import FoyerFoundation

@main
struct FoyerApp: App {
    @State private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(\.imagePipeline, environment.images)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    environment.scenePhaseChanged(phase)
                }
        }
    }
}
