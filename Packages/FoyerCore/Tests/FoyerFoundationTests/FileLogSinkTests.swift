import XCTest
@testable import FoyerFoundation

final class FileLogSinkTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("foyer.log")
    }

    func testWritesFormattedLinesAndRotates() throws {
        let url = temporaryURL()
        let sink = FileLogSink(url: url, maxBytes: 300)
        for i in 0..<20 {
            sink.write(LogEntry(level: .info, category: .playback, message: "line \(i) ........"))
        }
        sink.flush()
        let current = try String(contentsOf: url, encoding: .utf8)
        let rotated = try String(contentsOf: sink.rotatedURL, encoding: .utf8)
        XCTAssertTrue(current.contains("[PLAYBACK] INFO: line 19 "), current)
        XCTAssertLessThanOrEqual(current.utf8.count, 300)
        XCTAssertTrue(rotated.contains("line "), "previous file is kept once")
        XCTAssertFalse(current.contains("line 0 "), "old lines were rotated out")
    }

    func testAppendsAcrossLaunches() throws {
        let url = temporaryURL()
        let first = FileLogSink(url: url)
        first.write(LogEntry(level: .notice, category: .ui, message: "first launch"))
        first.flush()
        let second = FileLogSink(url: url)
        second.write(LogEntry(level: .notice, category: .ui, message: "second launch"))
        second.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("first launch"))
        XCTAssertTrue(text.contains("second launch"))
        XCTAssertEqual(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
    }
}
