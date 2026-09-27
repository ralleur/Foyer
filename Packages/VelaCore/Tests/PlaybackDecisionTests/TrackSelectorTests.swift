import XCTest
@testable import JellyfinKit
@testable import PlaybackDecision

final class TrackSelectorTests: XCTestCase {
    let prefs = LanguagePreferences()

    func testGermanAudioAvailable_noSubtitles() {
        let streams = [
            TestMedia.audio(index: 1, codec: "truehd", language: "eng", channels: 8, isDefault: true),
            TestMedia.audio(index: 2, codec: "eac3", language: "ger", channels: 6),
            TestMedia.subtitle(index: 3, codec: "subrip", language: "ger"),
            TestMedia.subtitle(index: 4, codec: "subrip", language: "eng"),
        ]
        let sel = TrackSelector.select(streams: streams, preferences: prefs)
        XCTAssertEqual(sel.audioStreamIndex, 2)
        XCTAssertNil(sel.subtitleStreamIndex)
    }

    func testGermanAudioWithForcedSubtitles() {
        let streams = [
            TestMedia.audio(index: 1, codec: "eac3", language: "deu", isDefault: true),
            TestMedia.subtitle(index: 2, codec: "subrip", language: "ger", forced: true),
            TestMedia.subtitle(index: 3, codec: "subrip", language: "ger"),
        ]
        let sel = TrackSelector.select(streams: streams, preferences: prefs)
        XCTAssertEqual(sel.audioStreamIndex, 1)
        XCTAssertEqual(sel.subtitleStreamIndex, 2)
    }

    func testEnglishOnlyAudio_getsGermanSubtitles() {
        let streams = [
            TestMedia.audio(index: 1, codec: "aac", language: "eng", isDefault: true),
            TestMedia.subtitle(index: 2, codec: "subrip", language: "eng"),
            TestMedia.subtitle(index: 3, codec: "subrip", language: "ger"),
            TestMedia.subtitle(index: 4, codec: "subrip", language: "ger", sdh: true),
        ]
        let sel = TrackSelector.select(streams: streams, preferences: prefs)
        XCTAssertEqual(sel.audioStreamIndex, 1)
        XCTAssertEqual(sel.subtitleStreamIndex, 3, "regular German track preferred over SDH")
    }

    func testExternalTextFileBeatsEmbeddedTextTrack() {
        // Companion (2025): embedded German SubRip plus the same text as an external .de.hi.srt next to the file.
        let streams = [
            TestMedia.audio(index: 1, codec: "truehd", language: "eng", isDefault: true),
            TestMedia.subtitle(index: 3, codec: "subrip", language: "ger"),
            TestMedia.subtitle(index: 5, codec: "PGSSUB", language: "ger"),
            TestMedia.subtitle(index: 12, codec: "subrip", language: "ger", external: true, sdh: true),
            TestMedia.subtitle(index: 13, codec: "subrip", language: "eng", external: true, sdh: true),
        ]
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: prefs).subtitleStreamIndex, 12)
    }

    func testEmbeddedBitmapTrackIsKeptOverExternalFile() {
        // Bitmap tracks are decoded near the playhead by Vela, no full-file extraction on the server.
        let streams = [
            TestMedia.audio(index: 1, codec: "truehd", language: "eng", isDefault: true),
            TestMedia.subtitle(index: 3, codec: "PGSSUB", language: "ger"),
            TestMedia.subtitle(index: 12, codec: "subrip", language: "ger", external: true),
        ]
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: prefs).subtitleStreamIndex, 3)
    }

    func testPreferSDH() {
        var p = prefs
        p.preferSDH = true
        let streams = [
            TestMedia.audio(index: 1, codec: "aac", language: "eng", isDefault: true),
            TestMedia.subtitle(index: 3, codec: "subrip", language: "ger"),
            TestMedia.subtitle(index: 4, codec: "subrip", language: "ger", sdh: true),
        ]
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: p).subtitleStreamIndex, 4)
    }

    func testJapaneseAudio_noPreferredSubtitles_fallsBackToEnglishSubs() {
        let streams = [
            TestMedia.audio(index: 1, codec: "aac", language: "jpn", isDefault: true),
            TestMedia.subtitle(index: 2, codec: "ass", language: "eng"),
        ]
        let sel = TrackSelector.select(streams: streams, preferences: prefs)
        XCTAssertEqual(sel.subtitleStreamIndex, 2)
    }

    func testCommentaryIsAvoided() {
        let streams = [
            TestMedia.audio(index: 1, codec: "ac3", language: "ger", channels: 2, title: "Regisseur Kommentar"),
            TestMedia.audio(index: 2, codec: "ac3", language: "ger", channels: 6),
        ]
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: prefs).audioStreamIndex, 2)
    }

    func testMoreChannelsWinWithinLanguage() {
        let streams = [
            TestMedia.audio(index: 1, codec: "aac", language: "ger", channels: 2),
            TestMedia.audio(index: 2, codec: "dts", language: "ger", channels: 6, profile: "DTS-HD MA"),
        ]
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: prefs).audioStreamIndex, 2)
    }

    func testDefaultFlagBreaksTiesWithinLanguage() {
        let streams = [
            TestMedia.audio(index: 1, codec: "eac3", language: "ger", channels: 6),
            TestMedia.audio(index: 2, codec: "eac3", language: "ger", channels: 6, isDefault: true),
        ]
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: prefs).audioStreamIndex, 2)
    }

    func testRememberedLanguageWins() {
        let streams = [
            TestMedia.audio(index: 1, codec: "eac3", language: "ger"),
            TestMedia.audio(index: 2, codec: "eac3", language: "eng"),
        ]
        let sel = TrackSelector.select(streams: streams, preferences: prefs, rememberedAudioLanguage: "en")
        XCTAssertEqual(sel.audioStreamIndex, 2)
        XCTAssertEqual(sel.subtitleStreamIndex, nil, "no subtitles available")
    }

    func testOriginalAudioPreference() {
        var p = prefs
        p.preferOriginalAudio = true
        let streams = [
            TestMedia.audio(index: 1, codec: "eac3", language: "ger"),
            TestMedia.audio(index: 2, codec: "eac3", language: "eng", isOriginal: true),
            TestMedia.subtitle(index: 3, codec: "subrip", language: "ger"),
        ]
        let sel = TrackSelector.select(streams: streams, preferences: p)
        XCTAssertEqual(sel.audioStreamIndex, 2)
        XCTAssertEqual(sel.subtitleStreamIndex, 3)
    }

    func testSingleUnknownLanguageTrack_noSubtitlesForced() {
        let streams = [
            TestMedia.audio(index: 1, codec: "aac", language: "und"),
            TestMedia.subtitle(index: 2, codec: "subrip", language: "ger"),
        ]
        XCTAssertNil(TrackSelector.select(streams: streams, preferences: prefs).subtitleStreamIndex)
    }

    func testSubtitleModes() {
        let streams = [
            TestMedia.audio(index: 1, codec: "eac3", language: "ger", isDefault: true),
            TestMedia.subtitle(index: 2, codec: "subrip", language: "ger", forced: true),
            TestMedia.subtitle(index: 3, codec: "subrip", language: "ger"),
        ]
        var p = prefs
        p.subtitleMode = .off
        XCTAssertNil(TrackSelector.select(streams: streams, preferences: p).subtitleStreamIndex)
        p.subtitleMode = .forcedOnly
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: p).subtitleStreamIndex, 2)
        p.subtitleMode = .always
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: p).subtitleStreamIndex, 3)
        p.subtitleMode = .smart
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: p).subtitleStreamIndex, 2)
    }

    func testNoAudioTracks() {
        let sel = TrackSelector.select(streams: [TestMedia.video(codec: "h264")], preferences: prefs)
        XCTAssertNil(sel.audioStreamIndex)
        XCTAssertNil(sel.subtitleStreamIndex)
    }

    func testEnglishSecondaryAudioWithoutGermanSubs_showsEnglishSubs() {
        let streams = [
            TestMedia.audio(index: 1, codec: "aac", language: "eng", isDefault: true),
            TestMedia.subtitle(index: 2, codec: "subrip", language: "eng"),
        ]
        // English is a preferred audio language but not the primary one, so full subtitles in a preferred language.
        XCTAssertEqual(TrackSelector.select(streams: streams, preferences: prefs).subtitleStreamIndex, 2)
    }
}
