import XCTest

/// Smoke tour against a real Jellyfin server. Skipped unless `FOYER_REAL_SERVER`, `FOYER_REAL_USER`
/// and `FOYER_REAL_PASSWORD` are set (see `Scripts/e2e-real.sh`). It signs in with username/password,
/// plays the first Continue Watching item, the first movie of the first library and the primary
/// episode of the first series for a few seconds each, and saves screenshots to `FOYER_SHOT_DIR`.
/// Watch state on the server is touched (a few seconds of progress); nothing is marked as played.
final class RealServerTour: XCTestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { .shared }
    private var shotDir: URL?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["FOYER_REAL_SERVER"], !server.isEmpty,
              let user = env["FOYER_REAL_USER"], let password = env["FOYER_REAL_PASSWORD"] else {
            throw XCTSkip("FOYER_REAL_SERVER/USER/PASSWORD not set – run Scripts/e2e-real.sh")
        }
        if let dir = env["FOYER_SHOT_DIR"], !dir.isEmpty {
            shotDir = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: shotDir!, withIntermediateDirectories: true)
        }
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-server", server, "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        if let preset = env["FOYER_CAPABILITIES"], !preset.isEmpty {
            app.launchArguments += ["-capabilities", preset]
        }
        app.launch()
        signInIfNeeded(user: user, password: password)
    }

    override func tearDown() {
        app?.terminate()
    }

    // MARK: Helpers

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        if let shotDir { try? png.write(to: shotDir.appendingPathComponent("\(name).png")) }
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

    private func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

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

    private var home: XCUIElement { app.buttons["Einstellungen"] }

    private func type(_ text: String, into field: XCUIElement) {
        focus(field, path: [(.down, 3), (.up, 3)])
        press(.select) // opens the tvOS keyboard
        wait(1)
        app.typeText(text)
        wait(0.5)
        press(.menu) // dismiss the keyboard, keeping the text
        wait(0.5)
    }

    private func signInIfNeeded(user: String, password: String) {
        let connect = app.buttons["connectButton"]
        if connect.waitForExistence(timeout: 6) {
            shot("00-real-onboarding-server")
            focus(connect, path: [(.down, 2)])
            press(.select)
            let other = app.buttons["otherUserButton"]
            XCTAssertTrue(other.waitForExistence(timeout: 20), "user picker did not appear")
            shot("01-real-onboarding-users")
            // Public users may be listed first; the manual sign-in card is always present.
            focus(other, path: [(.down, 1), (.right, 6)])
            press(.select)
            let username = app.textFields["usernameField"]
            XCTAssertTrue(username.waitForExistence(timeout: 10), "password screen did not appear")
            type(user, into: username)
            let passwordField = app.secureTextFields["passwordField"]
            type(password, into: passwordField)
            shot("02-real-onboarding-password")
            let signIn = app.buttons["signInButton"]
            focus(signIn, path: [(.down, 3)])
            press(.select)
        }
        XCTAssertTrue(home.waitForExistence(timeout: 40), "Home did not appear after sign-in")
        wait(3) // artwork
    }

    private func openTab(_ title: String) {
        press(.up, times: 3, pause: 0.4)
        let tab = app.buttons[title]
        for _ in 0..<6 where !(tab.exists && tab.hasFocus) { press(.right) }
        for _ in 0..<6 where !(tab.exists && tab.hasFocus) { press(.left) }
        wait(2)
    }

    private func leavePlayer(expecting element: XCUIElement) {
        for _ in 0..<4 where !element.exists { press(.menu, pause: 1.2) }
        XCTAssertTrue(element.waitForExistence(timeout: 8), "did not return from player")
    }

    // MARK: Tests

    func test00HomeAndContinueWatching() {
        shot("10-real-home")
        press(.down)
        wait(1)
        shot("11-real-home-first-card")
        press(.select)
        wait(12) // preparation + first frames
        shot("12-real-player-first-card")
        press(.select) // controls (advanced) or pause (native)
        wait(2)
        shot("13-real-player-controls")
        press(.down) // panel (advanced) or nothing (native)
        wait(2)
        shot("14-real-player-panel-or-info")
        press(.menu, pause: 1.2)
        leavePlayer(expecting: home)
        wait(2)
        shot("15-real-home-after-playback")
    }

    func test10FirstMovieDetailAndPlayback() {
        press(.up, times: 3, pause: 0.4)
        press(.right) // first library tab
        wait(2)
        shot("20-real-library")
        press(.down, times: 2)
        wait(1)
        shot("21-real-library-focus")
        press(.select)
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "movie detail did not open")
        wait(2)
        shot("22-real-movie-detail")
        focus(play, path: [(.down, 2), (.up, 3), (.down, 1)])
        press(.select)
        wait(12)
        shot("23-real-movie-player")
        press(.select)
        wait(2)
        shot("24-real-movie-player-controls")
        press(.menu, pause: 1.2)
        leavePlayer(expecting: play)
        wait(1)
        shot("25-real-movie-detail-after")
        press(.menu)
    }

    func test20FirstSeriesAndEpisode() {
        press(.up, times: 3, pause: 0.4)
        press(.right, times: 2) // second library tab (TV)
        wait(2)
        press(.down, times: 2)
        wait(1)
        press(.select)
        let play = app.buttons["seriesPlayButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "series detail did not open")
        wait(2)
        shot("30-real-series-detail")
        focus(play, path: [(.down, 2), (.up, 3), (.down, 1)])
        press(.select)
        wait(12)
        shot("31-real-episode-player")
        press(.select)
        wait(2)
        shot("32-real-episode-player-controls")
        press(.menu, pause: 1.2)
        leavePlayer(expecting: play)
        wait(1)
        shot("33-real-series-detail-after")
        press(.menu)
    }

    func test30SearchAndSettings() {
        openTab("Suche")
        wait(1)
        shot("40-real-search")
        openTab("Einstellungen")
        wait(1)
        shot("41-real-settings")
        let debug = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Entscheidung'")).firstMatch
        if focus(debug, path: [(.down, 16)]) {
            press(.select)
            wait(1.5)
            shot("42-real-last-decision")
            press(.menu)
        }
    }
}
