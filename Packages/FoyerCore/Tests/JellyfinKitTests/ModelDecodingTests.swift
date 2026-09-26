import XCTest
@testable import JellyfinKit
import FoyerFoundation

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

final class ModelDecodingTests: XCTestCase {
    let decoder = JellyfinDate.makeDecoder()

    func testMovieItemDecodes() throws {
        let item = try decoder.decode(BaseItem.self, from: fixture("movie_item"))
        XCTAssertEqual(item.id, "a1b2c3")
        XCTAssertEqual(item.type, .movie)
        XCTAssertTrue(item.isMovie)
        XCTAssertTrue(item.isPlayable)
        XCTAssertEqual(item.runtime, 9984)
        XCTAssertEqual(item.resumePosition, 1200)
        XCTAssertEqual(item.playedPercentage.map { Int($0) }, 12)
        XCTAssertEqual(item.people?.count, 2)
        XCTAssertEqual(item.chapters?.count, 2)
        XCTAssertEqual(item.trickplay?["ms1"]?["320"]?.thumbnailCount, 998)
        XCTAssertEqual(item.primaryImageTag, "p1")
        XCTAssertEqual(item.logoImageTag, "l1")
        XCTAssertEqual(item.firstBackdropTag, "b1")
        let created = try XCTUnwrap(item.dateCreated)
        XCTAssertEqual(Int(created.timeIntervalSince1970), 1714566896)

        let source = try XCTUnwrap(item.defaultMediaSource)
        XCTAssertEqual(source.container, "mkv")
        XCTAssertEqual(source.audioStreams.count, 3)
        XCTAssertEqual(source.subtitleStreams.count, 4)
        let video = try XCTUnwrap(source.videoStream)
        XCTAssertEqual(video.effectiveVideoRange, .doviWithHDR10)
        XCTAssertTrue(video.isHDR)
        XCTAssertTrue(video.isDolbyVision)
        XCTAssertEqual(video.dvProfile, 8)
        XCTAssertEqual(video.technicalLabel, "HEVC 4K Dolby Vision · HDR10")
        let truehd = try XCTUnwrap(source.stream(index: 1))
        XCTAssertTrue(truehd.isObjectAudio)
        XCTAssertEqual(truehd.technicalLabel, "Dolby TrueHD Atmos 7.1")
        let dts = try XCTUnwrap(source.stream(index: 3))
        XCTAssertEqual(dts.technicalLabel, "DTS-HD MA 5.1")
        let pgs = try XCTUnwrap(source.stream(index: 6))
        XCTAssertTrue(pgs.isBitmapSubtitle)
        XCTAssertFalse(pgs.isTextSubtitle)
        let sdh = try XCTUnwrap(source.stream(index: 7))
        XCTAssertTrue(sdh.isSDH)
        XCTAssertEqual(sdh.isExternal, true)
        XCTAssertEqual(source.mediaAttachments?.first?.isFont, true)
    }

    func testUnknownEnumValuesAreKept() throws {
        let json = #"{"Id":"x","Type":"HologramShow","MediaType":"Smell","LocationType":"Warp"}"#.data(using: .utf8)!
        let item = try decoder.decode(BaseItem.self, from: json)
        XCTAssertEqual(item.type?.rawValue, "HologramShow")
        XCTAssertFalse(item.isMovie)
    }

    func testQueryResultAndEpisodes() throws {
        let result = try decoder.decode(QueryResult<BaseItem>.self, from: fixture("resume_items"))
        XCTAssertEqual(result.totalRecordCount, 2)
        let episode = result.items[0]
        XCTAssertTrue(episode.isEpisode)
        XCTAssertEqual(episode.episodeLabel, "S1 · E1")
        XCTAssertEqual(episode.seriesName, "The Expanse")
        XCTAssertEqual(episode.resumePosition, 900)
        let emptyResult = try decoder.decode(QueryResult<BaseItem>.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(emptyResult.items.isEmpty)
    }

    func testPlaybackInfoDecodes() throws {
        let info = try decoder.decode(PlaybackInfoResponse.self, from: fixture("playback_info"))
        XCTAssertEqual(info.playSessionId, "ps1")
        let source = try XCTUnwrap(info.mediaSources.first)
        XCTAssertEqual(source.supportsDirectPlay, false)
        XCTAssertTrue(source.isHLSTranscode)
        XCTAssertEqual(source.stream(index: 5)?.deliveryMethod, .external)
    }

    func testAuthAndSystemInfo() throws {
        let auth = try decoder.decode(AuthenticationResult.self, from: fixture("auth_result"))
        XCTAssertEqual(auth.accessToken, "tok_ABC")
        XCTAssertEqual(auth.user.id, "user1")
        XCTAssertEqual(auth.user.configuration?.audioLanguagePreference, "deu")
        XCTAssertEqual(auth.user.configuration?.enableNextEpisodeAutoPlay, true)

        let info = try decoder.decode(PublicSystemInfo.self, from: fixture("public_system_info"))
        XCTAssertEqual(info.serverName, "Heimserver")
        XCTAssertTrue(info.isAtLeast(10, 10))
        XCTAssertTrue(info.isAtLeast(10, 9))
        XCTAssertFalse(info.isAtLeast(10, 11))
        XCTAssertFalse(info.isAtLeast(11, 0))
    }

    func testSegmentsAndIntroSkipper() throws {
        let segments = try decoder.decode(QueryResult<MediaSegment>.self, from: fixture("media_segments"))
        XCTAssertEqual(segments.items.count, 3)
        XCTAssertEqual(segments.items[0].type, .intro)
        XCTAssertEqual(segments.items[0].start, 30)
        XCTAssertEqual(segments.items[0].end, 120)
        XCTAssertEqual(segments.items[2].type.rawValue, "SomethingNew")

        let intro = try decoder.decode(IntroSkipperTimestamps.self, from: fixture("intro_skipper"))
        let segment = try XCTUnwrap(intro.asSegment(type: .intro))
        XCTAssertEqual(segment.start, 30.5, accuracy: 0.001)
        XCTAssertEqual(segment.end, 120, accuracy: 0.001)
        XCTAssertTrue(segment.contains(60))
        XCTAssertFalse(segment.contains(120))
    }

    func testQuickConnect() throws {
        let qc = try decoder.decode(QuickConnectResult.self, from: fixture("quick_connect"))
        XCTAssertEqual(qc.code, "123456")
        XCTAssertEqual(qc.authenticated, false)
    }

    func testDateParsing() {
        XCTAssertNotNil(JellyfinDate.parse("2024-05-01T12:34:56.1234567Z"))
        XCTAssertNotNil(JellyfinDate.parse("2024-05-01T12:34:56Z"))
        XCTAssertNotNil(JellyfinDate.parse("2024-05-01T12:34:56.12Z"))
        XCTAssertNotNil(JellyfinDate.parse("2024-05-01T12:34:56"))
        XCTAssertNotNil(JellyfinDate.parse("2024-05-01T12:34:56.1234567+02:00"))
        XCTAssertNil(JellyfinDate.parse("yesterday"))
        let a = JellyfinDate.parse("2024-05-01T12:34:56.9999999Z")!
        let b = JellyfinDate.parse("2024-05-01T12:34:56.999Z")!
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 0.0001)
    }

    func testDeviceProfileEncodesPascalCase() throws {
        var profile = DeviceProfile(name: "Test")
        profile.directPlayProfiles = [DirectPlayProfile(container: "mp4", audioCodec: "aac", videoCodec: "h264")]
        profile.codecProfiles = [CodecProfile(type: .video, codec: "hevc", conditions: [ProfileCondition(.videoCodecTag, .equalsAny, "hvc1|dvh1", isRequired: true)])]
        profile.subtitleProfiles = [SubtitleProfile(format: "srt", method: .external)]
        profile.transcodingProfiles = [TranscodingProfile(container: "mp4", videoCodec: "hevc,h264", audioCodec: "eac3,aac")]
        let data = try JellyfinDate.makeEncoder().encode(profile)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["Name"] as? String, "Test")
        let dp = try XCTUnwrap((json["DirectPlayProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(dp["Container"] as? String, "mp4")
        XCTAssertEqual(dp["Type"] as? String, "Video")
        let cp = try XCTUnwrap((json["CodecProfiles"] as? [[String: Any]])?.first)
        let cond = try XCTUnwrap((cp["Conditions"] as? [[String: Any]])?.first)
        XCTAssertEqual(cond["Condition"] as? String, "EqualsAny")
        XCTAssertEqual(cond["Property"] as? String, "VideoCodecTag")
        XCTAssertEqual(cond["IsRequired"] as? Bool, true)
        let tp = try XCTUnwrap((json["TranscodingProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(tp["Protocol"] as? String, "hls")
        XCTAssertEqual(tp["Context"] as? String, "Streaming")
        XCTAssertEqual(tp["BreakOnNonKeyFrames"] as? Bool, true)
        let sp = try XCTUnwrap((json["SubtitleProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(sp["Method"] as? String, "External")
    }

    func testReportEncoding() throws {
        let report = PlaybackStateReport(itemId: "a", mediaSourceId: "ms", playSessionId: "ps", positionTicks: 100, isPaused: true,
                                         playMethod: .directPlay, audioStreamIndex: 1, subtitleStreamIndex: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JellyfinDate.makeEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(json["ItemId"] as? String, "a")
        XCTAssertEqual(json["IsPaused"] as? Bool, true)
        XCTAssertEqual(json["PlayMethod"] as? String, "DirectPlay")
        XCTAssertEqual(json["PositionTicks"] as? Int, 100)
        XCTAssertNil(json["SubtitleStreamIndex"])
    }
}
