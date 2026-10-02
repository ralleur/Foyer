import XCTest

/// UI tests run against canned server responses (launch argument `-uitest`), so they
/// need no Jellyfin server. They cover the primary navigation paths on tvOS.
final class VelaUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
    }

    private func waitForHome() {
        XCTAssertTrue(app.staticTexts["Continue Watching"].waitForExistence(timeout: 15), "Home did not show Continue Watching")
    }

    func testHomeShowsSectionsFromServer() {
        waitForHome()
        XCTAssertTrue(app.staticTexts["Next Up"].exists)
        XCTAssertTrue(app.staticTexts["New in Filme"].exists || app.staticTexts["New in Serien"].exists)
        XCTAssertTrue(app.staticTexts["Dune: Part Two"].exists)
    }

    func testMovieDetailShowsPlayAndMetadata() {
        waitForHome()
        let remote = XCUIRemote.shared
        // Move down past Continue Watching / Next Up to the first poster row and open it.
        remote.press(.down)
        remote.press(.down)
        remote.press(.select)
        XCTAssertTrue(app.otherElements["itemDetail"].waitForExistence(timeout: 10) || app.buttons["playButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playButton"].exists)
        XCTAssertTrue(app.buttons["watchedButton"].exists)
        remote.press(.menu)
    }

    func testSeriesNavigationShowsSeasonsAndEpisodes() {
        waitForHome()
        let remote = XCUIRemote.shared
        // Tab bar: Home, Filme, Serien, Search, Settings → move up to the tab bar then right twice.
        remote.press(.up)
        remote.press(.up)
        remote.press(.right)
        remote.press(.right)
        XCTAssertTrue(app.staticTexts["The Expanse"].waitForExistence(timeout: 10))
        remote.press(.down)
        remote.press(.select)
        XCTAssertTrue(app.buttons["seriesPlayButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Season 1"].exists)
        XCTAssertTrue(app.staticTexts["Dulcinea"].waitForExistence(timeout: 10))
        remote.press(.menu)
    }

    func testSettingsShowsAccountAndPlaybackOptions() {
        waitForHome()
        let remote = XCUIRemote.shared
        remote.press(.up)
        remote.press(.up)
        for _ in 0..<5 { remote.press(.right) }
        XCTAssertTrue(app.staticTexts["Audio Language"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Streaming Quality"].exists)
        XCTAssertTrue(app.buttons["signOutButton"].exists)
    }
}
