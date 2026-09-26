import XCTest
@testable import JellyfinKit
@testable import PlaybackDecision

final class DecisionEngineTests: XCTestCase {
    let engine = PlaybackDecisionEngine(capabilities: .appleTV4KHDR)

    func decide(_ source: MediaSource, audio: Int? = nil, subtitle: Int? = nil, prefs: PlaybackPreferences = .default,
                caps: DeviceCapabilities = .appleTV4KHDR) -> PlaybackDecision {
        PlaybackDecisionEngine(capabilities: caps, preferences: prefs).decide(source: source, audioStreamIndex: audio, subtitleStreamIndex: subtitle)
    }

    // MARK: Test matrix (PLAYBACK.md)

    func test_1080pH264_AAC_SRT_isNativeDirectPlay() {
        let d = decide(TestMedia.mp4H264AACSRT, subtitle: 2)
        XCTAssertEqual(d.route, .nativeDirectPlay)
        XCTAssertEqual(d.subtitleHandling, .externalText)
        XCTAssertEqual(d.audioStreamIndex, 1)
        XCTAssertTrue(d.reasons.contains { $0.contains("no server transcoding") })
    }

    func test_1080pH264_AC3_isNativeDirectPlay_withFFmpegContainerName() {
        let d = decide(TestMedia.mp4H264AC3)
        XCTAssertEqual(d.route, .nativeDirectPlay)
        XCTAssertTrue(d.reasons.contains { $0.contains("passed through") })
    }

    func test_4KHEVCSDR_MKV_isAdvancedDirectPlay() {
        let d = decide(TestMedia.mkv4KHEVCSDR)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertEqual(d.engine, .advanced)
        XCTAssertEqual(d.method, .directPlay)
        XCTAssertTrue(d.compromises.isEmpty)
    }

    func test_4KHEVCHDR10_MKV_isDirectStream_toKeepHDR() {
        let d = decide(TestMedia.mkv4KHEVCHDR10)
        XCTAssertEqual(d.route, .directStream)
        XCTAssertEqual(d.engine, .native)
        XCTAssertTrue(d.reasons.contains { $0.contains("HDR10 is preserved") })
        XCTAssertTrue(d.compromises.isEmpty, "EAC3 needs no audio transcode")
    }

    func test_4KHEVCDV8_MP4_isNativeDirectPlay() {
        let d = decide(TestMedia.mp44KHEVCDV8)
        XCTAssertEqual(d.route, .nativeDirectPlay)
        XCTAssertTrue(d.reasons.contains { $0.contains("Dolby Vision profile 8") })
    }

    func test_4KHEVCDV5_MKV_isDirectStream() {
        let d = decide(TestMedia.mkv4KHEVCDV5)
        XCTAssertEqual(d.route, .directStream)
    }

    func test_4KHEVCDV5_withoutDVDisplay_isAdvanced_toneMapped() {
        let d = decide(TestMedia.mkv4KHEVCDV5, caps: .appleTV4KSDR)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertTrue(d.compromises.contains { $0.contains("tone-mapped") })
    }

    func test_MKV_HEVC_DTS_isAdvanced() {
        XCTAssertEqual(decide(TestMedia.mkvHEVCDTS).route, .advancedDirectPlay)
    }

    func test_MKV_HEVC_DTSHD_isAdvanced() {
        let d = decide(TestMedia.mkvHEVCDTSHD)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertTrue(d.reasons.contains { $0.contains("DTS-HD MA 5.1 decoded locally") })
    }

    func test_MKV_HEVC_TrueHD_isAdvanced() {
        let d = decide(TestMedia.mkvHEVCTrueHD)
        XCTAssertEqual(d.route, .advancedDirectPlay)
    }

    func test_MKV_HDR_TrueHD_isDirectStream_withAudioTranscodeCompromise() {
        let d = decide(TestMedia.mkv4KHDRTrueHD)
        XCTAssertEqual(d.route, .directStream)
        XCTAssertTrue(d.compromises.contains { $0.contains("Dolby TrueHD") })
        XCTAssertTrue(d.reasons.contains { $0.contains("audio only") })
    }

    func test_ASS_subtitles_MKV_isAdvanced_embedded() {
        let d = decide(TestMedia.mkvASS, subtitle: 2)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertEqual(d.subtitleHandling, .embedded)
    }

    func test_PGS_selected_onHDR_prefersAdvancedOverBurnIn() {
        let d = decide(TestMedia.mkvHDRPGS, subtitle: 2)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertEqual(d.subtitleHandling, .embedded)
    }

    func test_PGS_notSelected_onHDR_isDirectStream() {
        XCTAssertEqual(decide(TestMedia.mkvHDRPGS).route, .directStream)
    }

    func test_PGS_selected_withoutAdvancedEngine_burnsIn() {
        var caps = DeviceCapabilities.appleTV4KHDR
        caps.advancedEngineAvailable = false
        let d = decide(TestMedia.mkvHDRPGS, subtitle: 2, caps: caps)
        XCTAssertEqual(d.route, .transcode)
        XCTAssertEqual(d.subtitleHandling, .burnIn)
        XCTAssertTrue(d.deviceProfile.subtitleProfiles.contains { $0.format == "pgssub" && $0.method == .encode })
    }

    func test_PGS_selected_burnInDisabled_dropsSubtitle() {
        var caps = DeviceCapabilities.appleTV4KHDR
        caps.advancedEngineAvailable = false
        var prefs = PlaybackPreferences.default
        prefs.allowBurnInSubtitles = false
        let d = decide(TestMedia.mkvHDRPGS, subtitle: 2, prefs: prefs, caps: caps)
        XCTAssertEqual(d.route, .directStream)
        XCTAssertEqual(d.subtitleHandling, .none)
        XCTAssertFalse(d.deviceProfile.subtitleProfiles.contains { $0.method == .encode })
    }

    func test_externalSRT_MP4_isNative_overlay() {
        let d = decide(TestMedia.mp4H264AACSRT, subtitle: 2)
        XCTAssertEqual(d.route, .nativeDirectPlay)
        XCTAssertEqual(d.subtitleHandling, .externalText)
    }

    func test_hev1_tag_inMP4_SDR_goesAdvanced() {
        let d = decide(TestMedia.mp4Hev1)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertTrue(d.reasons.contains { $0.contains("hev1") })
    }

    func test_hev1_tag_inMP4_withoutAdvanced_isDirectStreamRemux() {
        var caps = DeviceCapabilities.appleTV4KHDR
        caps.advancedEngineAvailable = false
        let d = decide(TestMedia.mp4Hev1, caps: caps)
        XCTAssertEqual(d.route, .directStream)
    }

    func test_AV1_1080p_withoutHardware_isAdvancedSoftware() {
        let src = TestMedia.source(container: "mkv", streams: [TestMedia.video(codec: "av1", tag: nil), TestMedia.audio(index: 1, codec: "opus", channels: 2)])
        let d = decide(src)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertTrue(d.reasons.contains { $0.contains("dav1d") })
    }

    func test_AV1_4K_withoutHardware_isTranscode() {
        let src = TestMedia.source(container: "mkv", streams: [TestMedia.video(codec: "av1", width: 3840, height: 2160, tag: nil), TestMedia.audio(index: 1, codec: "opus", channels: 2)])
        let d = decide(src)
        XCTAssertEqual(d.route, .transcode)
    }

    func test_AV1_4K_withHardware_isNativeOrAdvanced() {
        var caps = DeviceCapabilities.appleTV4KHDR
        caps.supportsAV1Hardware = true
        let src = TestMedia.source(container: "mp4", streams: [TestMedia.video(codec: "av1", width: 3840, height: 2160, tag: "av01"), TestMedia.audio(index: 1, codec: "aac", channels: 2)])
        XCTAssertEqual(decide(src, caps: caps).route, .nativeDirectPlay)
    }

    func test_AppleTVHD_4K_isTranscode() {
        let d = decide(TestMedia.mkv4KHEVCSDR, caps: .appleTVHD)
        XCTAssertEqual(d.route, .transcode)
        XCTAssertTrue(d.reasons.contains { $0.contains("exceeds device maximum") })
    }

    func test_advancedEngineNever_MKV_isDirectStream() {
        var prefs = PlaybackPreferences.default
        prefs.advancedEngineMode = .never
        let d = decide(TestMedia.mkvHEVCDTS, prefs: prefs)
        XCTAssertEqual(d.route, .directStream)
        XCTAssertTrue(d.compromises.contains { $0.contains("re-encoded by the server") })
    }

    func test_advancedEngineAlways_prefersAdvancedEvenForMP4() {
        var prefs = PlaybackPreferences.default
        prefs.advancedEngineMode = .always
        XCTAssertEqual(decide(TestMedia.mp4H264AC3, prefs: prefs).route, .advancedDirectPlay)
        XCTAssertEqual(decide(TestMedia.mkv4KHEVCHDR10, prefs: prefs).route, .advancedDirectPlay)
    }

    func test_forcedDirectPlay_HDR_MKV_usesAdvanced() {
        var prefs = PlaybackPreferences.default
        prefs.directPlayMode = .forced
        let d = decide(TestMedia.mkv4KHEVCHDR10, prefs: prefs)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertFalse(d.enableTranscoding)
        XCTAssertFalse(d.enableDirectStream)
    }

    func test_forcedDirectPlay_unsupportedCodec_stillAttempts() {
        var prefs = PlaybackPreferences.default
        prefs.directPlayMode = .forced
        let src = TestMedia.source(container: "mkv", streams: [TestMedia.video(codec: "av1", width: 3840, height: 2160, tag: nil)])
        let d = decide(src, prefs: prefs)
        XCTAssertEqual(d.route, .advancedDirectPlay)
        XCTAssertTrue(d.reasons.contains { $0.hasPrefix("unverified") })
    }

    func test_interlacedH264_MP4_goesAdvanced() {
        let src = TestMedia.source(container: "mp4", streams: [TestMedia.video(codec: "h264", interlaced: true), TestMedia.audio(index: 1, codec: "ac3")])
        XCTAssertEqual(decide(src).route, .advancedDirectPlay)
    }

    func test_VP9_webm_isAdvanced() {
        let src = TestMedia.source(container: "webm", streams: [TestMedia.video(codec: "vp9", tag: nil), TestMedia.audio(index: 1, codec: "opus", channels: 2)])
        XCTAssertEqual(decide(src).route, .advancedDirectPlay)
    }

    func test_opusAudio_MP4_isAdvanced() {
        let src = TestMedia.source(container: "mp4", streams: [TestMedia.video(codec: "h264"), TestMedia.audio(index: 1, codec: "opus", channels: 2)])
        XCTAssertEqual(decide(src).route, .advancedDirectPlay)
    }

    func test_h264_10bit_MP4_isAdvanced() {
        let src = TestMedia.source(container: "mp4", streams: [TestMedia.video(codec: "h264", profile: "High 10", bitDepth: 10), TestMedia.audio(index: 1, codec: "aac")])
        XCTAssertEqual(decide(src).route, .advancedDirectPlay)
    }

    func test_HLG_onSDRDisplay_isAdvancedToneMapped() {
        let src = TestMedia.source(container: "mp4", streams: [TestMedia.video(codec: "hevc", range: .hlg), TestMedia.audio(index: 1, codec: "aac")])
        let d = decide(src, caps: .appleTV4KSDR)
        XCTAssertEqual(d.route, .advancedDirectPlay)
    }

    func test_serverForbidsDirectPlay_isRespected() {
        var src = TestMedia.mp4H264AC3
        src.supportsDirectPlay = false
        let d = decide(src)
        XCTAssertEqual(d.route, .directStream)
    }

    func test_60fps_4K_isAllowed_but120IsNot() {
        let ok = TestMedia.source(container: "mp4", streams: [TestMedia.video(codec: "hevc", width: 3840, height: 2160, fps: 59.94), TestMedia.audio(index: 1, codec: "aac")])
        XCTAssertEqual(decide(ok).route, .nativeDirectPlay)
        let tooFast = TestMedia.source(container: "mp4", streams: [TestMedia.video(codec: "hevc", fps: 120), TestMedia.audio(index: 1, codec: "aac")])
        XCTAssertEqual(decide(tooFast).route, .transcode)
    }

    func test_multipleVersions_decisionPerSource() {
        // 4K HDR MKV version vs 1080p MP4 version of the same title.
        XCTAssertEqual(decide(TestMedia.mkv4KHEVCHDR10).route, .directStream)
        XCTAssertEqual(decide(TestMedia.mp4H264AC3).route, .nativeDirectPlay)
    }

    // MARK: Device profile

    func test_nativeProfileShape() {
        let d = decide(TestMedia.mp4H264AC3)
        let p = d.deviceProfile
        XCTAssertEqual(p.name, "Foyer tvOS (native)")
        XCTAssertTrue(p.directPlayProfiles.contains { $0.container.contains("mp4") && $0.videoCodec!.contains("hevc") })
        XCTAssertFalse(p.directPlayProfiles.contains { $0.container.contains("mkv") })
        XCTAssertTrue(p.codecProfiles.contains { $0.codec == "hevc" && $0.conditions.contains { $0.property == .videoCodecTag && $0.isRequired } })
        XCTAssertTrue(p.subtitleProfiles.contains { $0.format == "srt" && $0.method == .external })
        XCTAssertFalse(p.subtitleProfiles.contains { $0.method == .encode })
        XCTAssertEqual(p.transcodingProfiles.first?.protocol, "hls")
        XCTAssertEqual(p.transcodingProfiles.first?.container, "mp4")
        XCTAssertEqual(p.transcodingProfiles.first?.audioCodec?.split(separator: ",").first, "eac3")
    }

    func test_advancedProfileShape() {
        let d = decide(TestMedia.mkvHEVCDTS)
        let p = d.deviceProfile
        XCTAssertEqual(p.name, "Foyer tvOS (advanced)")
        XCTAssertTrue(p.directPlayProfiles.contains { $0.container.contains("mkv") && $0.audioCodec!.contains("truehd") })
        XCTAssertTrue(p.subtitleProfiles.contains { $0.format == "pgssub" && $0.method == .embed })
        XCTAssertTrue(p.codecProfiles.contains { $0.codec == "av1" })
    }

    func test_bitrateLimitIsForwarded() {
        var prefs = PlaybackPreferences.default
        prefs.maxStreamingBitrate = 20_000_000
        let d = decide(TestMedia.mp4H264AC3, prefs: prefs)
        XCTAssertEqual(d.deviceProfile.maxStreamingBitrate, 20_000_000)
    }

    // MARK: Reconcile with server

    func test_reconcile_serverDeclinesDirectPlay() {
        let decision = decide(TestMedia.mkvHEVCDTS)
        var server = TestMedia.mkvHEVCDTS
        server.supportsDirectPlay = false
        server.supportsDirectStream = true
        server.transcodingUrl = "/videos/x/master.m3u8?AudioCodec=eac3&PlaySessionId=1"
        let reconciled = engine.reconcile(decision, with: server)
        XCTAssertEqual(reconciled.route, .directStream)
        XCTAssertTrue(reconciled.reasons.last!.contains("server declined"))
    }

    func test_reconcile_serverTranscodesVideo() {
        let decision = decide(TestMedia.mkv4KHEVCHDR10)
        var server = TestMedia.mkv4KHEVCHDR10
        server.supportsDirectPlay = false
        server.supportsDirectStream = false
        server.transcodingUrl = "/videos/x/master.m3u8?VideoCodec=h264&PlaySessionId=1"
        XCTAssertEqual(engine.reconcile(decision, with: server).route, .transcode)
    }

    func test_reconcile_keepsDirectPlayWhenServerAgrees() {
        let decision = decide(TestMedia.mp4H264AC3)
        var server = TestMedia.mp4H264AC3
        server.supportsDirectPlay = true
        XCTAssertEqual(engine.reconcile(decision, with: server).route, .nativeDirectPlay)
    }

    func test_summaryIsReadable() {
        let d = decide(TestMedia.mkvHEVCDTSHD)
        XCTAssertTrue(d.summary.hasPrefix("Advanced Direct Play"))
        XCTAssertTrue(d.summary.contains("• "))
    }
}
