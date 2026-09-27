#!/usr/bin/env python3
"""
Mock Jellyfin server for end-to-end playback testing without a real server.

It speaks the subset of the Jellyfin 10.9+ API that Foyer uses, serves real media
files (with HTTP Range support, on-demand subtitle extraction and a small HLS
"transcoder" built on ffmpeg) and keeps watch state in memory, so Continue Watching,
Next Up, resume and the fallback chain can be exercised for real in the simulator.

    Tools/MockJellyfin/make-media.sh            # generates the synthetic library once
    Tools/MockJellyfin/server.py --media Tools/MockJellyfin/media --port 8097

Sign in with user "test" (no password). Nothing here is used by the app itself.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

TICKS = 10_000_000
SERVER_ID = "f0e1d2c3b4a5968778695a4b3c2d1e0f"
USER_ID = "0123456789abcdef0123456789abcdef"
TOKEN = "foyer-mock-token"
MEDIA_EXT = (".mkv", ".mp4", ".mov", ".m4v", ".ts", ".webm", ".avi")

# Metadata the file system cannot tell us. Keyed by file stem.
EXTRA = {
    "Aurora (2024)": dict(overview="H.264 in MP4 with two AAC tracks and external German/English SRT files. Expected: native direct play, subtitles rendered by Foyer.", genres=["Drama"], rating="PG-13", community=7.8),
    "Boreal (2023)": dict(overview="HEVC in MKV with Dolby Digital 5.1 (German), AAC (English), forced and full German SRT, English ASS and chapters. Expected: advanced direct play.", genres=["Thriller"], rating="R", community=8.2, resume_seconds=24),
    "Cascade (2022)": dict(overview="HEVC in MKV with DTS 5.1, TrueHD 5.1 and FLAC. Expected: advanced direct play, lossless audio decoded locally to PCM.", genres=["Action"], rating="PG", community=6.9),
    "Dawn HDR (2021)": dict(overview="HEVC Main 10 HDR10 in MKV with E-AC-3 5.1. Expected: system player after a server remux to keep HDR output.", genres=["Science Fiction"], rating="PG-13", community=8.9),
    "Broken (2020)": dict(overview="The server refuses to stream this file. Expected: fallback chain (direct play → remux → transcode) and a friendly error.", genres=["Horror"], rating="R", community=4.1, broken=True),
    "Test Show": dict(overview="Three short episodes with intro and credits markers. E01 is watched, E02 is next up.", genres=["Comedy"], rating="TV-PG", community=7.5),
    "Test Show S01E01": dict(name="Pilot", overview="Watched already.", played=True, segments=[("Intro", 3, 13), ("Outro", 32, 40)]),
    "Test Show S01E02": dict(name="The Second One", overview="Next up. MKV → advanced engine with skip intro and next-episode countdown.", segments=[("Intro", 3, 13), ("Outro", 32, 40)]),
    "Test Show S01E03": dict(name="Finale", overview="MP4 → system player with contextual skip action and next-episode proposal.", segments=[("Intro", 3, 13), ("Outro", 32, 40)]),
}


def item_id(rel: str) -> str:
    return hashlib.md5(rel.encode("utf-8")).hexdigest()


def ticks(seconds: float) -> int:
    return int(round(seconds * TICKS))


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.0000000Z")


def ffprobe(path: str) -> dict:
    out = subprocess.run(["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", path],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def frac(value: str):
    try:
        n, d = value.split("/")
        return round(float(n) / float(d), 3) if float(d) else None
    except Exception:
        return None


SUBTITLE_CODECS = {"subrip": "subrip", "srt": "subrip", "ass": "ass", "ssa": "ssa", "webvtt": "webvtt", "mov_text": "mov_text",
                   "hdmv_pgs_subtitle": "PGSSUB", "dvd_subtitle": "DVDSUB", "dvb_subtitle": "DVBSUB"}
TEXT_SUBTITLES = {"subrip", "ass", "ssa", "webvtt", "mov_text"}


def jellyfin_streams(probe: dict, external_subs: list) -> list:
    streams = []
    for s in probe["streams"]:
        kind = s.get("codec_type")
        tags = s.get("tags", {})
        disp = s.get("disposition", {})
        base = {
            "Index": s["index"],
            "Codec": s.get("codec_name"),
            "CodecTag": s.get("codec_tag_string"),
            "Language": tags.get("language"),
            "Title": tags.get("title"),
            "IsDefault": bool(disp.get("default")),
            "IsForced": bool(disp.get("forced")),
            "IsExternal": False,
            "IsInterlaced": False,
            "TimeBase": s.get("time_base"),
        }
        if kind == "video":
            pix = s.get("pix_fmt", "")
            transfer = s.get("color_transfer")
            hdr = transfer in ("smpte2084", "arib-std-b67")
            base.update({
                "Type": "Video",
                "Profile": s.get("profile"),
                "Level": s.get("level"),
                "Width": s.get("width"),
                "Height": s.get("height"),
                "BitDepth": 10 if "10" in pix else 8,
                "PixelFormat": pix,
                "RealFrameRate": frac(s.get("r_frame_rate", "")),
                "AverageFrameRate": frac(s.get("avg_frame_rate", "")),
                "ColorTransfer": transfer,
                "ColorPrimaries": s.get("color_primaries"),
                "ColorSpace": s.get("color_space"),
                "ColorRange": s.get("color_range"),
                "VideoRange": "HDR" if hdr else "SDR",
                "VideoRangeType": "HDR10" if transfer == "smpte2084" else ("HLG" if transfer == "arib-std-b67" else "SDR"),
                "IsAVC": s.get("codec_name") == "h264",
                "RefFrames": s.get("refs"),
                "AspectRatio": s.get("display_aspect_ratio"),
                "BitRate": int(s.get("bit_rate") or probe["format"].get("bit_rate") or 0),
                "DisplayTitle": f"{(s.get('height') or 0)}p {s.get('codec_name', '').upper()}",
            })
        elif kind == "audio":
            base.update({
                "Type": "Audio",
                "Profile": s.get("profile"),
                "Channels": s.get("channels"),
                "ChannelLayout": s.get("channel_layout"),
                "SampleRate": int(s.get("sample_rate") or 0),
                "BitRate": int(s.get("bit_rate") or 0),
                "DisplayTitle": f"{tags.get('title') or tags.get('language') or 'Audio'} - {s.get('codec_name', '').upper()}",
            })
        elif kind == "subtitle":
            codec = SUBTITLE_CODECS.get(s.get("codec_name"), s.get("codec_name"))
            base.update({
                "Type": "Subtitle",
                "Codec": codec,
                "IsTextSubtitleStream": codec in TEXT_SUBTITLES,
                "SupportsExternalStream": codec in TEXT_SUBTITLES,
                "DisplayTitle": f"{tags.get('title') or tags.get('language') or 'Subtitle'} ({codec})",
            })
        else:
            continue
        streams.append(base)
    next_index = max([s["Index"] for s in streams], default=-1) + 1
    for path, language in external_subs:
        ext = os.path.splitext(path)[1].lower().lstrip(".")
        codec = {"srt": "subrip", "ass": "ass", "vtt": "webvtt"}.get(ext, ext)
        streams.append({
            "Index": next_index, "Type": "Subtitle", "Codec": codec, "Language": language, "Title": None,
            "IsDefault": False, "IsForced": False, "IsExternal": True, "IsTextSubtitleStream": True,
            "SupportsExternalStream": True, "Path": path, "DisplayTitle": f"{language or 'und'} ({codec}) external",
        })
        next_index += 1
    return streams


class Library:
    def __init__(self, root: str):
        self.root = os.path.abspath(root)
        self.lock = threading.RLock()
        self.items = {}          # id -> item dict (BaseItemDto without UserData; UserData added per request)
        self.files = {}          # id -> media path
        self.artwork = {}        # (id, type) -> file path
        self.user_data = {}      # id -> dict
        self.segments = {}       # id -> [segment dicts]
        self.external_subs = {}  # (id, index) -> path
        self.broken = set()
        self.movies_lib = item_id("lib:movies")
        self.shows_lib = item_id("lib:shows")
        now = datetime.now(timezone.utc)
        self.scan_movies(now)
        self.scan_shows(now)

    # MARK: Scanning

    def media_source(self, iid: str, path: str, external: list) -> dict:
        probe = ffprobe(path)
        fmt = probe["format"]
        streams = jellyfin_streams(probe, external)
        for s in streams:
            if s["Type"] == "Subtitle" and s.get("IsExternal"):
                self.external_subs[(iid, s["Index"])] = s["Path"]
        ext = os.path.splitext(path)[1].lower().lstrip(".")
        container = {"m4v": "mp4", "ts": "mpegts"}.get(ext, ext)
        duration = float(fmt.get("duration") or 0)
        audio = [s for s in streams if s["Type"] == "Audio"]
        source = {
            "Id": iid, "Name": os.path.basename(path), "Path": path, "Protocol": "File", "Container": container,
            "Size": int(fmt.get("size") or 0), "Bitrate": int(fmt.get("bit_rate") or 0), "RunTimeTicks": ticks(duration),
            "IsRemote": False, "ETag": hashlib.md5(f"{path}{fmt.get('size')}".encode()).hexdigest()[:16],
            "SupportsDirectPlay": True, "SupportsDirectStream": True, "SupportsTranscoding": True, "SupportsProbing": True,
            "IsInfiniteStream": False, "RequiresOpening": False, "VideoType": "VideoFile", "Type": "Default",
            "MediaStreams": streams, "MediaAttachments": [], "Formats": [],
            "DefaultAudioStreamIndex": audio[0]["Index"] if audio else None,
            "DefaultSubtitleStreamIndex": None,
        }
        chapters = [{"StartPositionTicks": ticks(float(c["start_time"])), "Name": c.get("tags", {}).get("title", f"Chapter {i + 1}")}
                    for i, c in enumerate(probe.get("chapters", []))]
        video = next((s for s in streams if s["Type"] == "Video"), None)
        return source, chapters, video, duration

    def scan_movies(self, now):
        base = os.path.join(self.root, "Movies")
        if not os.path.isdir(base):
            return
        for n, folder in enumerate(sorted(os.listdir(base))):
            fdir = os.path.join(base, folder)
            if not os.path.isdir(fdir):
                continue
            media = [f for f in sorted(os.listdir(fdir)) if f.lower().endswith(MEDIA_EXT)]
            if not media:
                continue
            path = os.path.join(fdir, media[0])
            stem = os.path.splitext(media[0])[0]
            iid = item_id(os.path.relpath(path, self.root))
            external = []
            for f in sorted(os.listdir(fdir)):
                if f.lower().endswith((".srt", ".ass", ".vtt")):
                    m = re.match(re.escape(stem) + r"\.([a-z]{2,3})\.", f)
                    external.append((os.path.join(fdir, f), m.group(1) if m else None))
            source, chapters, video, duration = self.media_source(iid, path, external)
            extra = EXTRA.get(stem, {})
            year = int(re.search(r"\((\d{4})\)", stem).group(1)) if re.search(r"\((\d{4})\)", stem) else None
            name = re.sub(r"\s*\(\d{4}\)", "", stem)
            item = {
                "Id": iid, "Name": name, "OriginalTitle": name, "SortName": name.lower(), "ServerId": SERVER_ID, "Etag": source["ETag"],
                "Type": "Movie", "MediaType": "Video", "IsFolder": False, "LocationType": "FileSystem", "ParentId": self.movies_lib,
                "ProductionYear": year, "PremiereDate": iso(datetime(year or 2000, 6, 1, tzinfo=timezone.utc)),
                "DateCreated": iso(now - timedelta(days=n)), "RunTimeTicks": source["RunTimeTicks"],
                "OfficialRating": extra.get("rating"), "CommunityRating": extra.get("community"),
                "Overview": extra.get("overview"), "Genres": extra.get("genres", []), "Taglines": [],
                "Studios": [{"Name": "Foyer Test Studio", "Id": item_id("studio")}],
                "People": [{"Name": "Test Actor", "Id": item_id("person1"), "Role": "Lead", "Type": "Actor"},
                           {"Name": "Test Director", "Id": item_id("person2"), "Role": "Director", "Type": "Director"}],
                "Container": source["Container"], "Width": video and video.get("Width"), "Height": video and video.get("Height"),
                "HasSubtitles": any(s["Type"] == "Subtitle" for s in source["MediaStreams"]),
                "MediaSources": [source], "MediaStreams": source["MediaStreams"], "Chapters": chapters, "MediaSourceCount": 1,
                "ImageTags": {}, "BackdropImageTags": [], "PrimaryImageAspectRatio": 0.6667, "Path": path,
                "Trickplay": {},
            }
            self.register_art(iid, item, fdir, "poster.jpg", "backdrop.jpg")
            self.items[iid] = item
            self.files[iid] = path
            if extra.get("broken"):
                self.broken.add(iid)
            self.user_data[iid] = self.default_user_data(iid, duration, extra)

    def scan_shows(self, now):
        base = os.path.join(self.root, "Shows")
        if not os.path.isdir(base):
            return
        for show in sorted(os.listdir(base)):
            sdir = os.path.join(base, show)
            if not os.path.isdir(sdir):
                continue
            series_id = item_id(os.path.relpath(sdir, self.root))
            extra = EXTRA.get(show, {})
            series = {
                "Id": series_id, "Name": show, "SortName": show.lower(), "ServerId": SERVER_ID, "Type": "Series", "IsFolder": True,
                "LocationType": "FileSystem", "ParentId": self.shows_lib, "ProductionYear": 2024, "Status": "Continuing",
                "PremiereDate": iso(datetime(2024, 1, 1, tzinfo=timezone.utc)), "DateCreated": iso(now - timedelta(hours=6)),
                "Overview": extra.get("overview"), "Genres": extra.get("genres", []), "OfficialRating": extra.get("rating"),
                "CommunityRating": extra.get("community"), "ImageTags": {}, "BackdropImageTags": [], "PrimaryImageAspectRatio": 0.6667,
                "ChildCount": 0, "RecursiveItemCount": 0, "Path": sdir, "Studios": [], "People": [],
            }
            self.register_art(series_id, series, sdir, "poster.jpg", "backdrop.jpg")
            self.items[series_id] = series
            seasons = [d for d in sorted(os.listdir(sdir)) if os.path.isdir(os.path.join(sdir, d))]
            for sdirname in seasons:
                season_dir = os.path.join(sdir, sdirname)
                m = re.search(r"(\d+)", sdirname)
                season_no = int(m.group(1)) if m else 1
                season_id = item_id(os.path.relpath(season_dir, self.root))
                season = {
                    "Id": season_id, "Name": f"Season {season_no}", "ServerId": SERVER_ID, "Type": "Season", "IsFolder": True,
                    "IndexNumber": season_no, "SeriesId": series_id, "SeriesName": show, "ParentId": series_id,
                    "LocationType": "FileSystem", "ChildCount": 0, "ImageTags": {}, "PrimaryImageAspectRatio": 0.6667,
                    "SeriesPrimaryImageTag": series["ImageTags"].get("Primary"),
                    "ParentBackdropItemId": series_id, "ParentBackdropImageTags": series["BackdropImageTags"],
                }
                self.items[season_id] = season
                episodes = [f for f in sorted(os.listdir(season_dir)) if f.lower().endswith(MEDIA_EXT)]
                for f in episodes:
                    path = os.path.join(season_dir, f)
                    stem = os.path.splitext(f)[0]
                    em = re.search(r"S(\d+)E(\d+)", stem, re.IGNORECASE)
                    ep_no = int(em.group(2)) if em else len(episodes)
                    eid = item_id(os.path.relpath(path, self.root))
                    source, chapters, video, duration = self.media_source(eid, path, [])
                    ex = EXTRA.get(stem, {})
                    episode = {
                        "Id": eid, "Name": ex.get("name", stem), "ServerId": SERVER_ID, "Etag": source["ETag"], "Type": "Episode",
                        "MediaType": "Video", "IsFolder": False, "LocationType": "FileSystem", "ParentId": season_id,
                        "IndexNumber": ep_no, "ParentIndexNumber": season_no, "SeriesId": series_id, "SeriesName": show,
                        "SeasonId": season_id, "SeasonName": season["Name"], "SeriesPrimaryImageTag": series["ImageTags"].get("Primary"),
                        "ParentBackdropItemId": series_id, "ParentBackdropImageTags": series["BackdropImageTags"],
                        "PremiereDate": iso(datetime(2024, 1, ep_no, tzinfo=timezone.utc)), "DateCreated": iso(now - timedelta(hours=6, minutes=ep_no)),
                        "RunTimeTicks": source["RunTimeTicks"], "Overview": ex.get("overview"), "Container": source["Container"],
                        "Width": video and video.get("Width"), "Height": video and video.get("Height"),
                        "HasSubtitles": any(s["Type"] == "Subtitle" for s in source["MediaStreams"]),
                        "MediaSources": [source], "MediaStreams": source["MediaStreams"], "Chapters": chapters, "MediaSourceCount": 1,
                        "ImageTags": {}, "BackdropImageTags": [], "PrimaryImageAspectRatio": 1.7778, "Path": path, "Trickplay": {},
                        "CommunityRating": 7.0,
                    }
                    thumb = os.path.join(season_dir, f"{stem}-thumb.jpg")
                    if os.path.exists(thumb):
                        episode["ImageTags"]["Primary"] = "t1"
                        self.artwork[(eid, "primary")] = thumb
                    self.items[eid] = episode
                    self.files[eid] = path
                    self.user_data[eid] = self.default_user_data(eid, duration, ex)
                    self.segments[eid] = [
                        {"Id": item_id(f"{eid}:{t}"), "ItemId": eid, "Type": t, "StartTicks": ticks(a), "EndTicks": ticks(b)}
                        for (t, a, b) in ex.get("segments", [])
                    ]
                    season["ChildCount"] += 1
                    series["RecursiveItemCount"] += 1
                series["ChildCount"] += 1

    def register_art(self, iid, item, folder, poster, backdrop):
        if os.path.exists(os.path.join(folder, poster)):
            item["ImageTags"]["Primary"] = "p1"
            self.artwork[(iid, "primary")] = os.path.join(folder, poster)
        if os.path.exists(os.path.join(folder, backdrop)):
            item["BackdropImageTags"] = ["b1"]
            self.artwork[(iid, "backdrop")] = os.path.join(folder, backdrop)

    @staticmethod
    def default_user_data(iid, duration, extra):
        played = bool(extra.get("played"))
        resume = float(extra.get("resume_seconds") or 0)
        return {
            "ItemId": iid, "Key": iid, "PlaybackPositionTicks": 0 if played else ticks(resume), "PlayCount": 1 if played else 0,
            "IsFavorite": False, "Played": played,
            "PlayedPercentage": 100.0 if played else (round(resume / duration * 100, 2) if duration and resume else None),
            "LastPlayedDate": iso(datetime.now(timezone.utc) - timedelta(days=1)) if (played or resume) else None,
        }

    # MARK: Views

    def with_user_data(self, item: dict) -> dict:
        out = dict(item)
        if item["Type"] in ("Movie", "Episode"):
            out["UserData"] = dict(self.user_data[item["Id"]])
        elif item["Type"] in ("Series", "Season"):
            eps = self.episodes(item["Id"] if item["Type"] == "Series" else item["SeriesId"], item["Id"] if item["Type"] == "Season" else None)
            unplayed = sum(1 for e in eps if not self.user_data[e["Id"]]["Played"])
            out["UserData"] = {"UnplayedItemCount": unplayed, "PlayedPercentage": (len(eps) - unplayed) / len(eps) * 100 if eps else 0,
                               "Played": bool(eps) and unplayed == 0, "IsFavorite": False, "PlayCount": 0, "PlaybackPositionTicks": 0}
        return out

    def card(self, item: dict) -> dict:
        """Lighter representation for lists (no streams)."""
        out = self.with_user_data(item)
        for key in ("MediaSources", "MediaStreams", "Chapters", "People", "Studios"):
            out.pop(key, None)
        return out

    def views(self):
        return [
            {"Id": self.movies_lib, "Name": "Filme", "ServerId": SERVER_ID, "Type": "CollectionFolder", "CollectionType": "movies", "IsFolder": True, "ImageTags": {}, "ChildCount": len(self.movies())},
            {"Id": self.shows_lib, "Name": "Serien", "ServerId": SERVER_ID, "Type": "CollectionFolder", "CollectionType": "tvshows", "IsFolder": True, "ImageTags": {}, "ChildCount": len(self.series())},
        ]

    def movies(self):
        return [i for i in self.items.values() if i["Type"] == "Movie"]

    def series(self):
        return [i for i in self.items.values() if i["Type"] == "Series"]

    def episodes(self, series_id, season_id=None):
        eps = [i for i in self.items.values() if i["Type"] == "Episode" and i["SeriesId"] == series_id and (season_id is None or i["SeasonId"] == season_id)]
        return sorted(eps, key=lambda e: (e["ParentIndexNumber"], e["IndexNumber"]))

    def seasons(self, series_id):
        return sorted([i for i in self.items.values() if i["Type"] == "Season" and i["SeriesId"] == series_id], key=lambda s: s["IndexNumber"])

    def next_up(self, series_id=None):
        out = []
        for s in self.series():
            if series_id and s["Id"] != series_id:
                continue
            eps = self.episodes(s["Id"])
            watched = [i for i, e in enumerate(eps) if self.user_data[e["Id"]]["Played"]]
            if not watched:
                continue
            for e in eps[max(watched) + 1:]:
                if not self.user_data[e["Id"]]["Played"]:
                    out.append(e)
                    break
        return out

    def resume_items(self):
        out = [i for i in self.items.values() if i["Type"] in ("Movie", "Episode")
               and self.user_data[i["Id"]]["PlaybackPositionTicks"] > 0 and not self.user_data[i["Id"]]["Played"]]
        return sorted(out, key=lambda i: self.user_data[i["Id"]].get("LastPlayedDate") or "", reverse=True)

    def query(self, q: dict):
        parent = q.get("ParentId")
        kinds = set(filter(None, q.get("IncludeItemTypes", "").split(",")))
        recursive = q.get("Recursive", "true").lower() == "true"
        term = (q.get("SearchTerm") or "").lower()
        ids = set(filter(None, q.get("Ids", "").split(",")))
        if ids:
            pool = [self.items[i] for i in ids if i in self.items]
        elif parent == self.movies_lib:
            pool = self.movies()
        elif parent == self.shows_lib:
            pool = self.series() if not kinds or "Series" in kinds else [i for i in self.items.values() if i["Type"] in kinds and i.get("SeriesId")]
        elif parent in self.items and self.items[parent]["Type"] == "Series":
            pool = self.episodes(parent) if (recursive and kinds == {"Episode"}) else self.seasons(parent)
        elif parent in self.items and self.items[parent]["Type"] == "Season":
            pool = self.episodes(self.items[parent]["SeriesId"], parent)
        elif parent:
            pool = []
        else:
            pool = [i for i in self.items.values() if i["Type"] in ("Movie", "Series", "Episode")]
        if kinds:
            pool = [i for i in pool if i["Type"] in kinds]
        if term:
            pool = [i for i in pool if term in (i.get("Name") or "").lower() or term in (i.get("SeriesName") or "").lower()]
        filters = set(filter(None, q.get("Filters", "").split(",")))
        if "IsUnplayed" in filters:
            pool = [i for i in pool if not self.with_user_data(i)["UserData"].get("Played")]
        if "IsPlayed" in filters:
            pool = [i for i in pool if self.with_user_data(i)["UserData"].get("Played")]
        if "IsFavorite" in filters:
            pool = [i for i in pool if self.with_user_data(i)["UserData"].get("IsFavorite")]
        sort_by = (q.get("SortBy") or "SortName").split(",")[0]
        desc = (q.get("SortOrder") or "Ascending").lower().startswith("desc")
        keyfn = {
            "SortName": lambda i: (i.get("SortName") or i.get("Name") or "").lower(),
            "DateCreated": lambda i: i.get("DateCreated") or "",
            "ProductionYear": lambda i: i.get("ProductionYear") or 0,
            "PremiereDate": lambda i: i.get("PremiereDate") or "",
            "CommunityRating": lambda i: i.get("CommunityRating") or 0,
            "IndexNumber": lambda i: (i.get("ParentIndexNumber") or 0, i.get("IndexNumber") or 0),
        }.get(sort_by, lambda i: (i.get("SortName") or i.get("Name") or "").lower())
        pool = sorted(pool, key=keyfn, reverse=desc)
        total = len(pool)
        start = int(q.get("StartIndex") or 0)
        limit = int(q["Limit"]) if q.get("Limit") else None
        page = pool[start:start + limit] if limit else pool[start:]
        return page, total

    # MARK: Watch state

    def report(self, kind: str, body: dict):
        iid = body.get("ItemId")
        if iid not in self.user_data:
            return
        with self.lock:
            data = self.user_data[iid]
            position = int(body.get("PositionTicks") or 0)
            runtime = self.items[iid].get("RunTimeTicks") or 1
            if kind == "stopped" and position >= runtime * 0.9:
                data.update({"Played": True, "PlaybackPositionTicks": 0, "PlayedPercentage": 100.0, "PlayCount": data.get("PlayCount", 0) + 1})
            else:
                data.update({"PlaybackPositionTicks": position, "PlayedPercentage": round(position / runtime * 100, 2)})
                if kind == "stopped" and position < 20 * TICKS:
                    data.update({"PlaybackPositionTicks": 0, "PlayedPercentage": 0})
            data["LastPlayedDate"] = iso(datetime.now(timezone.utc))
        log(f"   ↳ {kind:8s} {self.items[iid]['Name']:24s} pos={position / TICKS:7.1f}s method={body.get('PlayMethod')} paused={body.get('IsPaused')} a={body.get('AudioStreamIndex')} s={body.get('SubtitleStreamIndex')}")

    def set_played(self, iid: str, played: bool):
        with self.lock:
            data = self.user_data[iid]
            data.update({"Played": played, "PlaybackPositionTicks": 0, "PlayedPercentage": 100.0 if played else 0, "PlayCount": 1 if played else 0})
            return dict(data)

    def set_favorite(self, iid: str, favorite: bool):
        with self.lock:
            self.user_data[iid]["IsFavorite"] = favorite
            return dict(self.user_data[iid])


class Transcoder:
    """Very small stand-in for Jellyfin's HLS transcoder: one ffmpeg per play session."""

    def __init__(self):
        self.sessions = {}
        self.lock = threading.Lock()
        self.tmp = tempfile.mkdtemp(prefix="foyer-mock-hls-")

    def start(self, session_id: str, path: str, video_codec: str, audio_ordinal: int, copy_video: bool, copy_audio: bool):
        with self.lock:
            if session_id in self.sessions:
                return self.sessions[session_id]["dir"]
            out = os.path.join(self.tmp, session_id)
            os.makedirs(out, exist_ok=True)
            cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", path, "-map", "0:v:0", "-map", f"0:a:{audio_ordinal}"]
            if copy_video:
                cmd += ["-c:v", "copy"]
            else:
                cmd += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-g", "48", "-keyint_min", "48", "-sc_threshold", "0"]
            cmd += ["-c:a", "copy"] if copy_audio else ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
            cmd += ["-f", "hls", "-hls_time", "4", "-hls_playlist_type", "event", "-hls_segment_type", "fmp4",
                    "-hls_flags", "independent_segments", "-hls_fmp4_init_filename", "init.mp4",
                    "-hls_segment_filename", os.path.join(out, "seg%04d.m4s"), os.path.join(out, "master.m3u8")]
            proc = subprocess.Popen(cmd)
            self.sessions[session_id] = {"dir": out, "proc": proc}
            log(f"   ↳ transcoder started session={session_id[:8]} video={'copy' if copy_video else 'h264'} audio={'copy' if copy_audio else 'aac'}")
            return out

    def stop(self, session_id: str):
        with self.lock:
            entry = self.sessions.pop(session_id, None)
        if entry:
            if entry["proc"].poll() is None:
                entry["proc"].terminate()
            shutil.rmtree(entry["dir"], ignore_errors=True)
            log(f"   ↳ transcoder stopped session={session_id[:8]}")

    def wait_for_playlist(self, session_id: str, timeout=25.0):
        """Jellyfin serves a complete VOD playlist; emulate that by waiting for ffmpeg to finish the
        (short) test clips, falling back to the partial event playlist for long inputs."""
        entry = self.sessions.get(session_id)
        if not entry:
            return None
        playlist = os.path.join(entry["dir"], "master.m3u8")
        deadline = time.time() + timeout
        while time.time() < deadline:
            finished = entry["proc"].poll() is not None
            if finished:
                return playlist if os.path.exists(playlist) else None
            time.sleep(0.2)
        return playlist if os.path.exists(playlist) and "#EXTINF" in open(playlist).read() else None


LOG_LOCK = threading.Lock()


def log(msg: str):
    with LOG_LOCK:
        print(f"{datetime.now().strftime('%H:%M:%S')} {msg}", flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    library: Library = None
    transcoder: Transcoder = None
    subtitle_cache = {}

    def log_message(self, fmt, *args):  # quieter default logging
        pass

    # MARK: Helpers

    def send_json(self, obj, status=200):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def send_empty(self, status=204):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_bytes(self, data: bytes, content_type: str, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def send_file(self, path: str, content_type: str):
        size = os.path.getsize(path)
        start, end = 0, size - 1
        range_header = self.headers.get("Range")
        status = 200
        if path.lower().endswith(MEDIA_EXT):
            log(f"   ↳ media request: Range={range_header} Connection={self.headers.get('Connection')} UA={self.headers.get('User-Agent')}")
        if range_header and range_header.startswith("bytes="):
            spec = range_header[6:].split(",")[0]
            a, _, b = spec.partition("-")
            if a:
                start = int(a)
                end = int(b) if b else size - 1
            else:
                start = max(0, size - int(b))
            end = min(end, size - 1)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            f.seek(start)
            remaining = length
            try:
                while remaining > 0:
                    chunk = f.read(min(1 << 20, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                log(f"   ↳ client closed the connection after {length - remaining} of {length} bytes")
                self.close_connection = True

    def read_body(self):
        # One handler instance serves every request on a keep-alive connection: cache per request only.
        if getattr(self, "_body_for", None) is not self.headers:
            length = int(self.headers.get("Content-Length") or 0)
            self._body = self.rfile.read(length) if length else b""
            self._body_for = self.headers
        return self._body

    def body_json(self):
        try:
            return json.loads(self.read_body()) if self.read_body() else {}
        except Exception:
            return {}

    def token(self, query: dict):
        auth = self.headers.get("Authorization") or self.headers.get("X-Emby-Authorization") or ""
        m = re.search(r'Token="([^"]*)"', auth)
        if m and m.group(1):
            return m.group(1)
        if self.headers.get("X-Emby-Token"):
            return self.headers["X-Emby-Token"]
        return query.get("api_key") or query.get("ApiKey")

    def authorized(self, query: dict) -> bool:
        return self.token(query) == TOKEN

    # MARK: Routing

    def do_GET(self):
        self.route("GET")

    def do_HEAD(self):
        self.route("HEAD")

    def do_POST(self):
        self.route("POST")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method: str):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        path = url.path
        lower = path.lower()
        started = time.time()
        self.read_body()  # keep-alive framing: consume the body even for endpoints that ignore it
        try:
            status = self.dispatch(method, path, lower, query)
        except (BrokenPipeError, ConnectionResetError):
            status = "closed"
        except Exception as exc:  # noqa: BLE001
            log(f"!! {method} {path}: {exc!r}")
            try:
                self.send_json({"error": str(exc)}, 500)
            except Exception:
                pass
            status = 500
        ms = int((time.time() - started) * 1000)
        if not lower.endswith((".m4s", ".jpg")):
            log(f"{method:6s} {status!s:4s} {path}{'?' + url.query[:80] if url.query and not lower.startswith('/videos') else ''} ({ms} ms)")

    def dispatch(self, method, path, lower, query):
        lib = self.library
        parts = [p for p in path.split("/") if p]
        lparts = [p.lower() for p in parts]

        # Anonymous endpoints
        if lower == "/system/info/public":
            self.send_json({"LocalAddress": f"http://{self.headers.get('Host')}", "ServerName": "Foyer Mock", "Version": "10.10.7",
                            "ProductName": "Jellyfin Server", "OperatingSystem": "", "Id": SERVER_ID, "StartupWizardCompleted": True})
            return 200
        if lower == "/users/public":
            self.send_json([self.user()])
            return 200
        if lower == "/quickconnect/enabled":
            self.send_bytes(b"false", "application/json")
            return 200
        if lower == "/users/authenticatebyname" and method == "POST":
            body = self.body_json()
            if (body.get("Username") or "").lower() == "test" and (body.get("Pw") or "") in ("", "test"):
                self.send_json({"User": self.user(), "SessionInfo": {"Id": "s1"}, "AccessToken": TOKEN, "ServerId": SERVER_ID})
                return 200
            self.send_empty(401)
            return 401
        if lower.startswith("/quickconnect/"):
            self.send_empty(404)
            return 404

        # Media URLs (token via api_key) and everything else requires the token.
        if not self.authorized(query):
            self.send_empty(401)
            return 401

        if lower == "/users/me":
            self.send_json(self.user())
            return 200
        if lower in ("/sessions/capabilities/full", "/sessions/logout"):
            self.send_empty(204)
            return 204
        if lower == "/userviews" or (len(lparts) == 3 and lparts[0] == "users" and lparts[2] == "views"):
            views = lib.views()
            self.send_json({"Items": views, "TotalRecordCount": len(views), "StartIndex": 0})
            return 200
        if lower == "/useritems/resume":
            items = [lib.card(i) for i in lib.resume_items()]
            self.send_json({"Items": items, "TotalRecordCount": len(items), "StartIndex": 0})
            return 200
        if lower == "/shows/nextup":
            items = [lib.card(i) for i in lib.next_up(query.get("seriesId"))]
            self.send_json({"Items": items, "TotalRecordCount": len(items), "StartIndex": 0})
            return 200
        if lower == "/items/latest":
            parent = query.get("parentId")
            pool = lib.movies() if parent == lib.movies_lib else lib.series() if parent == lib.shows_lib else lib.movies() + lib.series()
            pool = sorted(pool, key=lambda i: i.get("DateCreated") or "", reverse=True)[: int(query.get("limit") or 16)]
            self.send_json([lib.card(i) for i in pool])
            return 200
        if lower == "/items":
            page, total = lib.query(query)
            self.send_json({"Items": [lib.card(i) for i in page], "TotalRecordCount": total, "StartIndex": int(query.get("StartIndex") or 0)})
            return 200
        if len(lparts) >= 2 and lparts[0] == "shows" and lparts[-1] in ("seasons", "episodes"):
            series_id = parts[1]
            if lparts[-1] == "seasons":
                items = [lib.card(s) for s in lib.seasons(series_id)]
            else:
                items = [lib.card(e) for e in lib.episodes(series_id, query.get("seasonId"))]
            self.send_json({"Items": items, "TotalRecordCount": len(items), "StartIndex": 0})
            return 200
        if len(lparts) == 2 and lparts[0] == "mediasegments":
            segs = lib.segments.get(parts[1], [])
            self.send_json({"Items": segs, "TotalRecordCount": len(segs), "StartIndex": 0})
            return 200
        if lparts and lparts[0] == "episode":
            self.send_empty(404)
            return 404
        if lparts and lparts[0] in ("userplayeditems", "userfavoriteitems") and len(lparts) == 2:
            iid = parts[1]
            if iid not in lib.user_data:
                self.send_empty(404)
                return 404
            flag = method == "POST"
            data = lib.set_played(iid, flag) if lparts[0] == "userplayeditems" else lib.set_favorite(iid, flag)
            self.send_json(data)
            return 200
        if lower.startswith("/sessions/playing"):
            body = self.body_json()
            kind = "start" if lower == "/sessions/playing" else lparts[-1]
            lib.report(kind, body)
            self.send_empty(204)
            return 204
        if lower == "/videos/activeencodings" and method == "DELETE":
            self.transcoder.stop(query.get("playSessionId") or "")
            self.send_empty(204)
            return 204
        if lower == "/userimage":
            self.send_empty(404)
            return 404

        # /Items/{id}...
        if lparts and lparts[0] == "items" and len(lparts) >= 2:
            iid = parts[1]
            item = lib.items.get(iid)
            if item is None and iid not in (lib.movies_lib, lib.shows_lib):
                self.send_empty(404)
                return 404
            if len(lparts) == 2:
                if item is None:
                    view = next(v for v in lib.views() if v["Id"] == iid)
                    self.send_json(view)
                    return 200
                self.send_json(lib.with_user_data(item))
                return 200
            if lparts[2] == "similar":
                pool = [lib.card(i) for i in lib.items.values() if i["Type"] == item["Type"] and i["Id"] != iid]
                self.send_json({"Items": pool, "TotalRecordCount": len(pool), "StartIndex": 0})
                return 200
            if lparts[2] == "playbackinfo" and method == "POST":
                return self.playback_info(item, self.body_json(), query)
            if lparts[2] == "images":
                kind = lparts[3] if len(lparts) > 3 else "primary"
                art = lib.artwork.get((iid, kind))
                if art:
                    self.send_file(art, "image/jpeg")
                    return 200
                self.send_empty(404)
                return 404
        # /Videos/{id}/...
        if lparts and lparts[0] == "videos" and len(lparts) >= 3:
            iid = parts[1]
            if iid not in lib.files:
                self.send_empty(404)
                return 404
            if lparts[2].startswith("stream"):
                if iid in lib.broken:
                    self.send_empty(500)
                    return 500
                self.send_file(lib.files[iid], "video/x-matroska" if lib.files[iid].endswith(".mkv") else "video/mp4")
                return 200
            if lparts[2] == "master.m3u8":
                return self.hls_playlist(iid, query)
            if lparts[2] == "hls" and len(lparts) == 5:
                return self.hls_segment(parts[3], parts[4])
            if len(lparts) >= 7 and lparts[3] == "subtitles":
                return self.subtitle(iid, int(parts[4]), lparts[6].split(".")[-1])
            if lparts[2] == "trickplay" or (len(lparts) >= 4 and lparts[3] == "attachments"):
                self.send_empty(404)
                return 404
        self.send_empty(404)
        return 404

    # MARK: Playback

    def user(self):
        return {"Id": USER_ID, "Name": "test", "ServerId": SERVER_ID, "HasPassword": False, "HasConfiguredPassword": False,
                "Configuration": {"AudioLanguagePreference": "ger", "SubtitleLanguagePreference": "ger", "SubtitleMode": "Smart",
                                  "PlayDefaultAudioTrack": False, "EnableNextEpisodeAutoPlay": True},
                "Policy": {"IsAdministrator": False, "EnableMediaPlayback": True}}

    def playback_info(self, item, body, query):
        lib = self.library
        source = dict(item["MediaSources"][0])
        streams = [dict(s) for s in source["MediaStreams"]]
        session_id = uuid.uuid4().hex
        direct_play = bool(body.get("EnableDirectPlay", True))
        audio_index = body.get("AudioStreamIndex")
        subtitle_index = body.get("SubtitleStreamIndex")
        for s in streams:
            if s["Type"] == "Subtitle" and s.get("IsTextSubtitleStream"):
                ext = {"subrip": "srt", "ass": "ass", "ssa": "ass", "webvtt": "vtt", "mov_text": "srt"}.get(s["Codec"], "srt")
                s["DeliveryMethod"] = "External"
                s["DeliveryUrl"] = f"/Videos/{item['Id']}/{source['Id']}/Subtitles/{s['Index']}/0/Stream.{ext}?api_key={TOKEN}"
            elif s["Type"] == "Subtitle":
                s["DeliveryMethod"] = "Encode" if not direct_play else "Embed"
        source["MediaStreams"] = streams
        if audio_index is not None:
            source["DefaultAudioStreamIndex"] = audio_index
        source["DefaultSubtitleStreamIndex"] = subtitle_index if subtitle_index is not None else -1
        source["SupportsDirectPlay"] = direct_play
        if not direct_play:
            video = next((s for s in streams if s["Type"] == "Video"), {})
            audio_streams = [s for s in streams if s["Type"] == "Audio"]
            ordinal = next((i for i, s in enumerate(audio_streams) if s["Index"] == audio_index), 0)
            audio = audio_streams[ordinal] if audio_streams else {}
            copy_video = bool(body.get("EnableDirectStream", True)) and video.get("Codec") in ("h264", "hevc")
            copy_audio = copy_video and audio.get("Codec") in ("aac", "ac3", "eac3")
            params = {"DeviceId": query.get("deviceId", "foyer"), "MediaSourceId": source["Id"], "PlaySessionId": session_id,
                      "api_key": TOKEN, "VideoCodec": "copy" if copy_video else "h264", "AudioCodec": "copy" if copy_audio else "aac",
                      "AudioStreamIndex": audio_index if audio_index is not None else "", "SubtitleStreamIndex": subtitle_index if subtitle_index is not None else "",
                      "StartTimeTicks": body.get("StartTimeTicks") or 0, "TranscodeReasons": "ContainerNotSupported"}
            source["TranscodingUrl"] = f"/videos/{item['Id']}/master.m3u8?" + "&".join(f"{k}={v}" for k, v in params.items())
            source["TranscodingSubProtocol"] = "hls"
            source["TranscodingContainer"] = "mp4"
            source["_mock"] = {"copy_video": copy_video, "copy_audio": copy_audio, "ordinal": ordinal}
        log(f"   ↳ PlaybackInfo {item['Name']}: directPlay={direct_play} directStream={body.get('EnableDirectStream')} transcode={body.get('EnableTranscoding')} "
            f"a={audio_index} s={subtitle_index} start={int(body.get('StartTimeTicks') or 0) / TICKS:.0f}s profile: "
            f"{len((body.get('DeviceProfile') or {}).get('DirectPlayProfiles', []))} dp / {len((body.get('DeviceProfile') or {}).get('TranscodingProfiles', []))} tp")
        mock = source.pop("_mock", None)
        if mock:
            self.transcoder_hint = mock
            Handler.pending_transcodes[session_id] = (item["Id"], mock)
        self.send_json({"MediaSources": [source], "PlaySessionId": session_id})
        return 200

    pending_transcodes = {}

    def hls_playlist(self, iid, query):
        session_id = query.get("PlaySessionId") or query.get("playSessionId") or uuid.uuid4().hex
        if iid in self.library.broken:
            self.send_empty(500)
            return 500
        _, mock = Handler.pending_transcodes.get(session_id, (iid, {"copy_video": query.get("VideoCodec") == "copy", "copy_audio": query.get("AudioCodec") == "copy", "ordinal": 0}))
        self.transcoder.start(session_id, self.library.files[iid], "", mock["ordinal"], mock["copy_video"], mock["copy_audio"])
        playlist = self.transcoder.wait_for_playlist(session_id)
        if not playlist:
            self.send_empty(500)
            return 500
        text = open(playlist).read()
        if "#EXT-X-ENDLIST" in text:
            text = text.replace("#EXT-X-PLAYLIST-TYPE:EVENT", "#EXT-X-PLAYLIST-TYPE:VOD")
        # Segment URIs are relative; rewrite them to a route that carries the session id.
        base = f"/Videos/{iid}/hls/{session_id}/"
        rewritten = []
        for line in text.splitlines():
            if line.startswith("#EXT-X-MAP:URI="):
                line = line.replace('URI="', f'URI="{base}').replace('"', f'?api_key={TOKEN}"', 2).replace(f'?api_key={TOKEN}"{base}', f'"{base}', 1)
            elif line and not line.startswith("#"):
                line = f"{base}{line}?api_key={TOKEN}"
            rewritten.append(line)
        self.send_bytes(("\n".join(rewritten) + "\n").encode(), "application/vnd.apple.mpegurl")
        return 200

    def hls_segment(self, session_id, name):
        entry = self.transcoder.sessions.get(session_id)
        if not entry:
            self.send_empty(404)
            return 404
        path = os.path.join(entry["dir"], os.path.basename(name))
        deadline = time.time() + 10
        while not os.path.exists(path) and time.time() < deadline:
            time.sleep(0.1)
        if not os.path.exists(path):
            self.send_empty(404)
            return 404
        self.send_file(path, "video/mp4" if name.endswith((".m4s", ".mp4")) else "application/octet-stream")
        return 200

    def subtitle(self, iid, index, fmt):
        key = (iid, index, fmt)
        data = Handler.subtitle_cache.get(key)
        if data is None:
            external = self.library.external_subs.get((iid, index))
            if external:
                data = open(external, "rb").read()
            else:
                ffmt = {"srt": "srt", "ass": "ass", "vtt": "webvtt"}.get(fmt, "srt")
                proc = subprocess.run(["ffmpeg", "-v", "error", "-i", self.library.files[iid], "-map", f"0:{index}", "-f", ffmt, "-"], capture_output=True)
                if proc.returncode != 0:
                    self.send_empty(404)
                    return 404
                data = proc.stdout
            Handler.subtitle_cache[key] = data
        self.send_bytes(data, {"srt": "application/x-subrip", "ass": "text/x-ssa", "vtt": "text/vtt"}.get(fmt, "text/plain"))
        return 200


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--media", default=os.path.join(os.path.dirname(__file__), "media"))
    parser.add_argument("--port", type=int, default=8097)
    parser.add_argument("--bind", default="0.0.0.0")
    args = parser.parse_args()
    if not os.path.isdir(args.media):
        sys.exit(f"media folder {args.media} not found — run make-media.sh first")
    library = Library(args.media)
    Handler.library = library
    Handler.transcoder = Transcoder()
    log(f"library: {len(library.movies())} movies, {len(library.series())} series, {sum(1 for i in library.items.values() if i['Type'] == 'Episode')} episodes")
    for i in sorted(library.items.values(), key=lambda i: i["Name"]):
        if i["Type"] in ("Movie", "Episode"):
            s = i["MediaSources"][0]
            log(f"  {i['Type']:8s} {i['Name']:20s} {s['Container']:5s} " + ", ".join(f"{x['Type'][0]}{x['Index']}:{x['Codec']}{'/' + x['Language'] if x.get('Language') else ''}" for x in s["MediaStreams"]))
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    server.daemon_threads = True
    log(f"mock Jellyfin listening on http://{args.bind}:{args.port} — sign in as user 'test' without password")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        shutil.rmtree(Handler.transcoder.tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
