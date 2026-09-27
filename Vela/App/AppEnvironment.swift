import SwiftUI
import Observation
import VelaFoundation
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
    /// Session WebSocket for "Play on this device" and play-state commands from other clients.
    let remoteControl = RemoteControlService()
    /// Set when the app runs under UI tests with canned server responses.
    let isUITest: Bool
    #if DEBUG
    /// `-play-url <url>`: show a stock AVPlayer for this URL instead of the app (device diagnostics).
    var debugPlayURL: URL?
    /// `-selftest queue`: plays every item in the queue file and writes a report (Tools/Nightly).
    var selfTest: SelfTestRunner?
    #endif

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
        observeSessionForRemoteControl()
    }

    static func live() -> AppEnvironment {
        AppLog.configure()
        let arguments = ProcessInfo.processInfo.arguments
        let isUITest = arguments.contains("-uitest")
        let preferences = Preferences(defaults: isUITest ? UserDefaults(suiteName: "uitest")! : .standard)
        if isUITest { preferences.resetForUITests() }
        AudioSessionController.configure()
        var capabilities = DeviceCapabilityProbe.probe(advancedEngineAvailable: AdvancedPlaybackEngine.isAvailable)
        #if DEBUG
        // `-capabilities appleTV4K|appleTV4KSDR|appleTVHD` lets the simulator decide like a real box (development only).
        if let preset = capabilityPreset(named: UserDefaults.standard.string(forKey: "capabilities")) {
            capabilities = preset
            capabilities.advancedEngineAvailable = AdvancedPlaybackEngine.isAvailable
            capabilities.modelName += " (simulated)"
            Log.notice(.playback, "Device capabilities overridden by launch argument")
        }
        #endif
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
        let environment = AppEnvironment(preferences: preferences, sessionStore: sessionStore, images: images, logBuffer: AppLog.buffer,
                                         capabilities: capabilities, isUITest: isUITest)
        #if DEBUG
        environment.debugPlayURL = UserDefaults.standard.string(forKey: "play-url").flatMap(URL.init(string:))
        if UserDefaults.standard.string(forKey: "selftest") == "queue" { environment.selfTest = SelfTestRunner(environment: environment) }
        if let url = environment.debugPlayURL { Log.notice(.ui, "Debug URL player requested for \(url.absoluteString)") }
        #endif
        return environment
    }

    var client: JellyfinClient? { sessionStore.active?.client }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            Log.info(.ui, "App entered background")
            playback?.appDidEnterBackground()
            remoteControl.suspend()
        case .inactive:
            playback?.appWillResignActive()
        case .active:
            Log.info(.ui, "App became active")
            playback?.appDidBecomeActive()
            refreshCapabilitiesIfNeeded()
            remoteControl.resume()
        @unknown default:
            break
        }
    }

    #if DEBUG
    private static func capabilityPreset(named name: String?) -> DeviceCapabilities? {
        switch name?.lowercased() {
        case "appletv4k", "appletv4khdr": return .appleTV4KHDR
        case "appletv4ksdr": return .appleTV4KSDR
        case "appletvhd": return .appleTVHD
        default: return nil
        }
    }
    #endif

    /// Audio routes can change (receiver switched on); re-probe cheaply.
    func refreshCapabilitiesIfNeeded() {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "capabilities") != nil { return }
        #endif
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
