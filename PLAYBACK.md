# Playback

Priorities, in order: reliability → picture and sound quality → direct play → usability → performance. When two goals conflict, the earlier one wins.

## Engines

| | Native engine | Advanced engine |
| --- | --- | --- |
| Implementation | `AVPlayer` in `AVPlayerViewController` | libmpv 0.41 + FFmpeg 9 via [MPVKit](https://github.com/mpvkit/MPVKit) (LGPL build), Metal through MoltenVK, VideoToolbox decoding |
| Containers | MP4, M4V, MOV (progressive) and HLS/fMP4 (server output) | MKV, MP4, MOV, MPEG-TS, AVI, WebM, … |
| Video | H.264 (8-bit ≤ L5.2), HEVC Main/Main 10 (hvc1/dvh1 tag), AV1 (hardware only), MPEG-4 Part 2 | H.264/HEVC via VideoToolbox, AV1/VP9 hardware or software ≤ 1080p, MPEG-2/4, VC-1 |
| HDR | HDR10, HDR10+, HLG, Dolby Vision P5 and P8 (P7 dual-layer: the server strips RPU/EL and the HDR10 base layer is played) | Tone-mapped to SDR (libplacebo bt.2446a); DV P5 reshaped by libdovi |
| Audio | AAC, AC-3, E-AC-3 (+Atmos JOC passthrough), ALAC, FLAC, MP3, PCM | Everything FFmpeg decodes (DTS, DTS-HD, TrueHD, FLAC, Opus, Vorbis, …) → multichannel PCM |
| Subtitles | tx3g embedded (system menu); SRT/ASS/VTT fetched from the server and drawn by Vela's overlay; bitmap → engine switch | Everything via libass (ASS styling, embedded fonts) and bitmap decoders (PGS, VobSub, DVB) |
| UI | System transport bar, info panel, chapters, contextual *Skip Intro*, next-episode proposal, custom audio/subtitle menus | Vela overlay: click for controls, swipe to scrub (trickplay previews), swipe down for panel, skip pill, countdown card, delays, debug HUD |
| Frame-rate matching | `appliesPreferredDisplayCriteriaAutomatically` | `AVDisplayCriteria(refreshRate:formatDescription:)` (tvOS 17) |

## Decision tree

Implemented in `PlaybackDecisionEngine.decide` (VelaCore/PlaybackDecision). Inputs: `MediaSource` (container, video/audio/subtitle streams with codec, profile, bit depth, range type, tag, fps, size), selected audio/subtitle indices (from `TrackSelector`), `DeviceCapabilities`, `PlaybackPreferences`.

```
1. Native direct play?      container ∈ MP4/MOV ∧ video ok ∧ audio ok ∧ subtitle text-or-none ∧ (advanced mode ≠ always)
     → Native Direct Play
2. Advanced direct play?    engine linked ∧ mode ≠ never ∧ container/video/audio/subtitle ok
     2a. video is HDR ∧ advanced cannot output HDR ∧ preferHDRPicture ∧ direct play not forced
         ∧ server may direct-stream ∧ video stream is native-compatible after remux ∧ selected subtitle is not bitmap
         → Direct Stream (native engine plays fMP4/HLS; server copies video, converts audio only if needed)
     2b. otherwise → Advanced Direct Play
3. Native can play but advanced was preferred and failed the check → Native Direct Play
4. Direct play forced by settings → try the most capable engine anyway, server help disabled
5. Server assisted (native engine plays the HLS output):
     video stream native-compatible after remux ∧ direct stream allowed → Direct Stream
     else transcoding allowed → Transcode
Bitmap subtitle selected on a server route → burn-in (route becomes Transcode) unless burn-in is disabled (subtitle dropped).
```

After `PlaybackInfo`, `reconcile` applies the server's verdict: no direct play but a transcoding URL → Direct Stream when the URL's `VideoCodec=` list still contains the source codec (Jellyfin reports `SupportsDirectStream=false` for every MKV → fMP4 conversion, even when it copies the video), otherwise Transcode; direct play granted although we asked for a remux → Native Direct Play.

For HEVC HDR/Dolby Vision remuxes Jellyfin's master playlist always carries a second, re-encoded H.264/SDR variant ("SDR entrance", same `BANDWIDTH`) regardless of the client profile. AVPlayer picks the first variant it can play: an Apple TV 4K with Dolby Vision takes the HEVC/DV copy, the simulator (no DV/PQ) falls back to the H.264 encode. The variant choice cannot be steered from the client; the device test plan checks it on real hardware.

Both device profiles always carry explicit `MaxStreamingBitrate`/`MaxStaticBitrate` values (the user's quality setting or 200 Mbit/s for "original"), because Jellyfin substitutes 8 Mbit/s when they are omitted and then re-encodes anything above it.

Every decision carries `reasons` (positive facts and blockers of the other engine) and `compromises` (e.g. "TrueHD becomes E-AC-3"). They are logged under PLAYBACK and shown in Settings › Debug › Last playback decision and the player's info panel when debug mode is on.

A seek keeps its target until the engine confirms it: AVPlayer reports the old position for a moment, and if the stream fails during the seek the next route resumes at the target, not before it.

### Fallback chain

If an engine fails to open or play (`didFail`), the coordinator stops the session, re-runs preparation at the last position (or at the originally requested position when no frame was shown yet) with the next route in `[other engine's direct play, Direct Stream, Transcode]` that has not been tried, and asks the server again with `EnableDirectPlay=false` for server routes. Only when the chain is exhausted does the user see an error (with the technical reason under Debug).

The advanced engine treats an end-of-file that arrives long before the known duration (stream broke off, unseekable source) as a failure rather than a normal end, so a broken direct stream falls back instead of silently closing the player.

## Device profile

`DeviceProfileBuilder` produces one of two Jellyfin `DeviceProfile`s per request:

**Native**: direct-play containers `mp4,m4v` and `mov` with `h264,hevc,(av1),mpeg4` × `aac,ac3,eac3,alac,flac,mp3,pcm_*`; codec profiles restrict H.264 to 8-bit ≤ L5.2 non-interlaced, HEVC to Main/Main 10 with `VideoRangeType ∈ supported set` and `VideoCodecTag ∈ hvc1|dvh1` (**not** required, like Jellyfin's own Safari profile: MKV sources have no tag and must stay remuxable, an `hev1`-tagged MP4 fails the check and is remuxed); `Width ≤ device max`, `VideoFramerate ≤ 60`. Subtitle profiles: text formats `External` (Vela renders), `mov_text` `Embed`, text formats `Hls`, bitmap formats `Encode` only when burn-in is allowed for this request.

**Advanced**: one direct-play profile with every container/video/audio codec FFmpeg handles; codec profiles cap VP9/AV1 software decoding at 1080p (Apple TV HD: 720p); subtitle profiles `Embed` for all formats plus `External` for text.

**Shared transcoding profile**: `hls` + `mp4` container (fMP4), video `hevc,h264` (HEVC first when hardware supports it), audio `eac3,ac3,aac,alac,flac,mp3` (order = server target preference), `MaxAudioChannels` = output channels, `BreakOnNonKeyFrames`, `MinSegments 2`, subtitles not in manifest (Vela renders external text tracks itself for consistency).

## Audio

- Track choice: `TrackSelector` — remembered language for the series → original (if preferred) → preferred languages in order → original → default → first; within a language: default flag, more channels, lossless/object formats, lower index; commentary tracks avoided.
- Native engine: AC-3/E-AC-3 pass through when the Apple TV's audio format setting allows; everything else is decoded by the system. HLS transcodes carry one audio track — switching to another track re-requests `PlaybackInfo` with the new index and resumes at the same position.
- Advanced engine: decodes to PCM, `audio-channels=auto-safe` with `AVAudioSession` preferring the maximum output channel count (7.1 LPCM over HDMI when the receiver supports it). No SPDIF passthrough on tvOS. Audio delay adjustable (`audio-delay`).
- tvOS limitation: DTS/TrueHD bitstreaming is impossible; DTS:X/TrueHD Atmos are decoded to their channel beds.

## Subtitles

- Selection (`SubtitleMode`): *off*; *forced only*; *smart* (default: forced track in the audio language when the audio is in the primary preferred language, full subtitles in a preferred language otherwise; unknown audio language counts as understood); *always*. SDH preference and default flags are honoured; external tracks are preferred less than embedded ones on ties.
- Native engine: text tracks are fetched as `/Videos/{item}/{source}/Subtitles/{index}/0/Stream.{srt|ass|vtt}` (or the server's `DeliveryUrl`), parsed by `SubtitleParser` (SRT, WebVTT incl. cue settings, ASS dialogue with override tags stripped and top-alignment detected) and rendered by `SubtitleCueView` (10 Hz clock, italics kept, lifted while the transport bar is visible, size from Settings, delay applied). Bitmap tracks trigger an engine switch at the current position.
- Advanced engine: libass with embedded fonts and original ASS styling (`sub-ass-override=no`), PGS/VobSub/DVB via FFmpeg, external text via `sub-add`. Delay via `sub-delay`.
- The server only burns subtitles in when the advanced engine is unavailable and the user allows it.

## HDR and frame rate

- Capabilities are probed at launch and on foreground: `AVPlayer.availableHDRModes` (HDR10/HLG/DV), `VTIsHardwareDecodeSupported` (HEVC, AV1), model (Apple TV HD limits), `AVAudioSession.maximumOutputNumberOfChannels`.
- Native engine outputs HDR10/HLG/DV natively and lets tvOS switch dynamic range and frame rate according to the user's *Match Content* settings.
- The device profile never claims dual-layer Dolby Vision (`DOVIWithEL`): AVPlayer on Apple TV rejects profile 7 (`-11855`), so Jellyfin removes the RPU/EL and copies the HDR10 base layer instead (verified on an Apple TV 4K).
- The audio session asks for at most 8 output channels (HDMI PCM). Asking for the 32 that tvOS 26 reports on HDMI left the audio route at 0 Hz and made every AVPlayer item with audio fail (`CoreMediaErrorDomain 'nope'`) until the box was rebooted.
- Advanced engine tone-maps HDR to SDR (documented limitation: no EDR Metal layer on tvOS) and requests the content frame rate via `AVDisplayManager`. HDR files therefore prefer the native path via server remux; the user can force local playback (Direct Play: Always / Advanced Player: Always).

## Seeking and buffering

- Native: 0.5 s tolerance seeks; `automaticallyWaitsToMinimizeStalling`; buffer sized by AVFoundation; stalls surface as *buffering* and are logged, playback continues when data arrives.
- Advanced: keyframe seeks for responsiveness with `hr-seek-framedrop`; demuxer cache 200 MB forward / 60 MB back, 30 s read-ahead, `cache-pause` with 1.5 s refill, HTTP auto-reconnect (`reconnect_on_network_error`), 20 s network timeout, 30 s open watchdog. Buffer state and dropped frames are shown in the debug HUD.
- Scrubbing UI: swipe distance maps to 10 % of runtime per full swipe (1–15 min), trickplay tile cropped from Jellyfin's sprite sheets, click confirms, Menu cancels.

## Segments, next episode, resume

- Segments: `GET /MediaSegments/{id}` (10.10+) → Intro Skipper `IntroSkipperSegments` → `IntroTimestamps/v1`. `SkipSegmentPolicy` shows *Skip Intro/Recap* for ≤ 12 s after the segment starts, hides it 2 s before the end, respects dismissals; commercials/previews are skippable throughout; an outro turns the prompt into *Next Episode*.
- Next episode: `NextEpisodeResolver` walks the season (and into the next regular season). Native engine shows the system content proposal (auto-accepted at the end when autoplay is on); advanced engine shows a countdown card 10 s before the end or at the credits marker (only for items longer than 60 s; short clips just show the *Next Episode* pill). Menu cancels the countdown.
- Resume: `ResumePolicy` ignores positions < 20 s and within the last 15 s. "Play from beginning" is one click away in details and context menus.

## Lifecycle

Background/inactive → pause, flush a progress report, mpv detaches video output; foreground → video re-attached, playback stays paused until the user resumes. Closing the player sends `Playing/Stopped` and, for transcodes, `DELETE /Videos/ActiveEncodings`. Idle timer is disabled only while a player is on screen.

## Test matrix

Expected route with default settings on an Apple TV 4K with an HDR display (`DecisionEngineTests` verifies each row).

| Media | Expected path | Notes |
| --- | --- | --- |
| 1080p H.264 + AAC + external SRT (MP4) | Native Direct Play | SRT drawn by Vela overlay |
| 1080p H.264 + AC-3 (MP4, container reported as `mov,mp4,m4a,…`) | Native Direct Play | AC-3 passthrough |
| 4K HEVC SDR (MKV, E-AC-3) | Advanced Direct Play | zero server work |
| 4K HEVC HDR10 (MKV, E-AC-3) | Direct Stream | HDR kept via remux, audio copied |
| 4K HEVC Dolby Vision P8 (MP4, dvh1) | Native Direct Play | |
| 4K HEVC Dolby Vision P5 (MKV) | Direct Stream (SDR display: Advanced, tone-mapped) | |
| MKV HEVC + DTS | Advanced Direct Play | DTS decoded locally |
| MKV HEVC + DTS-HD MA | Advanced Direct Play | core+extensions decoded locally |
| MKV HEVC + TrueHD (SDR) | Advanced Direct Play | 7.1 PCM out |
| MKV HEVC HDR10 + TrueHD | Direct Stream | compromise: TrueHD → E-AC-3 by the server |
| ASS subtitles (MKV) | Advanced Direct Play, embedded | libass styling |
| PGS subtitles selected on HDR MKV | Advanced Direct Play | subtitles beat HDR |
| PGS selected, advanced engine unavailable | Transcode (burn-in) | or Direct Stream with subtitle dropped when burn-in is off |
| MP4 HEVC tagged `hev1` | Advanced Direct Play (SDR); Direct Stream when advanced engine is off | tag fixed by remux |
| Forced subtitles + German audio | Native/Advanced with forced track | `TrackSelectorTests` |
| Multiple audio tracks (TrueHD en, E-AC-3 de, DTS-HD en) | German E-AC-3 chosen | commentary avoided |
| Multiple versions (4K HDR MKV, 1080p MP4) | Decision per selected version | version picker in details |
| AV1 1080p (MKV, no hardware) | Advanced Direct Play (dav1d) | |
| AV1 4K (no hardware) | Transcode | |
| Apple TV HD + 4K HEVC | Transcode | exceeds device limits |
| Interlaced H.264 (MP4) | Advanced Direct Play | deinterlaced |
| 120 fps HEVC | Transcode | > 60 fps |

## Network scenarios

| Scenario | Behaviour |
| --- | --- |
| Same LAN, http | probe https then http; all direct-play paths available |
| Reverse proxy / https | base path (`/jellyfin`) preserved in every URL incl. transcoding URLs |
| Slow link | *Streaming Quality* limit → server transcodes above the cap; buffer indicator instead of errors |
| Short interruption | AVFoundation stalls and resumes; mpv reconnects (`reconnect_on_network_error`); progress flushed regularly so little is lost |
| DNS failure / server down | friendly "Server not reachable" with retry; technical detail under Debug |
| Server restart during playback | playback error → fallback chain → error screen if nothing works; session report retried on close |
