import XCTest
@testable import PlaybackDecision

final class SubtitleParserTests: XCTestCase {
    func testSRT() {
        let srt = """
        \u{FEFF}1
        00:00:01,000 --> 00:00:03,500
        <i>Hello</i> <b>world</b>

        2
        00:00:04,000 --> 00:00:06,000
        {\\an8}Top line
        second line


        3
        00:01:00,000 --> 00:01:02,000
        <font color="#ff0000">Red</font> &amp; done
        """
        let cues = SubtitleParser.parse(srt)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].start, 1)
        XCTAssertEqual(cues[0].end, 3.5)
        XCTAssertEqual(cues[0].text, "<i>Hello</i> world")
        XCTAssertTrue(cues[1].isTop)
        XCTAssertEqual(cues[1].text, "Top line\nsecond line")
        XCTAssertEqual(cues[2].text, "Red & done")
        XCTAssertEqual(cues[2].start, 60)
    }

    func testWebVTT() {
        let vtt = """
        WEBVTT - Some title

        NOTE this is a comment

        STYLE
        ::cue { color: white }

        cue-1
        00:01.000 --> 00:02.000 line:0% align:start
        <v Speaker>Top cue</v>

        00:00:05.000 --> 00:00:07.250
        Second <c.yellow>cue</c>
        """
        let cues = SubtitleParser.parse(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1)
        XCTAssertEqual(cues[0].end, 2)
        XCTAssertTrue(cues[0].isTop)
        XCTAssertEqual(cues[0].text, "Top cue")
        XCTAssertEqual(cues[1].start, 5)
        XCTAssertEqual(cues[1].end, 7.25)
        XCTAssertEqual(cues[1].text, "Second cue")
    }

    func testASS() {
        let ass = """
        [Script Info]
        Title: Test

        [V4+ Styles]
        Format: Name, Fontname
        Style: Default,Arial

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\an8\\fad(200,200)}Top text\\NSecond, with comma
        Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0{\\p0}
        Dialogue: 0,0:00:06.00,0:00:08.00,Default,,0,0,0,,{\\i1}Italic{\\i0} normal\\hspace
        """
        let cues = SubtitleParser.parse(ass)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.5)
        XCTAssertEqual(cues[0].end, 3)
        XCTAssertTrue(cues[0].isTop)
        XCTAssertEqual(cues[0].text, "Top text\nSecond, with comma")
        XCTAssertEqual(cues[1].text, "Italic normal space")
    }

    func testFormatDetectionWithHint() {
        let cues = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000\nX", format: .webvtt)
        XCTAssertEqual(cues.count, 1)
    }

    func testTimelineLookup() {
        let cues = [
            SubtitleCue(id: 0, start: 1, end: 3, text: "a"),
            SubtitleCue(id: 1, start: 2, end: 10, text: "long"),
            SubtitleCue(id: 2, start: 4, end: 5, text: "c"),
            SubtitleCue(id: 3, start: 20, end: 22, text: "d"),
        ]
        let timeline = SubtitleTimeline(cues: cues)
        XCTAssertEqual(timeline.activeCues(at: 0.5).map(\.text), [])
        XCTAssertEqual(timeline.activeCues(at: 1.5).map(\.text), ["a"])
        XCTAssertEqual(timeline.activeCues(at: 2.5).map(\.text), ["a", "long"])
        XCTAssertEqual(timeline.activeCues(at: 4.5).map(\.text), ["long", "c"])
        XCTAssertEqual(timeline.activeCues(at: 9.99).map(\.text), ["long"])
        XCTAssertEqual(timeline.activeCues(at: 15).map(\.text), [])
        XCTAssertEqual(timeline.activeCues(at: 21).map(\.text), ["d"])
        XCTAssertEqual(timeline.nextChange(after: 0), 1)
        XCTAssertEqual(timeline.nextChange(after: 2.5), 3)
        XCTAssertEqual(timeline.nextChange(after: 12), 20)
        XCTAssertNil(timeline.nextChange(after: 30))
    }

    func testMalformedInputDoesNotCrash() {
        XCTAssertTrue(SubtitleParser.parse("").isEmpty)
        XCTAssertTrue(SubtitleParser.parse("garbage --> more garbage").isEmpty)
        XCTAssertTrue(SubtitleParser.parse("1\n00:00:02,000 --> 00:00:01,000\nreversed").isEmpty)
    }
}
