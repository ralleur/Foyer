# Testing

## Layers

| Layer | Location | Runs on | What it covers |
| --- | --- | --- | --- |
| Core unit tests | `Packages/FoyerCore/Tests` | macOS, Linux (`swift test`), Xcode | Jellyfin model decoding (fixtures), date parsing, open enums, URL/auth header construction, legacy endpoint fallbacks, error mapping, log redaction, server address normalisation, items query encoding, the playback decision matrix (42 tests), device profile shape, reconciliation with server responses, track selection rules, SRT/VTT/ASS parsing and timeline lookup, trickplay geometry, skip/countdown/progress/resume policies |
| App unit tests | `FoyerTests` | tvOS simulator | Integration flows against canned server responses (`FixtureTransport`): server discovery → sign-in → token in Keychain → switch/sign-out; libraries + Home sections + snapshot; library paging and series/season/episode models; `PlaybackCoordinator` with a mock engine (resume position, default German audio + forced subtitles, in-place vs. reload track switches, fallback after engine failure, close/stop) and the start/progress/stop reports the server receives; preferences persistence and defaults, error presentation, image downsampling, subtitle text decoding, track titles |
| UI tests | `FoyerUITests` | tvOS simulator | Home sections, movie detail (play/watched buttons), series navigation (season chips, episode rows), settings screen. The app is launched with `-uitest`, which installs a fake session and a `FixtureTransport` that serves JSON from `Foyer/Resources/UITestFixtures`; no Jellyfin server is needed |
| End-to-end tour | `FoyerUITests/MockServerTour` + `Tools/MockJellyfin` | tvOS simulator + local mock server | Real HTTP, real media files, both engines: onboarding → Home → resume in the advanced player (panel, tracks, subtitles, seek) → movie detail → system player → series with skip intro, next-episode countdown and autoplay → DTS/TrueHD track switching → HDR10 remux via HLS → broken file through the fallback chain to the error screen → search and settings. Every step leaves a screenshot |

## Running

```bash
# Core (no Xcode needed)
Scripts/test-core.sh                      # = cd Packages/FoyerCore && swift test

# App + UI tests on a simulator
Scripts/test-app.sh                       # FoyerTests only
xcodebuild -project Foyer.xcodeproj -scheme Foyer \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' test
```

## End-to-end tour with the mock server

```bash
Tools/MockJellyfin/make-media.sh          # once: ~30 MB of synthetic clips (needs ffmpeg with x264/x265)
Scripts/e2e-mock.sh                       # starts the server, reinstalls the app, runs MockServerTour, saves screenshots
open build/e2e/shots                      # numbered PNGs per step; server log next to them
```

The mock server can also be used interactively: `Tools/MockJellyfin/server.py --media Tools/MockJellyfin/media` and sign in as user `test` (no password) from a simulator or an Apple TV on the same network. It implements the endpoints listed in JELLYFIN.md, keeps watch state in memory and transcodes/remuxes to HLS with ffmpeg when the app asks for server help. It is a test tool, not a Jellyfin replacement.

## Status

- Core: 103 tests, all passing (Linux with Swift 6.2.4 and macOS with Xcode 27).
- App unit tests (`FoyerTests`): 19 tests passing on the tvOS 27 simulator.
- UI tests (`FoyerUITests`, fixtures): run on the simulator; see the notes in DEVELOPMENT.md for the focus-navigation fixes they triggered.
- End-to-end tour (`Scripts/e2e-mock.sh`): all five `MockServerTour` tests pass on the tvOS 27 simulator (≈ 6 minutes; the app is reinstalled and the mock server restarted for every run so watch state starts from the fixture defaults).

## Manual test plan (device)

Playback matrix (see PLAYBACK.md) on a real Apple TV 4K with an HDR display and an AV receiver:

1. For each row, open the title, check *Settings › Debug › Last playback decision* matches the expected path, confirm picture (HDR indicator on the TV for native HDR routes), audio format on the receiver, and that the server dashboard shows *Direct Play* / *Direct Stream* / *Transcode* accordingly.
2. Subtitles: forced German with German audio, full German with English audio, ASS styling in the advanced engine, PGS selection from the native engine (engine switch keeps position), delay ±.
3. Seeking: scrub in a 4K remux (MKV, advanced) and in an HLS transcode; verify position, subtitles and A/V sync after the seek; 10 s skips.
4. Resume: stop at 20 min, reopen from Home (Continue Watching), from details (button text), and from the series screen.
5. Watch state: dashboard shows progress within 10 s; pause is reflected; closing the app mid-playback keeps the position.
6. Skip intro / next episode with a Jellyfin 10.10 server (segments) and with Intro Skipper; autoplay on/off; cancel via Menu.
7. Lifecycle: press the TV button during playback, wait for the screensaver, unplug HDMI, switch Wi-Fi off/on; playback must pause, not run in the background, and resume cleanly.
8. Memory: Play/Stop 20× on 4K remuxes in both engines; watch the memory gauge in Xcode for growth. Browse a 2 000-movie library end to end; image memory must stay bounded (120 MB decoded cap).
9. Accessibility: VoiceOver over Home, details, player panel; Reduce Motion (no scale animations); Reduce Transparency (solid backdrops).
10. Network: server unreachable at launch (friendly error + retry), wrong password, expired token (returns to onboarding with the server pre-filled), reverse proxy with base path.

## Adding tests

- New Jellyfin fields: add to the fixture JSON under `Packages/FoyerCore/Tests/JellyfinKitTests/Fixtures` and assert in `ModelDecodingTests`.
- New decision rules: extend `TestMedia` builders and add a `DecisionEngineTests` case; update the matrix in PLAYBACK.md.
- New screens: add fixtures to `Foyer/Resources/UITestFixtures`, route them in `FixtureTransport.respond`, and give interactive elements `accessibilityIdentifier`s.
