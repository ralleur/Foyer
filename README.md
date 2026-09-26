# Foyer — a Jellyfin client for Apple TV

Foyer is a native tvOS app for [Jellyfin](https://jellyfin.org). It is built around one idea: turn on the TV, open the app, pick something, press play, and it plays — in the best quality the Apple TV can produce, with as little server work as possible.

- **Direct play first.** MP4/MOV goes straight to the system player (HDR10, HLG, Dolby Vision, Dolby passthrough). MKV, DTS, TrueHD, FLAC, Opus, ASS and PGS are handled on the Apple TV by an mpv/FFmpeg engine. The server only remuxes or transcodes when nothing else works, and every decision is logged with its reasons.
- **Subtitles are first class.** SRT/ASS/VTT are rendered locally (no "Preparing subtitles…"), PGS/VobSub by the advanced engine, forced/SDH/default flags and language preferences are respected, delay is adjustable.
- **Made for the couch.** Continue Watching, Next Up, series that know where you left off, skip intro / next episode, trickplay previews while scrubbing, a quiet 10-foot UI in German and English.
- **Honest engineering.** No mock data in the product, no buttons without function, structured logs without secrets, a debug screen that tells you exactly what is being played and why.

## Requirements

- Apple TV 4K (any generation) or Apple TV HD, tvOS 17 or newer
- Xcode 16 or newer with the tvOS platform (Xcode 26 recommended)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the project file (`brew install xcodegen`) — the generated `Foyer.xcodeproj` is committed, so this is only needed after changing `project.yml`
- Jellyfin server 10.8 or newer (10.10+ for server-side intro/credits segments)

## Build

```bash
git clone https://github.com/ralleur/foyer.git
cd foyer
Scripts/bootstrap.sh          # installs XcodeGen if needed and regenerates Foyer.xcodeproj
open Foyer.xcodeproj
```

In Xcode: select the *Foyer* scheme, set your team under *Signing & Capabilities*, pick an Apple TV (or a tvOS simulator) and run. The first build resolves two Swift packages: the local `FoyerCore` and [MPVKit](https://github.com/mpvkit/MPVKit) (binary xcframeworks, ~200 MB download once).

Run the platform-independent tests without Xcode (macOS or Linux):

```bash
Scripts/test-core.sh
```

App and UI tests on a simulator:

```bash
Scripts/test-app.sh
xcodebuild -project Foyer.xcodeproj -scheme Foyer -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' test
```

> The initial version of this code base was written in an environment without Xcode. The core package (Jellyfin client, playback decision engine, track selection, subtitle parsing, policies) is compiled and tested there; the tvOS app target was written against documented APIs but not compiled yet. Expect the first Xcode build to need small fixes — see [DEVELOPMENT.md](DEVELOPMENT.md).

## Jellyfin setup

Nothing special is required on the server. Recommended:

1. **Trickplay** (Dashboard › Playback › Trickplay): enables scrub previews in the advanced player.
2. **Media segments / Intro Skipper** (Jellyfin 10.10 media segments or the Intro Skipper plugin): enables *Skip Intro* and the credits-based *Next Episode* prompt.
3. **HTTPS with a valid certificate** for remote access. On the home network plain `http://server:8096` works; type the `http://` prefix explicitly or let Foyer probe (https first, then http).
4. **Hardware transcoding** if you have libraries the Apple TV cannot decode at all (rare: 4K AV1 on older boxes, VP9 4K).

Sign in with username/password or **Quick Connect** (Settings › Quick Connect on another device). Multiple servers and users can be saved and switched in Settings.

## Features

| Area | What you get |
| --- | --- |
| Home | Continue Watching, Next Up, New in each movie/show library, libraries, collections. Cached snapshot for instant start. |
| Libraries | Paged poster grid (100 per page, lazy), sort by name/date/year/rating, filters: all/unwatched/favorites. Folders and box sets browse naturally. |
| Details | Backdrop + logo, metadata, overview, cast, similar titles, versions picker, watched/favorite toggles, technical info sheet. |
| Series | Season chips that load episodes on focus, episode rows with progress, primary button = "Continue S2 E3" / "Play S1 E1". |
| Search | Server search across movies, shows and episodes with debounce; tvOS keyboard and dictation. |
| Player (native) | System transport bar, chapter markers, info panel, *Skip Intro* contextual action, next-episode proposal with autoplay, Jellyfin audio/subtitle menus, local text-subtitle overlay, frame-rate/HDR matching. |
| Player (advanced) | Click for controls, swipe to scrub with trickplay previews, swipe down for info/audio/subtitles/chapters, skip pill, next-episode countdown card, subtitle/audio delay, debug HUD. |
| Watch state | Start/progress/stop reporting, resume anywhere, remembered audio language per series. |
| Settings | Account/server, audio & subtitle languages and behaviour, subtitle size, streaming quality, direct play mode, advanced player mode, autoplay, debug tools (logs, capabilities, last decision, cache). |

## Architecture in one paragraph

`Packages/FoyerCore` holds everything platform-independent: `JellyfinKit` (models + HTTP client), `PlaybackDecision` (capabilities, decision engine, device profiles, track selection, subtitle parsers, skip/resume/progress policies) and `FoyerFoundation` (redacting logger, errors, language codes). The tvOS app (`Foyer/`) adds SwiftUI screens, an image pipeline with bounded caches, a session store with Keychain tokens, and the playback stack: `PlaybackCoordinator` orchestrates `NativePlaybackEngine` (AVFoundation) and `AdvancedPlaybackEngine` (libmpv) behind one protocol. Details in [ARCHITECTURE.md](ARCHITECTURE.md), [PLAYBACK.md](PLAYBACK.md) and [JELLYFIN.md](JELLYFIN.md).

## Known limitations

- **HDR in the advanced engine is tone-mapped to SDR.** tvOS offers no EDR Metal path, so HDR/Dolby Vision content is routed to the system player (server remux when the container is MKV). Lossless audio on such files is re-encoded by the server to E-AC-3/AAC.
- **Audio passthrough** of DTS/TrueHD is not possible on tvOS; they are decoded to multichannel PCM. AC-3/E-AC-3 (incl. Atmos) pass through via the system player.
- **AV1** needs hardware decoding (not present on Apple TV 4K 2022 and earlier); 1080p AV1 is decoded in software by the advanced engine, 4K AV1 is transcoded.
- **Trickplay previews** are shown in the advanced player only; the system player has no API for custom scrub thumbnails.
- **No offline downloads, no Live TV, no music/photos.** Those libraries are hidden.
- **App Store distribution** requires an LGPL-compliance review of the MPVKit binaries (see [LICENSES.md](LICENSES.md)).

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — modules, data flow, state, threading
- [PLAYBACK.md](PLAYBACK.md) — decision tree, codec matrix, audio/subtitle/HDR handling, test matrix
- [JELLYFIN.md](JELLYFIN.md) — endpoints, auth, device profile, watch state
- [TESTING.md](TESTING.md) — what is tested where and how to run it
- [LICENSES.md](LICENSES.md) — dependencies and licenses
- [DEVELOPMENT.md](DEVELOPMENT.md) — decision log
