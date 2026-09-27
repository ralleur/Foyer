# Testing

## Layers

| Layer | Location | Runs on | What it covers |
| --- | --- | --- | --- |
| Core unit tests | `Packages/VelaCore/Tests` | macOS, Linux (`swift test`), Xcode | Jellyfin model decoding (fixtures), date parsing, open enums, URL/auth header construction, legacy endpoint fallbacks, error mapping, log redaction, server address normalisation, items query encoding, the playback decision matrix (42 tests), device profile shape, reconciliation with server responses, track selection rules, SRT/VTT/ASS parsing and timeline lookup, trickplay geometry, skip/countdown/progress/resume policies |
| App unit tests | `VelaTests` | tvOS simulator | Integration flows against canned server responses (`FixtureTransport`): server discovery → sign-in → token in Keychain → switch/sign-out; libraries + Home sections + snapshot; library paging and series/season/episode models; `PlaybackCoordinator` with a mock engine (resume position, default German audio + forced subtitles, in-place vs. reload track switches, fallback after engine failure, close/stop) and the start/progress/stop reports the server receives; preferences persistence and defaults, error presentation, image downsampling, subtitle text decoding, track titles |
| UI tests | `VelaUITests` | tvOS simulator | Home sections, movie detail (play/watched buttons), series navigation (season chips, episode rows), settings screen. The app is launched with `-uitest`, which installs a fake session and a `FixtureTransport` that serves JSON from `Vela/Resources/UITestFixtures`; no Jellyfin server is needed |
| End-to-end tour | `VelaUITests/MockServerTour` + `Tools/MockJellyfin` | tvOS simulator + local mock server | Real HTTP, real media files, both engines: onboarding → Home → resume in the advanced player (panel, tracks, subtitles, seek) → movie detail → system player → series with skip intro, next-episode countdown and autoplay → DTS/TrueHD track switching → HDR10 remux via HLS → broken file through the fallback chain to the error screen → search and settings. Every step leaves a screenshot |

## Running

```bash
# Core (no Xcode needed)
Scripts/test-core.sh                      # = cd Packages/VelaCore && swift test

# App + UI tests on a simulator
Scripts/test-app.sh                       # VelaTests only
xcodebuild -project Vela.xcodeproj -scheme Vela \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' test
```

## End-to-end tour with the mock server

```bash
Tools/MockJellyfin/make-media.sh          # once: ~30 MB of synthetic clips (needs ffmpeg with x264/x265)
Scripts/e2e-mock.sh                       # starts the server, reinstalls the app, runs MockServerTour, saves screenshots
open build/e2e/shots                      # numbered PNGs per step; server log next to them
```

## Smoke tour against a real server

```bash
VELA_REAL_SERVER=http://server:8096 VELA_REAL_USER=name VELA_REAL_PASSWORD=secret \
VELA_CAPABILITIES=appleTV4K Scripts/e2e-real.sh
```

`VelaUITests/RealServerTour` signs in with username/password, plays the first Continue Watching item, the first movie and the primary episode of the first series for a few seconds each and saves screenshots; the script polls `/Sessions` meanwhile and writes what the server sees (play method, position, transcoding info) to `build/e2e-real/sessions.log`. Credentials are read from the environment only. `VELA_CAPABILITIES` maps to the `-capabilities` launch argument (`appleTV4K`, `appleTV4KSDR`, `appleTVHD`; debug builds only) so the simulator decides routes like a real box. The tour touches watch state (a few seconds of progress per item); Jellyfin discards positions under five minutes on stop, a resumed item keeps its new position.

The mock server can also be used interactively: `Tools/MockJellyfin/server.py --media Tools/MockJellyfin/media` and sign in as user `test` (no password) from a simulator or an Apple TV on the same network. It implements the endpoints listed in JELLYFIN.md, keeps watch state in memory and transcodes/remuxes to HLS with ffmpeg when the app asks for server help. It is a test tool, not a Jellyfin replacement.

## Status

- Core: 112 tests, all passing (Linux with Swift 6.2.4 and macOS with Xcode 27).
- App unit tests (`VelaTests`): 27 tests passing on the tvOS 27 simulator, including the FFmpeg-backed bitmap subtitle decoder on `VelaTests/Fixtures/pgs-sample.mkv` (synthetic PGS track made by `Scripts/make-pgs-fixture.py`, no third-party content).
- UI tests (`VelaUITests`, fixtures): run on the simulator; see the notes in DEVELOPMENT.md for the focus-navigation fixes they triggered.
- End-to-end tour (`Scripts/e2e-mock.sh`): all five `MockServerTour` tests pass on the tvOS 27 simulator (≈ 6 minutes; the app is reinstalled and the mock server restarted for every run so watch state starts from the fixture defaults).

## On the Apple TV

```bash
Scripts/install-device.sh Wohnzimmer            # signed Debug build → install → launch (pair once with xcrun devicectl manage pair)
Scripts/device-logs.sh Wohnzimmer 200           # pulls Library/Caches/Logs/vela.log from the app container
JF_SERVER=http://host:8096 JF_USER=… JF_PW=… Scripts/remote.py sessions      # what the server sees (play method, transcoding)
JF_SERVER=… JF_USER=… JF_PW=… Scripts/remote.py play "Dune" --position 600   # "Play on" the box through the session socket
JF_SERVER=… JF_USER=… JF_PW=… Scripts/remote.py watch 120                     # follow position/play method for two minutes
```

`remote.py` targets the Vela session whose device name is "Apple TV" (a real box; simulators report their model) and also sends pause/seek/stop/next, audio/subtitle switches and messages, so the playback matrix below can be driven from the Mac while the TV is watched.

Debug-build launch arguments (`xcrun devicectl device process launch … com.ralleur.vela -- <args>`, `xcrun simctl launch … <args>`):

| Argument | Effect |
| --- | --- |
| `-server http://host:8096` | pre-fills the server field |
| `-capabilities appleTV4K\|appleTV4KSDR\|appleTVHD` | decide routes like that box (simulator) |
| `-play-url <url>` | show a stock AVPlayer for the URL and log its diagnostics (isolates a stream problem from the app) |
| `-audio-channels N` | preferred audio output channels (0 = route default; default is min(max, 8)) |
| `-play-seek S`, `-play-seek-after T` | with `-play-url`: seek to S seconds after T seconds (default 12) and log what AVPlayer does |

Verified on an Apple TV 4K (2022, tvOS 26.6, HDMI to a TV) on 2026-09-27: sign-in, Home, remote control, HDR10 MKV remux (Direct Stream, HDR kept), Dolby Vision WEBRip (RPU stripped by the server), DV profile 7 remux (HDR10 base layer, TrueHD → AC-3), DV profile 8 MKV with PGS in the advanced engine (VideoToolbox, tone-mapped), H.264 MP4 direct play, resume position restore, seeking to 30 min in a remux, pause/resume and messages by remote control, text subtitles switched on/off in the system player without flipping back, a German PGS track drawn over an HDR remux (start at 20 min, first bitmap decoded from the original file within a second of playback). Not yet verified on the device: audio passthrough on an AV receiver, HLG, frame-rate switching for the native engine, seeking in remuxes, TestFlight builds.

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

- New Jellyfin fields: add to the fixture JSON under `Packages/VelaCore/Tests/JellyfinKitTests/Fixtures` and assert in `ModelDecodingTests`.
- New decision rules: extend `TestMedia` builders and add a `DecisionEngineTests` case; update the matrix in PLAYBACK.md.
- New screens: add fixtures to `Vela/Resources/UITestFixtures`, route them in `FixtureTransport.respond`, and give interactive elements `accessibilityIdentifier`s.
