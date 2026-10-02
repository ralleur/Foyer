import XCTest

/// End-to-end tour against the mock Jellyfin server in `Tools/MockJellyfin`: real HTTP,
/// real media files, both playback engines. It is skipped unless `VELA_MOCK_SERVER` is set;
/// `Scripts/e2e-mock.sh` starts the server, runs this class and collects the screenshots
/// written to `VELA_SHOT_DIR`. Tests are ordered by name; `test00` signs in once.
final class MockServerTour: XCTestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { .shared }
    private var shotDir: URL?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["VELA_MOCK_SERVER"], !server.isEmpty else {
            throw XCTSkip("VELA_MOCK_SERVER not set – run Scripts/e2e-mock.sh")
        }
        if let dir = env["VELA_SHOT_DIR"], !dir.isEmpty {
            shotDir = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: shotDir!, withIntermediateDirectories: true)
        }
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-server", server, "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        signInIfNeeded()
    }

    override func tearDown() {
        app?.terminate()
    }

    // MARK: Helpers

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let shotDir {
            try? png.write(to: shotDir.appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: name, payload: png)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1, pause: TimeInterval = 0.7) {
        for _ in 0..<times {
            remote.press(button)
            Thread.sleep(forTimeInterval: pause)
        }
    }

    private func wait(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func button(labelContaining text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", text, text)
        let button = app.buttons.matching(predicate).firstMatch
        return button.exists ? button : app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Moves focus along `path` (button, max presses) until `element` has focus; returns success.
    @discardableResult
    private func focus(_ element: XCUIElement, path: [(XCUIRemote.Button, Int)]) -> Bool {
        if element.exists, element.hasFocus { return true }
        for (direction, count) in path {
            for _ in 0..<count {
                press(direction)
                if element.exists, element.hasFocus { return true }
            }
        }
        return element.exists && element.hasFocus
    }

    /// Home is identified by its tab bar; the sections vary with the watch state.
    private var home: XCUIElement { app.buttons["Filme"] }

    private func signInIfNeeded() {
        let connect = app.buttons["connectButton"]
        if connect.waitForExistence(timeout: 6) {
            shot("00-onboarding-server")
            focus(connect, path: [(.down, 2)])
            press(.select)
            let user = app.buttons["user-test"]
            XCTAssertTrue(user.waitForExistence(timeout: 20), "user picker did not appear")
            shot("01-onboarding-users")
            focus(user, path: [(.down, 1), (.right, 1), (.left, 2)])
            press(.select)
        }
        XCTAssertTrue(home.waitForExistence(timeout: 30), "Home did not appear after sign-in")
        wait(2) // let artwork settle
    }

    /// Goes to a top-level tab by its title (focus moves through the tab bar).
    private func openTab(_ title: String) {
        press(.up, times: 3, pause: 0.4)
        let tab = app.buttons[title].exists ? app.buttons[title] : app.staticTexts[title]
        if !(tab.exists && tab.hasFocus) {
            for _ in 0..<6 where !(tab.exists && tab.hasFocus) { press(.right) }
        }
        if !(tab.exists && tab.hasFocus) {
            for _ in 0..<6 where !(tab.exists && tab.hasFocus) { press(.left) }
        }
        wait(1.5)
    }

    /// Leaves the player with Menu presses until Home/detail content is visible again.
    private func leavePlayer(expecting element: XCUIElement) {
        for _ in 0..<4 where !element.exists {
            press(.menu, pause: 1.2)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 8), "did not return from player")
    }

    // MARK: Tests

    func test00HomeAndResumeInAdvancedPlayer() {
        shot("02-home")
        press(.down)
        let boreal = button(labelContaining: "Boreal")
        XCTAssertTrue(boreal.waitForExistence(timeout: 5), "Continue Watching should list Boreal")
        focus(boreal, path: [(.left, 3), (.right, 3)])
        shot("03-home-focus-boreal")
        press(.select)
        wait(7) // resume at 12 s → advanced engine; overlay auto-hides after 4 s
        shot("10-player-advanced-boreal")
        press(.select) // show controls
        wait(1)
        shot("11-player-advanced-overlay")
        press(.down) // info / tracks panel
        wait(1.5)
        shot("12-player-advanced-panel-info")
        press(.right) // audio tab
        press(.select)
        wait(1)
        shot("13-player-advanced-panel-audio")
        press(.right) // subtitles tab
        press(.select)
        wait(1)
        shot("14-player-advanced-panel-subtitles")
        press(.down) // into the list
        press(.down) // second entry (first real subtitle track)
        press(.select)
        wait(1)
        press(.menu, pause: 1.0) // close panel
        wait(4)
        shot("15-player-advanced-subtitle-on")
        press(.left, times: 2) // seek back 20 s
        wait(2)
        shot("16-player-advanced-after-seek")
        leavePlayer(expecting: home)
        wait(2)
        shot("17-home-after-playback")
    }

    func test10MovieDetailAndNativePlayer() {
        openTab("Filme")
        shot("20-library-filme")
        let aurora = button(labelContaining: "Aurora")
        focus(aurora, path: [(.down, 2), (.left, 6)])
        XCTAssertTrue(aurora.exists, "Aurora should be in the grid")
        press(.select)
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "movie detail did not open")
        wait(1.5)
        shot("21-detail-aurora")
        focus(play, path: [(.down, 2), (.up, 3), (.down, 1)])
        press(.select)
        wait(7)
        shot("22-player-native-aurora")
        press(.playPause) // pause via system controls (shows transport bar)
        wait(1.5)
        shot("23-player-native-controls")
        press(.playPause)
        wait(1)
        leavePlayer(expecting: play)
        wait(1)
        shot("24-detail-aurora-after-playback")
        press(.menu)
    }

    func test20SeriesSkipIntroAndAutoplay() {
        openTab("Serien")
        shot("30-library-serien")
        let show = button(labelContaining: "Test Show")
        focus(show, path: [(.down, 2), (.left, 3)])
        press(.select)
        let play = app.buttons["seriesPlayButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "series detail did not open")
        wait(1.5)
        shot("31-series-detail")
        XCTAssertTrue(play.label.contains("E"), "primary action should name an episode, got \(play.label)")
        focus(play, path: [(.down, 2), (.up, 3), (.down, 1)])
        press(.select)
        wait(6) // inside the intro segment (3–13 s)
        shot("32-episode2-skip-intro")
        press(.select) // performSkip while the overlay is hidden
        wait(2)
        shot("33-episode2-after-skip")
        wait(20) // credits start at 32 s → countdown card
        shot("34-episode2-countdown")
        wait(9) // countdown reaches zero → E03 (MP4, system player)
        wait(6)
        shot("35-episode3-native-autoplay")
        leavePlayer(expecting: play)
        wait(2)
        shot("36-series-detail-after-playback")
        press(.menu)
    }

    func test30LosslessAudioHDRRemuxAndBrokenFile() {
        openTab("Filme")
        let cascade = button(labelContaining: "Cascade")
        focus(cascade, path: [(.down, 2), (.left, 6), (.right, 3)])
        press(.select)
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        focus(play, path: [(.down, 2), (.up, 3), (.down, 1)])
        press(.select)
        wait(7)
        shot("40-player-cascade-dts")
        press(.select)
        press(.down)
        press(.right)
        press(.select)
        wait(1)
        shot("41-player-cascade-audio-tracks")
        press(.down)
        press(.down) // TrueHD
        press(.select)
        wait(3)
        press(.menu, pause: 1.0)
        wait(1)
        shot("42-player-cascade-truehd")
        leavePlayer(expecting: play)
        press(.menu)
        wait(1.5)

        let dawn = button(labelContaining: "Dawn")
        focus(dawn, path: [(.right, 2), (.down, 1), (.left, 1)])
        press(.select)
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        wait(1)
        shot("43-detail-dawn-hdr")
        focus(play, path: [(.down, 2), (.up, 3), (.down, 1)])
        press(.select)
        wait(10) // remux via HLS takes a moment
        shot("44-player-dawn-hdr-remux")
        press(.playPause)
        wait(1.5)
        shot("44b-player-dawn-hdr-controls")
        press(.playPause)
        leavePlayer(expecting: play)
        press(.menu)
        wait(1.5)

        let broken = button(labelContaining: "Broken")
        focus(broken, path: [(.left, 3), (.right, 2)])
        press(.select)
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        focus(play, path: [(.down, 2), (.up, 3), (.down, 1)])
        press(.select)
        let close = app.buttons["Schließen"]
        XCTAssertTrue(close.waitForExistence(timeout: 60), "broken file should end in the error screen after the fallback chain")
        shot("45-player-broken-error")
        press(.select)
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        press(.menu)
    }

    func test40SearchAndSettings() {
        openTab("Suche")
        wait(1)
        shot("50-search")
        openTab("Einstellungen")
        wait(1)
        shot("51-settings")
        press(.down, times: 3)
        shot("52-settings-scrolled")
        let debug = button(labelContaining: "Debug")
        if focus(debug, path: [(.down, 12)]) {
            press(.select)
            wait(1.5)
            shot("53-settings-debug")
            let decision = button(labelContaining: "Entscheidung")
            if focus(decision, path: [(.down, 4)]) {
                press(.select)
                wait(1.5)
                shot("54-settings-debug-last-decision")
                press(.menu)
            }
            press(.menu)
        }
    }
}
