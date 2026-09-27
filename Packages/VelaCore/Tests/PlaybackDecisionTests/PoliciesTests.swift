import XCTest
@testable import JellyfinKit
@testable import PlaybackDecision
import VelaFoundation

final class TrickplayTests: XCTestCase {
    func testTileMath() {
        let info = TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 250, interval: 10_000)
        let geo = TrickplayGeometry(info: info, width: 320)
        XCTAssertEqual(geo.thumbnailsPerImage, 100)
        XCTAssertEqual(geo.imageCount, 3)
        let t0 = geo.tile(at: 0)!
        XCTAssertEqual(t0.imageIndex, 0)
        XCTAssertEqual(t0.x, 0)
        XCTAssertEqual(t0.y, 0)
        let t = geo.tile(at: 1234)!   // thumbnail 123 → image 1, within 23 → row 2, col 3
        XCTAssertEqual(t.imageIndex, 1)
        XCTAssertEqual(t.x, 3 * 320)
        XCTAssertEqual(t.y, 2 * 180)
        let last = geo.tile(at: 99_999)!
        XCTAssertEqual(last.imageIndex, 2)
        XCTAssertNil(TrickplayGeometry(info: TrickplayInfo(width: 0, height: 0, tileWidth: 0, tileHeight: 0, thumbnailCount: 0, interval: 0), width: 0).tile(at: 1))
    }

    func testBestVariant() {
        let variants = ["160": TrickplayInfo(width: 160, height: 90, tileWidth: 10, tileHeight: 10, thumbnailCount: 1, interval: 1),
                        "320": TrickplayInfo(width: 320, height: 180, tileWidth: 10, tileHeight: 10, thumbnailCount: 1, interval: 1)]
        XCTAssertEqual(TrickplayGeometry.bestVariant(from: variants, preferredWidth: 300)?.width, 320)
        XCTAssertEqual(TrickplayGeometry.bestVariant(from: variants, preferredWidth: 800)?.width, 320)
        XCTAssertEqual(TrickplayGeometry.bestVariant(from: variants, preferredWidth: 100)?.width, 160)
        XCTAssertNil(TrickplayGeometry.bestVariant(from: [:], preferredWidth: 100))
    }
}

final class SkipPolicyTests: XCTestCase {
    let policy = SkipSegmentPolicy()
    let segments = [
        MediaSegment(id: "intro", type: .intro, start: 30, end: 90),
        MediaSegment(id: "outro", type: .outro, start: 2500, end: 2600),
        MediaSegment(id: "tiny", type: .intro, start: 200, end: 202),
    ]

    func testIntroPromptWindow() {
        XCTAssertEqual(policy.prompt(at: 10, segments: segments, mediaDuration: 2600, dismissed: [], hasNextEpisode: true), .none)
        XCTAssertEqual(policy.prompt(at: 31, segments: segments, mediaDuration: 2600, dismissed: [], hasNextEpisode: true), .skipIntro(to: 90))
        XCTAssertEqual(policy.prompt(at: 50, segments: segments, mediaDuration: 2600, dismissed: [], hasNextEpisode: true), .none, "button hides after 12 s")
        XCTAssertEqual(policy.prompt(at: 89.5, segments: segments, mediaDuration: 2600, dismissed: [], hasNextEpisode: true), .none)
        XCTAssertEqual(policy.prompt(at: 35, segments: segments, mediaDuration: 2600, dismissed: ["intro"], hasNextEpisode: true), .none)
        XCTAssertEqual(policy.prompt(at: 201, segments: segments, mediaDuration: 2600, dismissed: [], hasNextEpisode: true), .none, "too short")
    }

    func testOutroPrompt() {
        XCTAssertEqual(policy.prompt(at: 2550, segments: segments, mediaDuration: 2600, dismissed: [], hasNextEpisode: true), .nextEpisode(creditsStart: 2500, mediaEnd: 2600))
        XCTAssertEqual(policy.prompt(at: 2550, segments: segments, mediaDuration: 2590, dismissed: [], hasNextEpisode: false), .nextEpisode(creditsStart: 2500, mediaEnd: 2590))
    }

    func testCountdownStart() {
        let policy = NextEpisodeCountdownPolicy()
        XCTAssertEqual(policy.countdownStart(mediaDuration: 2600, outro: nil), 2580)
        XCTAssertEqual(policy.countdownStart(mediaDuration: 2600, outro: MediaSegment(type: .outro, start: 2500, end: 2600)), 2500)
        XCTAssertNil(policy.countdownStart(mediaDuration: 30, outro: nil))
    }
}

final class ReportAndResumePolicyTests: XCTestCase {
    func testProgressPolicy() {
        let policy = ProgressReportPolicy(interval: 10, minimumSpacing: 1)
        let clock = ManualClock()
        let t0 = clock.now
        XCTAssertTrue(policy.shouldReport(trigger: .timer, now: t0, lastReport: nil, isPlaying: true))
        XCTAssertFalse(policy.shouldReport(trigger: .timer, now: t0.addingTimeInterval(5), lastReport: t0, isPlaying: true))
        XCTAssertTrue(policy.shouldReport(trigger: .timer, now: t0.addingTimeInterval(10), lastReport: t0, isPlaying: true))
        XCTAssertFalse(policy.shouldReport(trigger: .timer, now: t0.addingTimeInterval(30), lastReport: t0, isPlaying: false), "no timer reports while paused")
        XCTAssertFalse(policy.shouldReport(trigger: .pause, now: t0.addingTimeInterval(0.2), lastReport: t0, isPlaying: false))
        XCTAssertTrue(policy.shouldReport(trigger: .pause, now: t0.addingTimeInterval(1.5), lastReport: t0, isPlaying: false))
        XCTAssertTrue(policy.shouldReport(trigger: .seek, now: t0.addingTimeInterval(2), lastReport: t0, isPlaying: true))
    }

    func testResumePolicy() {
        var item = BaseItem(id: "x", type: .movie)
        item.runTimeTicks = JellyfinTicks.ticks(seconds: 6000)
        item.userData = UserData(playbackPositionTicks: JellyfinTicks.ticks(seconds: 10))
        XCTAssertNil(ResumePolicy.resumePosition(for: item), "too early")
        item.userData = UserData(playbackPositionTicks: JellyfinTicks.ticks(seconds: 1200))
        XCTAssertEqual(ResumePolicy.resumePosition(for: item), 1200)
        XCTAssertTrue(ResumePolicy.canResume(item))
        item.userData = UserData(playbackPositionTicks: JellyfinTicks.ticks(seconds: 5995))
        XCTAssertNil(ResumePolicy.resumePosition(for: item), "practically finished")
        item.userData = nil
        XCTAssertFalse(ResumePolicy.canResume(item))
    }
}
