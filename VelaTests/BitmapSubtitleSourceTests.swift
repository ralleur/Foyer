import XCTest
@testable import Vela

/// Decodes the synthetic PGS track in `Fixtures/pgs-sample.mkv` (two white bars, 1–3 s and 4–6 s on a
/// 1920×1080 canvas; made by `Scripts/make-pgs-fixture.py`) through the FFmpeg-backed source.
final class BitmapSubtitleSourceTests: XCTestCase {
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    func testDecodesSyntheticPGSTrack() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pgs-sample", withExtension: "mkv"))
        let source = BitmapSubtitleSource(url: url, streamIndex: 1, language: "ger")
        source.start(at: 0)
        defer { source.stop() }
        try await waitUntil { source.frame(at: 5) != nil || source.failure != nil }
        XCTAssertNil(source.failure)

        let first = try XCTUnwrap(source.frame(at: 1.5), "bar visible between 1 and 3 s")
        XCTAssertEqual(first.canvasWidth, 1920)
        XCTAssertEqual(first.canvasHeight, 1080)
        XCTAssertEqual(first.images.count, 1)
        XCTAssertEqual(first.images.first?.width, 400)
        XCTAssertEqual(first.images.first?.height, 60)
        XCTAssertEqual(first.images.first?.x, 760)
        XCTAssertEqual(first.images.first?.y, 900)
        XCTAssertEqual(first.images.first?.image.width, 400)
        XCTAssertNil(source.frame(at: 0.5), "nothing before the first bar")
        XCTAssertNil(source.frame(at: 3.5), "cleared at 3 s")
        XCTAssertNotNil(source.frame(at: 5.0), "second bar between 4 and 6 s")
        XCTAssertNil(source.frame(at: 6.5), "cleared at 6 s")
        XCTAssertGreaterThanOrEqual(source.decodedFrameCount, 4)

        // A seek back re-reads the file and decodes again.
        source.seek(to: 0)
        try await waitUntil { source.frame(at: 1.5) != nil }
        XCTAssertNotNil(source.frame(at: 1.5))
    }

    func testMissingStreamReportsFailure() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pgs-sample", withExtension: "mkv"))
        let source = BitmapSubtitleSource(url: url, streamIndex: 7, language: nil)
        source.start(at: 0)
        defer { source.stop() }
        try await waitUntil { source.failure != nil }
        XCTAssertNotNil(source.failure)
    }
}
