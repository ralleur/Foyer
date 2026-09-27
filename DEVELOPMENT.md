# Development Log

Only decisions that shape the product or architecture. Newest at the bottom.

## Environment for the initial build-out

**Problem:** The initial implementation was produced in a Linux container without Xcode or a tvOS SDK.
**Decision:** Everything that does not need UIKit/AVFoundation lives in a Swift package (`Packages/FoyerCore`) that builds and tests on Linux with Swift 6.2. The tvOS app target was written against documented APIs (availability verified against Apple's documentation index) but could not be compiled in that environment. The Xcode project is generated from `project.yml` with XcodeGen (built from source on Linux) so the project file itself is reproducible.
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
**Decision:** Text subtitles (SRT/ASS/VTT) on the native engine are fetched as external streams and rendered by Foyer's own overlay (SRT/VTT/ASS parsers live in the core package); mpv renders everything itself including PGS/VobSub with libass styling. Selecting a bitmap track while the system player is active transparently switches engines at the current position. Burn-in is only used when no engine can show the track (advanced engine unavailable) and can be disabled.

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
**Decision:** `Tools/MockJellyfin` — a generator for a small synthetic library (H.264/MP4, HEVC/MKV with AC-3, DTS, TrueHD, FLAC, HDR10, SRT/ASS, chapters, a series with intro/credits markers, one deliberately broken file) and a Python server that implements the Jellyfin endpoints Foyer uses, including Range requests, on-demand subtitle extraction, an ffmpeg-based HLS remux/transcode and in-memory watch state. `Scripts/e2e-mock.sh` runs `FoyerUITests/MockServerTour` against it and collects screenshots. Nothing of this ships in the app.

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
