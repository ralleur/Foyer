import SwiftUI
import Observation
import FoyerFoundation
import JellyfinKit
import PlaybackDecision

/// Dependency container for the whole app. Created once at launch.
@MainActor
@Observable
final class AppEnvironment {
    let preferences: Preferences
    let sessionStore: SessionStore
    let images: ImagePipeline
    let logBuffer: LogBuffer
    private(set) var capabilities: DeviceCapabilities
    /// The playback session currently on screen (nil when no player is presented).
    var playback: PlaybackCoordinator?
    /// Set when the app runs under UI tests with canned server responses.
    let isUITest: Bool

    init(preferences: Preferences, sessionStore: SessionStore, images: ImagePipeline, logBuffer: LogBuffer,
         capabilities: DeviceCapabilities, isUITest: Bool) {
        self.preferences = preferences
        self.sessionStore = sessionStore
        self.images = images
        self.logBuffer = logBuffer
        self.capabilities = capabilities
        self.isUITest = isUITest
        images.authorizationHeaderProvider = { @MainActor [weak sessionStore] in
            guard let client = sessionStore?.active?.client else { return nil }
            return client.identity.authorizationHeader(token: client.accessToken)
        }
    }

    static func live() -> AppEnvironment {
        AppLog.configure()
        let arguments = ProcessInfo.processInfo.arguments
        let isUITest = arguments.contains("-uitest")
        let preferences = Preferences(defaults: isUITest ? UserDefaults(suiteName: "uitest")! : .standard)
        if isUITest { preferences.resetForUITests() }
        AudioSessionController.configure()
        let capabilities = DeviceCapabilityProbe.probe(advancedEngineAvailable: AdvancedPlaybackEngine.isAvailable)
        Log.info(.playback, "Device capabilities: \(capabilities)")

        let transportFactory: @Sendable () -> any HTTPTransport
        if isUITest {
            transportFactory = { FixtureTransport() }
        } else {
            transportFactory = { URLSessionTransport(timeout: 20) }
        }
        let sessionStore = SessionStore(transportFactory: transportFactory, keychain: isUITest ? InMemoryKeychain() : KeychainStore())
        if isUITest { sessionStore.installUITestSession() }

        let images = ImagePipeline()
        return AppEnvironment(preferences: preferences, sessionStore: sessionStore, images: images, logBuffer: AppLog.buffer,
                              capabilities: capabilities, isUITest: isUITest)
    }

    var client: JellyfinClient? { sessionStore.active?.client }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            Log.info(.ui, "App entered background")
            playback?.appDidEnterBackground()
        case .inactive:
            playback?.appWillResignActive()
        case .active:
            Log.info(.ui, "App became active")
            playback?.appDidBecomeActive()
            refreshCapabilitiesIfNeeded()
        @unknown default:
            break
        }
    }

    /// Audio routes can change (receiver switched on); re-probe cheaply.
    func refreshCapabilitiesIfNeeded() {
        let fresh = DeviceCapabilityProbe.probe(advancedEngineAvailable: AdvancedPlaybackEngine.isAvailable)
        if fresh != capabilities {
            Log.info(.playback, "Device capabilities changed: \(fresh)")
            capabilities = fresh
        }
    }

    /// Builds the decision engine from current capabilities and preferences.
    var decisionEngine: PlaybackDecisionEngine {
        PlaybackDecisionEngine(capabilities: capabilities, preferences: preferences.playback)
    }
}
