# Development Log

Only decisions that shape the product or architecture. Newest at the bottom.

## Environment for the initial build-out

**Problem:** The initial implementation was produced in a Linux container without Xcode or a tvOS SDK.
**Decision:** Everything that does not need UIKit/AVFoundation lives in a Swift package (`Packages/VelaCore`) that builds and tests on Linux with Swift 6.2. The tvOS app target was written against documented APIs (availability verified against Apple's documentation index) but could not be compiled in that environment. The Xcode project is generated from `project.yml` with XcodeGen (built from source on Linux) so the project file itself is reproducible.
**Consequence:** The first `xcodebuild` on a Mac surfaced a handful of compile issues in the app target (see "First local build" below); the core logic (Jellyfin client, decision engine, track selection, subtitle parsing, policies) was already covered by 103 passing tests.

## Playback engines

**Problem:** AVFoundation plays MP4/MOV with H.264/HEVC/AAC/AC-3/E-AC-3 flawlessly (with HDR10, HLG, Dolby Vision) but nothing else. Home cinema libraries are largely MKV with DTS, TrueHD, FLAC, ASS and PGS.
**Options:** VLCKit 3 (LGPL, no proper HDR tone-mapping, no DV profile 5), MPVKit (LGPL build available, mpv 0.41 + FFmpeg 9, libass, libplacebo tone-mapping, libdovi), KSPlayer (GPL, rejected), custom FFmpeg → VideoToolbox → AVSampleBufferDisplayLayer pipeline (best possible result, weeks of work, untestable here).
**Decision:** Two engines behind one `PlaybackEngine` protocol. Native = AVFoundation in `AVPlayerViewController`. Advanced = libmpv via MPVKit (LGPL variant, pinned to 1.0.0). The UI never knows which one is active.

## HDR on the advanced engine

**Problem:** tvOS has no EDR path for a `CAMetalLayer` (`wantsExtendedDynamicRangeContent` is not available on tvOS), so mpv cannot output true HDR; it tone-maps to SDR.
**Decision:** The decision engine routes HDR/Dolby Vision content to the system player whenever the *video* stream is compatible. For an HDR MKV that means a server remux to fMP4/HLS (video copied, container changed) instead of local MKV playback, accepting an audio re-encode when the track is TrueHD/DTS. The advanced engine still plays HDR (tone-mapped) when the user forces direct play, disables server help, or selects bitmap subtitles. This is a data-driven capability flag (`advancedEngineSupportsHDROutput`) and flips the moment HDR output becomes possible.

## Subtitles without server work

**Problem:** Jellyfin burns in subtitles ("Preparing subtitles…") whenever the client cannot handle them.
**Decision:** Text subtitles (SRT/ASS/VTT) on the native engine are fetched as external streams and rendered by Vela's own overlay (SRT/VTT/ASS parsers live in the core package); mpv renders everything itself including PGS/VobSub with libass styling. Selecting a bitmap track while the system player is active transparently switches engines at the current position. Burn-in is only used when no engine can show the track (advanced engine unavailable) and can be disabled.

## Device profile per decision

**Problem:** One static device profile cannot express "MKV is fine locally but for HDR we want a remux".
**Decision:** The client decides locally first (`PlaybackDecisionEngine`), then sends a profile tailored to the chosen engine to `PlaybackInfo`; the server response is reconciled (`reconcile`) and the server keeps the final word on remux vs. transcode. Every decision is logged with reasons and shown in the debug screen.

## Language defaults

**Decision:** Audio: German → English → original → default track. Subtitles: "smart" mode shows forced subtitles when the audio is in the primary language and full subtitles in the preferred language otherwise; unknown audio language counts as understood to avoid surprising subtitles. All configurable in Settings.

## Navigation and player UI

**Decision:** Native engine uses the system transport bar plus contextual actions (skip intro), `AVContentProposal` (next episode), custom transport menus (Jellyfin audio/subtitle lists) and chapter markers. Advanced engine gets a custom overlay that mirrors tvOS conventions: click for controls, swipe to scrub with trickplay previews, swipe down for info/tracks/chapters, Menu to hide or leave.

## Watch state

**Decision:** Progress reports every 10 s while playing, immediately on pause/resume/seek/track change, flushed on background, stop report on close with `Videos/ActiveEncodings` cleanup for transcodes. Resume ignores positions in the first 20 s or last 15 s.

## Deployment target

**Decision:** tvOS 17.0 — needed for `@Observable`, `navigationDestination(item:)` and `AVDisplayCriteria(refreshRate:formatDescription:)`; covers every Apple TV 4K and the Apple TV HD.

## Licensing

**Decision:** The repository is GPL-3.0 (owner's choice). Third-party code is limited to LGPL/MIT/BSD/Apache components via MPVKit's LGPL build; no GPL dependencies. See LICENSES.md for App Store considerations.

## First local build (Xcode 27, tvOS 27 SDK)

**Problem:** The app target had never been compiled. Nine compile errors surfaced: `SortOrder` ambiguous between Foundation and JellyfinKit, missing `AVKit` import for `AVDisplayManager`, main-actor state read inside `async let` initialisers, a `let` that needed mutation, a `URL??` from `map`, and a ternary over closures the type checker could not resolve.
**Decision:** Fix in place, no architectural changes. The app now builds warning-free for the tvOS simulator; unit and UI tests run.

## End-to-end verification without a Jellyfin login

**Problem:** Playback, watch state and the fallback chain can only be trusted after running against real HTTP and real media, but the real server needs credentials the build machine does not have.
**Decision:** `Tools/MockJellyfin` — a generator for a small synthetic library (H.264/MP4, HEVC/MKV with AC-3, DTS, TrueHD, FLAC, HDR10, SRT/ASS, chapters, a series with intro/credits markers, one deliberately broken file) and a Python server that implements the Jellyfin endpoints Vela uses, including Range requests, on-demand subtitle extraction, an ffmpeg-based HLS remux/transcode and in-memory watch state. `Scripts/e2e-mock.sh` runs `VelaUITests/MockServerTour` against it and collects screenshots. Nothing of this ships in the app.

## Bugs found by the end-to-end run

- **mpv `loadfile` signature.** Since mpv 0.38 the third positional argument is the playlist index; options are the fourth. The advanced engine failed every load with "invalid parameter" and silently fell back to a server transcode. Fixed with the four-argument form plus a fallback to the legacy form for older libmpv builds.
- **mpv list options.** `stream-lavf-o` is a key/value list; a value containing a comma (`reconnect_on_http_error=4xx,5xx`) broke the whole option. Entries are now appended one by one. Options that need Lua (`osc`, `ytdl`) do not exist in the MPVKit build and were removed.
- **Fallback lost the resume position.** When an engine failed before producing a frame, the fallback restarted at 0:00 instead of the requested position. The coordinator now remembers the requested start.
- **Detail screens focused the overview instead of Play.** `prefersDefaultFocus` needs the focus scope on the whole screen, not on the action row.

## Keychain on unsigned simulator builds

**Problem:** `xcodebuild … CODE_SIGNING_ALLOWED=NO` produces a simulator app without entitlements; `SecItemAdd` fails with `errSecMissingEntitlement` and every relaunch asked to sign in again.
**Decision:** `KeychainStore` falls back to a JSON file in the app container **only** on the simulator and only when the Keychain reports the missing entitlement. Device builds keep tokens exclusively in the Keychain.

## Development launch argument

**Decision:** `-server http://host:8096` pre-fills the server field on the welcome screen (standard `-key value` → `UserDefaults` mechanism). Used by the mock tour and handy on the simulator; it does not bypass sign-in.

## MPVKit packaging

**Observation:** MPVKit's xcframeworks are static archives wrapped in `.framework` bundles. The linker folds mpv/FFmpeg into the app binary; Xcode still embeds the framework folders, each with a small stub dylib (`MinimumOSVersion 100.0`, never loaded). This is Xcode's standard handling of static frameworks from packages and is accepted by App Store validation, but it explains the ~30 empty-looking frameworks in the bundle. Nothing to do.

## First run against the real Jellyfin server (10.11)

**Observation:** Sign-in, Home, resume at 25 min, direct play of 4K HEVC MKV through mpv, forced-subtitle selection and progress reporting all worked on the first attempt (`Scripts/e2e-real.sh`). But an HDR/Dolby Vision MKV that should have been *remuxed* for the system player came back as a full H.264 transcode with reason `VideoCodecTagNotSupported`.
**Cause:** The native device profile required `VideoCodecTag ∈ hvc1|dvh1`. MKV sources have no codec tag, so the required condition fails and Jellyfin re-encodes the video instead of copying it (it adds `-tag:v hvc1` itself when remuxing HEVC into fMP4).
**Decision:** The condition stays but is no longer required (Jellyfin's Safari profile does the same). `hev1`-tagged MP4s still fail the check and are remuxed instead of direct-played.

## Jellyfin's 8 Mbit/s default

**Problem:** After fixing the codec-tag condition the server still re-encoded the HDR MKV. The transcoding URL carried `VideoBitrate=7680000`: Jellyfin's `DeviceProfile` defaults `MaxStreamingBitrate`/`MaxStaticBitrate` to 8 Mbit/s when a client omits them, and a 4K stream above that limit cannot be copied.
**Decision:** The profiles and the `PlaybackInfo` request always send an explicit ceiling — the user's quality setting or 200 Mbit/s for "original quality". With that, the same request yields an fMP4 remux with the HEVC/Dolby Vision stream copied (`dvh1`). `reconcile` now also recognises such remuxes as Direct Stream although Jellyfin flags `SupportsDirectStream=false` for every MKV conversion.

## Jellyfin's SDR entrance for HDR remuxes

**Observation (logging proxy between app and server):** For the HDR MKV Jellyfin's master playlist advertised two variants — the HEVC/Dolby Vision copy (`VIDEO-RANGE=PQ`, `SUPPLEMENTAL-CODECS="dvh1.08.06/db1p"`) and an H.264/SDR re-encode with identical `BANDWIDTH`. The simulator's AVPlayer picked the H.264 variant because it cannot play Dolby Vision, which is why the server kept encoding although the copy was available and chosen by the app. Probing with curl showed that Jellyfin adds this "SDR entrance" whatever the profile says (transcoding codec list, direct-play codecs, range conditions), so it cannot be suppressed from the client.
**Decision:** Nothing to change in the profile (an attempt to list only the source codec was reverted as ineffective). The app's decision, `PlaybackInfo` request and reported play method are correct; whether AVPlayer takes the HEVC/DV variant is verified on a real Apple TV 4K (device test plan).

## First install on a real Apple TV 4K (tvOS 26.6)

**Observation:** Xcode 27 has no *Devices and Simulators* window; wireless pairing is done with `xcrun devicectl manage pair --device <name>` (the TV shows the code under *Remote App and Devices*). The first signed build failed with *"Your team has no devices from which to generate a provisioning profile"* because `generic/platform=tvOS` never registers a device.
**Decision:** `Scripts/install-device.sh` builds for the concrete device (`platform=tvOS,id=<udid>`) with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`; the first run registers the Apple TV and creates the development profile, later runs are incremental. Bash 3.2 gotcha on the way: `"$UDID…"` (ellipsis right after the name) is parsed as an unbound variable, so the script uses `${UDID}`.

## Remote control was advertised, not implemented

**Observation:** The capabilities posted after sign-in claimed `SupportsMediaControl` with `Play`/`PlayState` commands, but the app never opened the session WebSocket, so Jellyfin listed the Apple TV as *not* remote-controllable and "Play on Vela" in the web UI did nothing. A claim without an implementation.
**Decision:** `RemoteControlService` keeps `/socket` open while signed in (keep-alive replies, backoff reconnect, suspended in the background) and `AppEnvironment` handles `Play` (item, position, tracks), `Playstate` (pause/seek/stop/next…) and `GeneralCommand` (`DisplayMessage` banner, track switches). Play queues do not exist in Vela, so `PlayNext`/`PlayLast` are declined with a log line instead of being faked. First device run: the handshake failed with 403 "Token is required" because the token was passed as `api_key` in the query, which 10.11 does not accept on `/socket`; the `Authorization: MediaBrowser … Token=` header works and the server answers with `ForceKeepAlive` right away. The protocol parsing lives in JellyfinKit (`SessionMessage`) and is unit-tested; the app test feeds frames through the dispatcher and checks the presented player. Side effect: device tests can now be driven from the Mac (`Scripts/remote.py`).

## Logs from the device

**Problem:** `log collect` for a paired Apple TV needs `sudo`, Xcode 27's console needs the app started from Xcode, and the debug screen's ring buffer is gone after a crash.
**Decision:** `FileLogSink` (VelaFoundation) appends every entry to `Library/Caches/Logs/vela.log` (2 MB, one rotation, serial queue, failures ignored); `Scripts/device-logs.sh` copies it out of the app container with `xcrun devicectl device copy from --domain-type appDataContainer`, which works for development-signed builds without a debugger.

## First playback on the Apple TV: every HEVC remux failed with CoreMediaErrorDomain 'nope'

**Observation:** On the Apple TV 4K (tvOS 26.6) every server remux for the system player (Konklave HDR10, The Invite, Companion) reported *ready*, played for about a second and failed with `CoreMediaErrorDomain 1852797029` (`'nope'`); the same streams played in the simulator. The fallback chain then retried *Transcode* (which Jellyfin answered with the same remux) and finally landed in the advanced engine, tone-mapped to SDR.
**Investigation:** `-play-url <url>` (debug builds) shows a stock `AVPlayerViewController` for any URL and `AVPlayerDiagnostics` logs the error chain, tracks, format descriptions and access/error logs. With it, from the Mac and without rebuilding: Jellyfin's own output copied to a local HTTP server failed; repackaging with local ffmpeg (with/without `hevc_mp4toannexb`, with/without edit lists) failed; **Apple's own HEVC and H.264 sample streams failed**; a video-only fMP4 played; an audio-only E-AC-3 playlist failed at once. So AVPlayer could not open audio at all. The audio session reported `HDMIOutput(32ch)`, `outputNumberOfChannels 32` and **`sampleRate 0 Hz`**, whatever the preferred channel count, and the advanced engine (its own AVFoundation output unit at 48 kHz/6 ch) kept working, with the reported position jumping back every ~10 s. After `xcrun devicectl device reboot` the route reported 48 kHz, Apple's samples played, and the Jellyfin remuxes played through the native engine (HDR10 kept, Dolby Vision WEBRip, DV profile 7 with TrueHD → AC-3).
**Cause (best supported):** the first build asked `AVAudioSession` for `maximumOutputNumberOfChannels` = 32 preferred output channels on an HDMI route. tvOS 26 reports 32 there, HDMI carries 8 PCM channels, and the audio server stayed in a broken 32-channel/0 Hz state across app launches until the reboot (another AVPlayer app crashed in the meantime).
**Decision:** `AudioSessionController` caps the preference at 8 channels and sets it *before* activating the session; `-audio-channels N` (debug) overrides it for experiments. `Scripts/install-device.sh` now fails when xcodebuild fails instead of installing the previous binary (which hid two of the experiments). The variant lab is worth repeating from a scratch directory: capture the master/media playlist, init and first segments with the app's own query parameters, repackage with ffmpeg, serve with `python3 -m http.server`, launch with `-play-url`.

## Dual-layer Dolby Vision (profile 7)

**Observation:** *Dune: Part Two* (UHD remux, DV profile 7 with enhancement layer, TrueHD) failed immediately in the native engine with `AVFoundationErrorDomain -11855` ("cannot be decoded on this device"). The profile listed `DOVIWithEL`/`DOVIWithELHDR10Plus` as supported ranges, so Jellyfin copied the profile-7 stream with a `dvh1` tag; Apple TV decodes DV profiles 5 and 8 only.
**Decision:** The native profile no longer claims dual-layer DV. Jellyfin then reports `VideoRangeTypeNotSupported`, strips RPU/EL (`hevc_metadata=remove_dovi=1`) and copies the HDR10 base layer — verified on the device (Direct Stream, HDR10, TrueHD → AC-3). Profile 8 with an HDR10-compatible base layer stays `dvh1`; "DOVIInvalid" WEBRips (profile 8 RPU on BT.709-tagged x265, common on YTS-style releases) are handled the same way by the server.

## Subtitle downloads time out on first use

**Observation:** `Subtitle load failed: serverUnreachable: URLError -1001` while a 4K remux started: Jellyfin extracts embedded subtitles from the file on the first request, which takes longer than the 20 s request timeout.
**Decision:** The subtitle session waits up to 120 s.

## Routing note from the device run

A Dolby Vision profile 8 MKV with TrueHD and a German PGS track selected (English audio) goes to the advanced engine and is tone-mapped: the system player cannot show PGS and burn-in would cost a full transcode. Subtitles the user asked for win over HDR; the decision screen says so. Switching the subtitle off moves such titles to the HDR remux.

## Seeking in a remux failed on the device — for one file

**Observation:** Seeking a remuxed HDR title from 0:12 to 30:00 on the Apple TV failed with `CoreMediaErrorDomain -19602`; Jellyfin's log showed the restart at `-ss 00:09:25 -start_number 94`, so AVPlayer had asked for segment 94 instead of 299. The simulator (which plays the H.264 variant) asked for 299. With `-play-url … -play-seek 1800` behind a logging proxy the stock player did the same (segments 91–94). Fetching the fresh remux showed why: segment 2 starts at 8.6 s, segments 3+ carry video timestamps around 1295 s in 44 ms steps while the playlist declares 6.006 s each — ffmpeg loses the timeline in this MKV (`EBML number … exceeds max length` at 3 MB: the file is damaged). AVPlayer builds its seek map from the timestamps it has seen and lands in the wrong place; the same seek in a healthy file (The Invite) lands exactly.
**Decision:** Nothing to fix in the packaging. Two things were wrong on our side and are fixed: after a failed seek the fallback resumed at the *pre-seek* position (stale time updates from AVPlayer overwrote the target) — the coordinator now keeps the seek target until the engine confirms it and resumes there; and seek diagnostics (target, seekable ranges, landing) are logged.

## Device diagnostics kit

`-play-url <url>` with `-play-seek <s>` (`-play-seek-after <s>`, default 12) plus a logging proxy on the Mac (`proxy.py` in a scratch directory forwarding to Jellyfin) shows exactly which playlists and segments the box requests, with the AppleCoreMedia user agent; `AVPlayerDiagnostics` logs the error chain, tracks and format descriptions. This found the audio-route problem, the profile-7 rejection and the damaged file within an afternoon; keep it.

## Renamed to Vela (2026-09-27)

**Decision:** The app is called **Vela** (it was "Foyer" until today). Product name, bundle identifier (`com.ralleur.vela`), Jellyfin client name, Xcode project/scheme, modules (`VelaCore`, `VelaFoundation`), test targets, scripts, log file (`vela.log`) and docs were renamed in one mechanical pass; only the GitHub repository keeps its old name until it is renamed there. The new bundle identifier is a new app for tvOS: it installs next to the old one and starts signed out, so the old "Foyer" app was removed from the box and the account entered again. Jellyfin lists the box as client "Vela" from now on; the old "Foyer" sessions expire on their own.

## Home-screen tile

**Decision:** The supplied tile (navy background, cream V, blue dot) became the layered tvOS icon: `Back` = solid background colour, `Front` = the logo cut out of the flattened image by colour distance (background grain < 10, the JPEG's black corners ≈ 40, logo > 260 on a 0–441 scale), un-blended at the edges so the parallax layer has clean colours; `Middle` stays empty. The same logo, smaller and centred, fills the Top Shelf images (1920×720, 2320×720). Sizes: 400×240 @1x, 800×480 @2x, 1280×768 for the App Store stack. Generated with Pillow; the flattened source stays out of the repository.

