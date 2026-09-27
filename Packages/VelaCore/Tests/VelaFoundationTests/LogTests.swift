import XCTest
@testable import VelaFoundation

final class LogRedactionTests: XCTestCase {
    func testRedactsQueryTokens() {
        let msg = "GET /Videos/1/stream?api_key=abc123DEF&static=true"
        XCTAssertEqual(Log.redact(msg), "GET /Videos/1/stream?api_key=•••&static=true")
        XCTAssertEqual(Log.redact("X-Emby-Token=secret99"), "X-Emby-Token=•••")
    }

    func testRedactsAuthorizationHeaderToken() {
        let header = "MediaBrowser Client=\"Vela\", Token=\"deadbeef\""
        XCTAssertEqual(Log.redact(header), "MediaBrowser Client=\"Vela\", Token=\"•••\"")
    }

    func testRedactsJSONFields() {
        let json = #"{"AccessToken":"tok123","Pw":"hunter2","Username":"anna"}"#
        let redacted = Log.redact(json)
        XCTAssertFalse(redacted.contains("tok123"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("anna"))
    }

    func testRedactsRegisteredSecrets() {
        XCTAssertEqual(Log.redact("token appears here: XYZSECRET", secrets: ["XYZSECRET"]), "token appears here: •••")
    }

    func testBufferKeepsCapacity() {
        let buffer = LogBuffer(capacity: 3)
        for i in 0..<5 {
            buffer.write(LogEntry(level: .info, category: .ui, message: "m\(i)"))
        }
        XCTAssertEqual(buffer.snapshot.map(\.message), ["m2", "m3", "m4"])
    }

    func testLoggerRoutesToSinkAndRedacts() {
        let buffer = LogBuffer()
        let log = Log()
        log.configure(sinks: [buffer], minimumLevel: .info)
        log.registerSecret("SUPERSECRET")
        log.log(.debug, .network, "hidden")
        log.log(.info, .network, "token SUPERSECRET used")
        XCTAssertEqual(buffer.snapshot.count, 1)
        XCTAssertEqual(buffer.snapshot.first?.message, "token ••• used")
    }
}

final class LanguageCodeTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(LanguageCode.normalize("ger"), "de")
        XCTAssertEqual(LanguageCode.normalize("deu"), "de")
        XCTAssertEqual(LanguageCode.normalize("de-DE"), "de")
        XCTAssertEqual(LanguageCode.normalize("DE"), "de")
        XCTAssertEqual(LanguageCode.normalize("eng"), "en")
        XCTAssertEqual(LanguageCode.normalize("jpn"), "ja")
        XCTAssertNil(LanguageCode.normalize("und"))
        XCTAssertNil(LanguageCode.normalize(nil))
        XCTAssertNil(LanguageCode.normalize(""))
        XCTAssertEqual(LanguageCode.normalize("xyz"), "xyz")
    }

    func testMatching() {
        XCTAssertTrue(LanguageCode.matches("ger", "de"))
        XCTAssertTrue(LanguageCode.matches("en-US", "eng"))
        XCTAssertFalse(LanguageCode.matches("und", "und"))
        XCTAssertFalse(LanguageCode.matches("de", "en"))
    }

    func testDisplayName() {
        XCTAssertEqual(LanguageCode.displayName("ger", locale: Locale(identifier: "en_US")), "German")
    }
}

final class TicksAndErrorTests: XCTestCase {
    func testTicks() {
        XCTAssertEqual(JellyfinTicks.seconds(Int64(15) * JellyfinTicks.perSecond), 15)
        XCTAssertEqual(JellyfinTicks.ticks(seconds: 1.5), 15_000_000)
        XCTAssertEqual(JellyfinTicks.ticks(seconds: -3), 0)
        XCTAssertEqual(JellyfinTicks.ticks(seconds: .nan), 0)
    }

    func testClockString() {
        XCTAssertEqual(TimeInterval(65).clockString, "1:05")
        XCTAssertEqual(TimeInterval(3661).clockString, "1:01:01")
        XCTAssertEqual(TimeInterval(-4).clockString, "0:00")
        XCTAssertEqual(TimeInterval(5400).wholeMinutes, 90)
    }

    func testURLErrorMapping() {
        XCTAssertEqual(VelaError.wrap(URLError(.notConnectedToInternet)).kind, .networkInterrupted)
        XCTAssertEqual(VelaError.wrap(URLError(.cannotFindHost)).kind, .serverUnreachable)
        XCTAssertEqual(VelaError.wrap(URLError(.serverCertificateUntrusted)).kind, .certificateUntrusted)
        XCTAssertEqual(VelaError.wrap(URLError(.timedOut)).kind, .serverUnreachable)
        XCTAssertEqual(VelaError.wrap(CancellationError()).kind, .cancelled)
        let existing = VelaError(.notFound, detail: "x")
        XCTAssertEqual(VelaError.wrap(existing), existing)
    }
}
