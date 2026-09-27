# Jellyfin integration

All server communication goes through `JellyfinClient` (FoyerCore/JellyfinKit). Endpoints follow the 10.9+ API and fall back to the pre-10.9 user-scoped routes on 404, so 10.8 servers work too.

## Identification and authentication

- Header on every request: `Authorization: MediaBrowser Client="Foyer", Device="<Apple TV name>", DeviceId="<per-install UUID>", Version="<app version>", Token="<access token>"`. The token is omitted for anonymous calls.
- `POST /Users/AuthenticateByName` `{Username, Pw}` → `AccessToken`, `User`, `ServerId`.
- Quick Connect: `GET /QuickConnect/Enabled`, `POST /QuickConnect/Initiate` (falls back to `GET` on 404/405 for older servers), poll `GET /QuickConnect/Connect?secret=` every 2 s, then `POST /Users/AuthenticateWithQuickConnect` `{Secret}`.
- `POST /Sessions/Capabilities/Full` after sign-in (`PlayableMediaTypes: Video`, `SupportsMediaControl`, `SupportedCommands: Play, PlayState, DisplayMessage, SetAudioStreamIndex, SetSubtitleStreamIndex`) so the session shows correctly in the dashboard and can be targeted with "Play on".
- `ws(s)://…/socket?deviceId=` with the same `Authorization` header stays open while signed in (see *Remote control*). Jellyfin only lists a session as remote-controllable while this socket is connected. 10.11 rejects `api_key` in the query of this endpoint (403 "Token is required"), so the token must be sent as a header.
- `POST /Sessions/Logout` on sign-out; tokens deleted from the Keychain.
- `GET /System/Info/Public` is used to validate a server address and read its version; `GET /Users/Public` lists selectable users; `GET /Users/Me` refreshes the profile.

## Library

| Purpose | Endpoint |
| --- | --- |
| Libraries | `GET /UserViews?userId=` (fallback `/Users/{id}/Views`); video libraries: movies, tvshows, boxsets, homevideos, mixed |
| Continue watching | `GET /UserItems/Resume?userId=&mediaTypes=Video&includeItemTypes=Movie,Episode` (fallback `/Users/{id}/Items/Resume`) |
| Next up | `GET /Shows/NextUp?userId=&enableResumable=false&enableRewatching=false[&seriesId=]` |
| Recently added | `GET /Items/Latest?userId=&parentId=&groupItems=true` (fallback `/Users/{id}/Items/Latest`) |
| Browse / search | `GET /Items` with `ParentId`, `IncludeItemTypes`, `Recursive`, `SortBy`, `SortOrder`, `StartIndex`, `Limit`, `Fields`, `Filters`, `SearchTerm`, `EnableImageTypes`, `ImageTypeLimit` |
| Item | `GET /Items/{id}?userId=&fields=` (fallback `/Users/{id}/Items/{id}`) |
| Seasons / episodes | `GET /Shows/{seriesId}/Seasons`, `GET /Shows/{seriesId}/Episodes?seasonId=` |
| Similar | `GET /Items/{id}/Similar` |
| Watched | `POST`/`DELETE /UserPlayedItems/{id}?userId=` (fallback `/Users/{id}/PlayedItems/{id}`) |
| Favorite | `POST`/`DELETE /UserFavoriteItems/{id}?userId=` |
| Images | `GET /Items/{id}/Images/{type}[/{index}]?tag=&maxWidth=&quality=90`, `GET /UserImage?userId=` |

Requested `fields` are kept small for cards (`PrimaryImageAspectRatio, ChildCount, RecursiveItemCount, MediaSourceCount`) and complete for detail/playback (`Overview, Genres, People, Studios, Taglines, MediaSources, MediaStreams, Chapters, Trickplay, …`). Lists request one image per type. Grids page 100 items at a time with `TotalRecordCount`.

## Playback

1. `POST /Items/{id}/PlaybackInfo?userId=` with `PlaybackInfoDto`: `MediaSourceId`, `MaxStreamingBitrate`, `StartTimeTicks`, `AudioStreamIndex`, `SubtitleStreamIndex`, `EnableDirectPlay/DirectStream/Transcoding`, `DeviceProfile` (see PLAYBACK.md). Response: `MediaSources` with `SupportsDirectPlay/DirectStream/Transcoding`, `TranscodingUrl`, `DefaultAudioStreamIndex`, stream `DeliveryMethod`/`DeliveryUrl`, and `PlaySessionId`.
2. Direct play URL: `GET /Videos/{id}/stream.{container}?static=true&mediaSourceId=&playSessionId=&Tag=&deviceId=&api_key=`. Server-assisted playback uses `TranscodingUrl` as returned (already contains `api_key`, `PlaySessionId`, codec parameters); the base path of reverse proxies is preserved.
3. Subtitles: `DeliveryUrl` when provided, else `GET /Videos/{id}/{mediaSourceId}/Subtitles/{index}/0/Stream.{srt|ass|vtt}`. Fonts: `/Videos/{id}/{mediaSourceId}/Attachments/{index}`.
4. Trickplay: `BaseItemDto.Trickplay[mediaSourceId][width]` → `GET /Videos/{id}/Trickplay/{width}/{tileIndex}.jpg?mediaSourceId=`.
5. Segments: `GET /MediaSegments/{id}?includeSegmentTypes=Intro&…` (10.10+), fallback Intro Skipper plugin `GET /Episode/{id}/IntroSkipperSegments` and `GET /Episode/{id}/IntroTimestamps/v1`.
6. Chapters: `BaseItemDto.Chapters` with `/Items/{id}/Images/Chapter/{index}?tag=`.

Media player URLs carry the token as `api_key` because AVFoundation and mpv cannot send custom headers reliably. Logs redact `api_key`, `Token="…"`, `AccessToken` and password fields.

## Watch state

| Event | Call |
| --- | --- |
| Start (first frame) | `POST /Sessions/Playing` with `ItemId, MediaSourceId, PlaySessionId, PositionTicks, PlayMethod, AudioStreamIndex, SubtitleStreamIndex, CanSeek` |
| Progress | `POST /Sessions/Playing/Progress` every 10 s while playing, immediately on pause/resume/seek/track change (min. 1 s apart), flushed on background |
| Stop | `POST /Sessions/Playing/Stopped` with the final position; `DELETE /Videos/ActiveEncodings?deviceId=&playSessionId=` for transcodes |

Ticks are 100 ns (`JellyfinTicks`). `PlayedPercentage`/`PlaybackPositionTicks` from `UserData` drive progress bars and resume. After the player closes, Home, library and detail screens refresh their data from the server.

## Remote control (session WebSocket)

`RemoteControlService` connects to `/socket` after sign-in and reconnects with backoff (2 s → 30 s); the socket is closed while the app is in the background. Frames are `{"MessageType": …, "Data": …}`:

| Message | Handling |
| --- | --- |
| `ForceKeepAlive` (`Data` = timeout s) | send `{"MessageType":"KeepAlive"}` every timeout/2 s |
| `Play` `{ItemIds, PlayCommand, StartPositionTicks, StartIndex, MediaSourceId, AudioStreamIndex, SubtitleStreamIndex}` | `PlayNow`: load the item (`ItemIds[StartIndex]`), open the player at the position with the requested tracks (`SubtitleStreamIndex = -1` = off). Ids arrive as GUIDs with dashes and are normalised. `PlayNext`/`PlayLast`/`PlayInstantMix`/`PlayShuffle` need a queue and are declined with a log line; extra ids are ignored |
| `Playstate` `{Command, SeekPositionTicks}` | `Pause`, `Unpause`, `PlayPause`, `Stop` (closes the player), `Seek`, `Rewind`/`FastForward` (±10 s), `NextTrack`/`PreviousTrack` (episodes) — routed to the presented `PlaybackCoordinator`; ignored when nothing plays |
| `GeneralCommand` `{Name, Arguments}` | `DisplayMessage` (`Header`, `Text`, `TimeoutMs`) shows a banner over the current screen or player; `SetAudioStreamIndex`/`SetSubtitleStreamIndex` (`Index`, `-1` = off) switch tracks in place or reload; everything else is logged as unsupported |
| `UserDataChanged`, `LibraryChanged`, `SessionEnded`, … | logged at debug level, not acted on |

The server sends these when a user picks this device in the web UI's "Play on" menu or calls `POST /Sessions/{id}/Playing`, `/Playing/{command}`, `/Message` or `/Command` (`Scripts/remote.py` wraps them for device testing).

## User configuration

The server-side user configuration is read (audio/subtitle language, `EnableNextEpisodeAutoPlay`) but Foyer's own preferences take precedence because they encode the requested German/English rules; they are stored per device.

## Compatibility notes

- Enums are decoded as open string wrappers, so values added by newer servers do not break parsing.
- Dates with seven fractional digits (`2024-05-01T12:34:56.1234567Z`) are normalised before ISO 8601 parsing.
- `Container` may be an FFmpeg format list (`mov,mp4,m4a,3gp,3g2,mj2`); the decision engine matches tokens.
- 401 on an authenticated call invalidates the local session and returns to onboarding with the server pre-filled.
