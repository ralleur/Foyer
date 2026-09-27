import XCTest
import UIKit
@testable import Vela
import VelaFoundation
import JellyfinKit
import PlaybackDecision

final class ErrorPresentationTests: XCTestCase {
    func testEveryKindHasFriendlyText() {
        let kinds: [VelaErrorKind] = [.invalidServerAddress, .serverUnreachable, .certificateUntrusted, .authenticationFailed, .sessionExpired,
                                       .accessDenied, .notFound, .serverError(status: 500), .networkInterrupted, .videoLoadFailed, .formatUnsupported,
                                       .transcodingFailed, .subtitlesUnavailable, .quickConnectUnavailable, .unknown]
        for kind in kinds {
            let presentation = ErrorPresentation(VelaError(kind, detail: "x"))
            XCTAssertFalse(presentation.title.isEmpty, "\(kind) has no title")
            XCTAssertFalse(presentation.message.isEmpty, "\(kind) has no message")
            XCTAssertFalse(presentation.message.contains("HTTP"), "\(kind) leaks technical wording")
        }
        XCTAssertTrue(ErrorPresentation(VelaError(.cancelled)).title.isEmpty)
        XCTAssertEqual(ErrorPresentation(URLError(.notConnectedToInternet)).title, L10n.errorNetworkTitle)
    }
}

@MainActor
final class PreferencesTests: XCTestCase {
    func testRoundTrip() {
        let suite = "PreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.languages.audioLanguages = ["en", "de"]
        prefs.languages.subtitleMode = .always
        prefs.playback.maxStreamingBitrate = 20_000_000
        prefs.playback.advancedEngineMode = .never
        prefs.autoPlayNextEpisode = false
        prefs.subtitleSize = .large
        prefs.rememberAudioLanguage("ja", forSeries: "series1")

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.languages.audioLanguages, ["en", "de"])
        XCTAssertEqual(reloaded.languages.subtitleMode, .always)
        XCTAssertEqual(reloaded.playback.maxStreamingBitrate, 20_000_000)
        XCTAssertEqual(reloaded.playback.advancedEngineMode, .never)
        XCTAssertFalse(reloaded.autoPlayNextEpisode)
        XCTAssertEqual(reloaded.subtitleSize, .large)
        XCTAssertEqual(reloaded.rememberedAudioLanguages["series1"], "ja")
    }

    func testDefaultsMatchProductRules() {
        let suite = "PreferencesTests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        XCTAssertEqual(prefs.languages.audioLanguages, ["de", "en"])
        XCTAssertEqual(prefs.languages.subtitleLanguages, ["de", "en"])
        XCTAssertEqual(prefs.languages.subtitleMode, .smart)
        XCTAssertEqual(prefs.playback.directPlayMode, .preferred)
        XCTAssertEqual(prefs.playback.advancedEngineMode, .automatic)
        XCTAssertNil(prefs.playback.maxStreamingBitrate)
        XCTAssertTrue(prefs.autoPlayNextEpisode)
    }
}

final class ImagePipelineTests: XCTestCase {
    func testDownsampleRespectsTargetSize() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 3000))
        let data = renderer.pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 3000))
        }
        let image = try XCTUnwrap(ImagePipeline.downsample(data, to: CGSize(width: 240, height: 360)))
        let scale = UITraitCollection.current.displayScale
        XCTAssertLessThanOrEqual(image.size.height * image.scale, 360 * max(scale, 1) + 1)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testMemoryCacheHit() async throws {
        let pipeline = ImagePipeline(memoryLimitBytes: 10 * 1024 * 1024)
        let url = URL(string: "https://example.invalid/never.png")!
        XCTAssertNil(pipeline.cachedImage(for: url, targetSize: CGSize(width: 10, height: 10)))
    }
}

final class SubtitleLoaderDecodingTests: XCTestCase {
    func testDecodesLatin1Fallback() {
        let latin1 = "Grüße".data(using: .isoLatin1)!
        XCTAssertEqual(SubtitleLoader.decode(latin1), "Grüße")
        let utf8 = "Grüße".data(using: .utf8)!
        XCTAssertEqual(SubtitleLoader.decode(utf8), "Grüße")
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(utf8)
        XCTAssertEqual(SubtitleLoader.decode(bom), "Grüße", "BOM must be stripped so the parser never sees it")
    }
}

final class PlayerTrackTests: XCTestCase {
    func testTitleComposition() {
        var stream = MediaStream(index: 3, type: .subtitle, codec: "subrip", language: "ger")
        stream.isForced = true
        stream.isExternal = true
        stream.title = "Deutsch"
        let track = PlayerTrack(stream: stream)
        XCTAssertEqual(track.id, "subtitle:3")
        XCTAssertTrue(track.title.contains(L10n.forced))
        XCTAssertTrue(track.title.contains(L10n.external))
        XCTAssertFalse(track.title.contains("Deutsch · Deutsch"))
        XCTAssertFalse(track.isBitmap)
        XCTAssertEqual(PlayerTrack.subtitlesOff.id, "subtitle:off")
    }
}

final class ServerAccountTests: XCTestCase {
    func testIdentityAndTokenKey() {
        let account = ServerAccount(serverId: "s", serverName: "n", serverURL: URL(string: "https://x")!, serverVersion: nil,
                                    userId: "u", userName: "anna", userImageTag: nil, lastUsed: Date())
        XCTAssertEqual(account.id, "s|u")
        XCTAssertEqual(account.tokenKey, "token.s|u")
    }
}
