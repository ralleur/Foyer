import XCTest
@testable import JellyfinKit
@testable import PlaybackDecision

final class ChapterSegmentsTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(ChapterSegments.type(forChapterName: "Intro"), .intro)
        XCTAssertEqual(ChapterSegments.type(forChapterName: "Opening Credits"), .intro)
        XCTAssertEqual(ChapterSegments.type(forChapterName: "Vorspann"), .intro)
        XCTAssertEqual(ChapterSegments.type(forChapterName: "Previously on Severance"), .recap)
        XCTAssertEqual(ChapterSegments.type(forChapterName: "End Credits"), .outro)
        XCTAssertEqual(ChapterSegments.type(forChapterName: "Abspann"), .outro)
        XCTAssertNil(ChapterSegments.type(forChapterName: "Chapter 01"))
        XCTAssertNil(ChapterSegments.type(forChapterName: "Introduction to the case"), "whole words only")
        XCTAssertNil(ChapterSegments.type(forChapterName: "Opera"))
        XCTAssertNil(ChapterSegments.type(forChapterName: nil))
    }

    func testSegmentsSpanToTheNextChapter() {
        let segments = ChapterSegments.segments(chapters: [("Recap", 0), ("Intro", 62), ("Chapter 2", 118), ("Credits", 2520)], duration: 2600)
        XCTAssertEqual(segments.map(\.type), [.recap, .intro, .outro])
        XCTAssertEqual(segments[1].start, 62)
        XCTAssertEqual(segments[1].end, 118)
        XCTAssertEqual(segments[2].end, 2600)
    }

    func testServerSegmentsWinPerType() {
        let server = [MediaSegment(type: .intro, start: 60, end: 115)]
        let chapters = ChapterSegments.segments(chapters: [("Intro", 62), ("Chapter", 118), ("Credits", 2520)], duration: 2600)
        let merged = ChapterSegments.merge(server: server, chapters: chapters)
        XCTAssertEqual(merged.map(\.type), [.intro, .outro])
        XCTAssertEqual(merged[0].start, 60, "the server's intro, not the chapter")
    }

    func testChapterCreditsOfferTheNextEpisode() {
        let segments = ChapterSegments.segments(chapters: [("Episode", 0), ("End Credits", 2500)], duration: 2560)
        let prompt = SkipSegmentPolicy().prompt(at: 2510, segments: segments, mediaDuration: 2560, dismissed: [], hasNextEpisode: true)
        XCTAssertEqual(prompt, .nextEpisode(creditsStart: 2500, mediaEnd: 2560))
    }
}
