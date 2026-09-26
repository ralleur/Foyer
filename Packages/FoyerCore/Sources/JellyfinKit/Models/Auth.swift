import Foundation

public struct PublicSystemInfo: Codable, Hashable, Sendable {
    public var id: String?
    public var serverName: String?
    public var version: String?
    public var productName: String?
    public var operatingSystem: String?
    public var localAddress: String?
    public var startupWizardCompleted: Bool?

    public init(id: String? = nil, serverName: String? = nil, version: String? = nil) {
        self.id = id
        self.serverName = serverName
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case productName = "ProductName"
        case operatingSystem = "OperatingSystem"
        case localAddress = "LocalAddress"
        case startupWizardCompleted = "StartupWizardCompleted"
    }

    /// Parses "10.10.3" into comparable components.
    public var versionComponents: [Int] {
        (version ?? "").split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
    }

    public func isAtLeast(_ major: Int, _ minor: Int) -> Bool {
        let c = versionComponents
        guard c.count >= 2 else { return false }
        if c[0] != major { return c[0] > major }
        return c[1] >= minor
    }
}

public struct User: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var serverId: String?
    public var primaryImageTag: String?
    public var hasPassword: Bool?
    public var hasConfiguredPassword: Bool?
    public var configuration: UserConfiguration?
    public var policy: UserPolicy?

    public init(id: String, name: String?) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
        case primaryImageTag = "PrimaryImageTag"
        case hasPassword = "HasPassword"
        case hasConfiguredPassword = "HasConfiguredPassword"
        case configuration = "Configuration"
        case policy = "Policy"
    }
}

public struct UserConfiguration: Codable, Hashable, Sendable {
    public var audioLanguagePreference: String?
    public var subtitleLanguagePreference: String?
    public var subtitleMode: String?
    public var playDefaultAudioTrack: Bool?
    public var enableNextEpisodeAutoPlay: Bool?
    public var rememberAudioSelections: Bool?
    public var rememberSubtitleSelections: Bool?
    public var displayMissingEpisodes: Bool?
    public var hidePlayedInLatest: Bool?
    public var orderedViews: [String]?
    public var latestItemsExcludes: [String]?
    public var myMediaExcludes: [String]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case audioLanguagePreference = "AudioLanguagePreference"
        case subtitleLanguagePreference = "SubtitleLanguagePreference"
        case subtitleMode = "SubtitleMode"
        case playDefaultAudioTrack = "PlayDefaultAudioTrack"
        case enableNextEpisodeAutoPlay = "EnableNextEpisodeAutoPlay"
        case rememberAudioSelections = "RememberAudioSelections"
        case rememberSubtitleSelections = "RememberSubtitleSelections"
        case displayMissingEpisodes = "DisplayMissingEpisodes"
        case hidePlayedInLatest = "HidePlayedInLatest"
        case orderedViews = "OrderedViews"
        case latestItemsExcludes = "LatestItemsExcludes"
        case myMediaExcludes = "MyMediaExcludes"
    }
}

public struct UserPolicy: Codable, Hashable, Sendable {
    public var isAdministrator: Bool?
    public var enableMediaPlayback: Bool?
    public var enableVideoPlaybackTranscoding: Bool?
    public var enablePlaybackRemuxing: Bool?
    public var remoteClientBitrateLimit: Int?

    enum CodingKeys: String, CodingKey {
        case isAdministrator = "IsAdministrator"
        case enableMediaPlayback = "EnableMediaPlayback"
        case enableVideoPlaybackTranscoding = "EnableVideoPlaybackTranscoding"
        case enablePlaybackRemuxing = "EnablePlaybackRemuxing"
        case remoteClientBitrateLimit = "RemoteClientBitrateLimit"
    }
}

public struct AuthenticationResult: Codable, Hashable, Sendable {
    public var user: User
    public var accessToken: String
    public var serverId: String?

    public init(user: User, accessToken: String, serverId: String?) {
        self.user = user
        self.accessToken = accessToken
        self.serverId = serverId
    }

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

public struct QuickConnectResult: Codable, Hashable, Sendable {
    public var authenticated: Bool?
    public var secret: String?
    public var code: String?
    public var deviceId: String?
    public var deviceName: String?
    public var appName: String?
    public var appVersion: String?

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
        case deviceId = "DeviceId"
        case deviceName = "DeviceName"
        case appName = "AppName"
        case appVersion = "AppVersion"
    }
}
