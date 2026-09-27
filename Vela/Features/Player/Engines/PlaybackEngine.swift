import Foundation
import UIKit
import VelaFoundation
import JellyfinKit
import PlaybackDecision

enum PlaybackEngineState: Equatable {
    case idle
    case loading
    case buffering
    case playing
    case paused
    case ended
    case failed(VelaError)

    var isActive: Bool {
        switch self {
        case .playing, .paused, .buffering: true
        default: false
        }
    }
}

/// A selectable track as the UI sees it. Backed by Jellyfin stream indices so both
/// engines and the server agree on identities.
struct PlayerTrack: Identifiable, Hashable {
    enum Kind: Hashable { case audio, subtitle }

    let kind: Kind
    /// Jellyfin `MediaStream.index`; nil for the "Off" subtitle entry.
    let streamIndex: Int?
    let title: String
    let detail: String?
    let language: String?
    let isForced: Bool
    let isSDH: Bool
    let isExternal: Bool
    let isBitmap: Bool

    var id: String { "\(kind):\(streamIndex.map(String.init) ?? "off")" }

    static let subtitlesOff = PlayerTrack(kind: .subtitle, streamIndex: nil, title: L10n.subtitlesOff, detail: nil, language: nil,
                                          isForced: false, isSDH: false, isExternal: false, isBitmap: false)

    init(kind: Kind, streamIndex: Int?, title: String, detail: String?, language: String?, isForced: Bool, isSDH: Bool, isExternal: Bool, isBitmap: Bool) {
        self.kind = kind
        self.streamIndex = streamIndex
        self.title = title
        self.detail = detail
        self.language = language
        self.isForced = isForced
        self.isSDH = isSDH
        self.isExternal = isExternal
        self.isBitmap = isBitmap
    }

    init(stream: MediaStream) {
        let language = LanguageCode.displayName(stream.language) ?? L10n.unknownLanguage
        var flags: [String] = []
        if stream.isForced == true { flags.append(L10n.forced) }
        if stream.isSDH { flags.append(L10n.sdh) }
        if stream.isExternal == true { flags.append(L10n.external) }
        var title = language
        if let streamTitle = stream.title, !streamTitle.isEmpty, streamTitle.lowercased() != language.lowercased() {
            title += " · " + streamTitle
        }
        if !flags.isEmpty { title += " (" + flags.joined(separator: ", ") + ")" }
        self.init(kind: stream.isAudio ? .audio : .subtitle,
                  streamIndex: stream.index,
                  title: title,
                  detail: stream.technicalLabel,
                  language: stream.normalizedLanguage,
                  isForced: stream.isForced == true,
                  isSDH: stream.isSDH,
                  isExternal: stream.isExternal == true,
                  isBitmap: stream.isBitmapSubtitle)
    }
}

/// A text subtitle track that Vela can fetch and render itself.
struct ExternalSubtitle: Hashable {
    let streamIndex: Int
    let url: URL
    let format: SubtitleTextFormat?
    let language: String?
    let title: String
}

struct EngineLoadRequest {
    let itemId: String
    let mediaSource: MediaSource
    let url: URL
    let route: PlaybackRoute
    let startPosition: TimeInterval
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let externalSubtitles: [ExternalSubtitle]
    let fontURLs: [URL]
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let chapters: [(title: String, start: TimeInterval, imageURL: URL?)]
    /// Approximate frame rate for display matching.
    let frameRate: Double?
    let isHDR: Bool

    var isHLS: Bool { url.path.lowercased().hasSuffix(".m3u8") }
}

struct PlaybackStatistics: Equatable {
    var engine: String = ""
    var videoCodec: String = ""
    var resolution: String = ""
    var frameRate: String = ""
    var dynamicRange: String = ""
    var hardwareDecode: String = ""
    var audioCodec: String = ""
    var audioChannels: String = ""
    var droppedFrames: Int = 0
    var bufferedSeconds: Double = 0
    var bitrate: String = ""
    var extra: String = ""

    var lines: [String] {
        var out: [String] = []
        if !engine.isEmpty { out.append("Engine: \(engine)") }
        if !videoCodec.isEmpty { out.append("Video: \(videoCodec) \(resolution) \(frameRate) \(dynamicRange)".trimmingCharacters(in: .whitespaces)) }
        if !hardwareDecode.isEmpty { out.append("Decode: \(hardwareDecode)") }
        if !audioCodec.isEmpty { out.append("Audio: \(audioCodec) \(audioChannels)".trimmingCharacters(in: .whitespaces)) }
        out.append("Buffer: \(String(format: "%.1f", bufferedSeconds)) s")
        if droppedFrames > 0 { out.append("Dropped frames: \(droppedFrames)") }
        if !bitrate.isEmpty { out.append("Bitrate: \(bitrate)") }
        if !extra.isEmpty { out.append(extra) }
        return out
    }
}

@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func engine(_ engine: any PlaybackEngine, didChangeState state: PlaybackEngineState)
    func engine(_ engine: any PlaybackEngine, didUpdateTime time: TimeInterval, duration: TimeInterval)
    func engineDidReachEnd(_ engine: any PlaybackEngine)
    func engine(_ engine: any PlaybackEngine, didFail error: VelaError)
    func engineDidCompleteSeek(_ engine: any PlaybackEngine)
    func engineRequestsNextItem(_ engine: any PlaybackEngine)
    func engineRequestsPreviousItem(_ engine: any PlaybackEngine)
    func engineRequestsSkip(_ engine: any PlaybackEngine)
    func engine(_ engine: any PlaybackEngine, requestsAudioTrack streamIndex: Int)
    func engine(_ engine: any PlaybackEngine, requestsSubtitleTrack streamIndex: Int?)
}

/// What the coordinator needs from a player implementation. The UI never talks to engines directly.
@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    var delegate: (any PlaybackEngineDelegate)? { get set }
    var state: PlaybackEngineState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var statistics: PlaybackStatistics { get }
    var subtitleDelay: TimeInterval { get set }
    var audioDelay: TimeInterval { get set }
    var viewController: UIViewController { get }

    func load(_ request: EngineLoadRequest)
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
    /// Returns false when switching needs a reload (e.g. HLS transcode with a single audio track).
    func selectAudio(streamIndex: Int) -> Bool
    /// Returns false when the engine cannot show this track itself (bitmap subtitles in AVFoundation).
    func selectSubtitle(streamIndex: Int?) -> Bool
    /// Engine specific hooks for the surrounding UI.
    func updateSkipAction(title: String?)
    func updateNextEpisode(_ item: BaseItem?, artworkURL: URL?, creditsStart: TimeInterval?, autoplay: Bool)
    func updateTrackMenus(audio: [PlayerTrack], subtitles: [PlayerTrack], selectedAudio: Int?, selectedSubtitle: Int?)
    /// Called when Vela's own controls cover the lower part of the picture (subtitles move up).
    func setControlsVisible(_ visible: Bool)
    /// Bitmap subtitles decoded by Vela from the original file, drawn over the picture (nil = none).
    func setBitmapSubtitle(_ source: EmbeddedSubtitleSource?)
    func appDidEnterBackground()
    func appWillEnterForeground()
}
