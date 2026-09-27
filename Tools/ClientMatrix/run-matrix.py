#!/usr/bin/env python3
"""Plays every client-matrix title on a client session of the test server and records what happens.

The client must be signed in to the test server (Tools/ClientMatrix/test-server.sh, user matrix/matrix)
and must accept Jellyfin remote-control commands (the "Play on" menu of the web dashboard). For each
row the script sends PlayNow to the client's session, then reads the session from the server: play
method (direct play / remux / transcode), transcode reasons, selected audio and subtitle stream,
whether the position advances. With --sim it also takes simulator screenshots while subtitle cues are
on screen; with --ask it asks the tester what the TV and the receiver show (real Apple TV runs).

  run-matrix.py --client Moonfin [--sim UDID] [--ask] [--rows M04,M05] [--out DIR]
"""
import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.normpath(os.path.join(HERE, "..", "..", "build", "client-matrix"))
AUTH = 'MediaBrowser Client="ClientMatrix", Device="harness", DeviceId="client-matrix-harness", Version="1.0"'

# row → (title prefix, expectation text, expected audio stream index, expected subtitle index or None)
# Stream indices follow Jellyfin's numbering (video 0, then audio, then embedded subs, then external subs).
ROWS = [
    ("M01", "MP4 H.264 + AAC + ext. SRT", "Direct Play", 1, -1),
    ("M02", "MP4 H.264 + AC-3 5.1", "Direct Play, AC-3 passthrough", 1, None),
    ("M03", "MKV HEVC 4K SDR + E-AC-3", "Direct Play (no server work)", 1, None),
    ("M04", "MKV HEVC 4K HDR10 + E-AC-3", "HDR kept: Direct Play or remux (video copied)", 1, None),
    ("M05", "MP4 dvh1 DV P8.1", "Direct Play, Dolby Vision", 1, None),
    ("M06", "MKV DV P5", "DV kept: Direct Play or remux; never a video transcode", 1, None),
    ("M07", "MKV HEVC + DTS 5.1", "Direct Play (DTS decoded on device)", 1, None),
    ("M09", "MKV HEVC SDR + TrueHD 5.1", "Direct Play (TrueHD decoded on device)", 1, None),
    ("M10", "MKV HEVC 4K HDR10 + TrueHD", "HDR kept; audio converted at most", 1, None),
    ("M11", "MKV + ASS (DE) + audio EN", "Direct Play, ASS styled (smart subs → DE)", 1, 2),
    ("M12", "MKV 4K HDR10 + PGS (DE) + audio EN", "PGS shown without burn-in", 1, 2),
    ("M14", "MP4 HEVC hev1", "Direct Play or remux, no video transcode", 1, None),
    ("M15", "Forced DE + German audio", "audio DE (1) + forced DE subtitles (3)", 1, 3),
    ("M16", "TrueHD en (default) / E-AC-3 de / DTS en", "German E-AC-3 (2) despite default flag", 2, None),
    ("M17", "2 versions (2160p HDR10 MKV / 1080p MP4)", "plays default version; version picker in UI", 1, None),
    ("M18", "MKV AV1 1080p", "Direct Play (dav1d/HW) or transcode", 1, None),
    ("M19", "MKV AV1 4K", "Transcode acceptable without AV1 hardware", 1, None),
    ("M21", "MP4 H.264 1080i", "Direct Play, deinterlaced", 1, None),
    ("M22", "MKV HEVC 1080p 120 fps", "Direct Play or transcode (> 60 fps)", 1, None),
]


class Server:
    def __init__(self, url, token):
        self.url, self.token = url.rstrip("/"), token

    def call(self, method, path, body=None):
        req = urllib.request.Request(self.url + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Authorization", f'{AUTH}, Token="{self.token}"')
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None


def find_session(server, client):
    for s in server.call("GET", "/Sessions?activeWithinSeconds=900"):
        if client.lower() in (s.get("Client") or "").lower() and s.get("UserName"):
            return s
    return None


def items(server, user_id):
    q = urllib.parse.urlencode({"Recursive": "true", "IncludeItemTypes": "Movie,Episode",
                                "Fields": "MediaSources,MediaStreams,Path", "userId": user_id})
    return server.call("GET", f"/Items?{q}")["Items"]


def shot(udid, path):
    subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", path],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def describe_stream(item, index):
    if index is None or index < 0:
        return "none"
    for src in item.get("MediaSources", [])[:1]:
        for st in src.get("MediaStreams", []):
            if st.get("Index") == index:
                return f"{index}: {st.get('Type')} {st.get('Codec')} {st.get('Language') or ''} {'forced' if st.get('IsForced') else ''}".strip()
    return str(index)


def play_and_observe(server, sid, item, args, outdir, row, extra_query=None, wait_end=False):
    q = {"playCommand": "PlayNow", "itemIds": item["Id"], "startPositionTicks": 0}
    q.update(extra_query or {})
    server.call("POST", f"/Sessions/{sid}/Playing?{urllib.parse.urlencode(q)}")
    started, samples, first_pos, last = None, [], None, None
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        s = next((x for x in server.call("GET", "/Sessions") if x["Id"] == sid), None)
        if s and s.get("NowPlayingItem", {}).get("Id") == item["Id"]:
            ps = s.get("PlayState", {})
            pos = (ps.get("PositionTicks") or 0) / 1e7
            if started is None:
                started, first_pos = time.time(), pos
            last = s
            samples.append(round(pos, 1))
            elapsed = time.time() - started
            if args.sim and elapsed >= 2 and not os.path.exists(f"{outdir}/{row}-a.png"):
                shot(args.sim, f"{outdir}/{row}-a.png")
            if args.sim and elapsed >= 6.5 and not os.path.exists(f"{outdir}/{row}-b.png"):
                shot(args.sim, f"{outdir}/{row}-b.png")
            if elapsed >= args.watch and not wait_end:
                break
        elif wait_end and started and s and s.get("NowPlayingItem"):
            last = s  # moved on (e.g. next episode)
            break
        time.sleep(1)
    if args.sim and not os.path.exists(f"{outdir}/{row}-a.png"):
        shot(args.sim, f"{outdir}/{row}-fail.png")
    return started is not None, first_pos, samples, last


def summarize(item, ok, samples, s):
    if not ok or not s:
        return {"plays": False, "method": "—", "detail": "never reported as playing"}
    ps, ti = s.get("PlayState", {}), s.get("TranscodingInfo") or {}
    method = ps.get("PlayMethod") or "?"
    if method == "Transcode" and ti:
        if ti.get("IsVideoDirect") and ti.get("IsAudioDirect"):
            method = "Remux"
        elif ti.get("IsVideoDirect"):
            method = "DirectStream (audio conv.)"
    advancing = len(samples) >= 3 and samples[-1] - samples[0] >= 2
    detail = []
    if ti:
        detail.append(f"{ti.get('Container')} v={ti.get('VideoCodec')} a={ti.get('AudioCodec')}")
        if ti.get("TranscodeReasons"):
            detail.append("reasons=" + ",".join(ti["TranscodeReasons"]))
    return {
        "plays": advancing, "method": method, "detail": "; ".join(detail),
        "audio": describe_stream(item, ps.get("AudioStreamIndex")),
        "subtitle": describe_stream(item, ps.get("SubtitleStreamIndex")),
        "audioIndex": ps.get("AudioStreamIndex"), "subtitleIndex": ps.get("SubtitleStreamIndex"),
        "positions": samples[-6:],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--client", required=True, help="substring of the Jellyfin client name, e.g. Moonfin")
    ap.add_argument("--server", default="http://127.0.0.1:8097")
    ap.add_argument("--sim", help="simulator UDID for screenshots")
    ap.add_argument("--ask", action="store_true", help="ask the tester for TV/AVR observations per row")
    ap.add_argument("--rows", help="comma separated subset, e.g. M04,M05,SHOW")
    ap.add_argument("--watch", type=float, default=12, help="seconds to observe each title")
    ap.add_argument("--timeout", type=float, default=45)
    ap.add_argument("--out")
    args = ap.parse_args()

    state = json.load(open(os.path.join(BASE, "state.json")))
    server = Server(args.server, state["token"])
    session = find_session(server, args.client)
    if not session:
        sys.exit(f"no signed-in session for client '{args.client}' on {args.server} — open the app and sign in as matrix/matrix")
    sid = session["Id"]
    print(f"session: {session.get('Client')} {session.get('ApplicationVersion')} on {session.get('DeviceName')} "
          f"(remote control: {session.get('SupportsRemoteControl')}, media control: {session.get('SupportsMediaControl')})")

    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    outdir = args.out or os.path.join(BASE, "results", f"{args.client.lower()}-{stamp}")
    os.makedirs(outdir, exist_ok=True)
    catalog = items(server, state["userId"])
    by_prefix = {}
    for it in catalog:
        by_prefix.setdefault(it["Name"].split(" ")[0], it)
    wanted = set(args.rows.split(",")) if args.rows else None
    results = []

    for row, what, expect, exp_audio, exp_sub in ROWS:
        if wanted and row not in wanted:
            continue
        item = by_prefix.get(row)
        if not item:
            print(f"{row}: not in library, skipped"); continue
        print(f"▶ {row} {what}")
        ok, _, samples, s = play_and_observe(server, sid, item, args, outdir, row)
        r = summarize(item, ok, samples, s)
        r.update(row=row, what=what, expect=expect)
        r["audioOk"] = r.get("audioIndex") == exp_audio if r.get("plays") else None
        r["subtitleOk"] = (r.get("subtitleIndex", -1) if r.get("subtitleIndex") is not None else -1) == exp_sub if exp_sub is not None and r.get("plays") else None
        if args.ask:
            r["tv"] = input("  TV (HDR/DV/SDR, picture ok?): ").strip()
            r["avr"] = input("  receiver audio format: ").strip()
            r["note"] = input("  note: ").strip()
        print(f"  {r['method']}  plays={r['plays']}  audio={r.get('audio')}  sub={r.get('subtitle')}  {r['detail']}")
        results.append(r)
        try:
            server.call("POST", f"/Sessions/{sid}/Playing/Stop")
        except Exception:
            pass
        time.sleep(3)

    if not wanted or "SHOW" in wanted:
        episodes = sorted([i for i in catalog if i["Type"] == "Episode"], key=lambda i: i.get("IndexNumber") or 0)
        if episodes:
            e1 = episodes[0]
            print("▶ SHOW skip intro: S01E01 from 0 s, screenshots at ~8 s and ~12 s")
            args_watch, args.watch = args.watch, 14
            ok, _, samples, s = play_and_observe(server, sid, e1, args, outdir, "SHOW-intro")
            args.watch = args_watch
            server.call("POST", f"/Sessions/{sid}/Playing/Stop"); time.sleep(3)
            print("▶ SHOW next episode: S01E01 from 62 s, wait for the end (autoplay → S01E02?)")
            ok, _, samples, s = play_and_observe(server, sid, e1, args, outdir, "SHOW-credits",
                                                 {"startPositionTicks": 62 * 10_000_000}, wait_end=True)
            nxt = (s or {}).get("NowPlayingItem", {}).get("Name") if s else None
            results.append({"row": "SHOW", "what": "skip intro / next episode", "expect": "skip prompt 5–30 s; next-episode prompt at credits; autoplay E02",
                            "plays": ok, "method": "(see screenshots)", "detail": f"after E01 end now playing: {nxt}"})
            try:
                server.call("POST", f"/Sessions/{sid}/Playing/Stop")
            except Exception:
                pass

    with open(os.path.join(outdir, "results.json"), "w") as fh:
        json.dump({"client": session.get("Client"), "version": session.get("ApplicationVersion"),
                   "device": session.get("DeviceName"), "results": results}, fh, indent=2, ensure_ascii=False)
    with open(os.path.join(outdir, "results.md"), "w") as fh:
        fh.write(f"# {session.get('Client')} {session.get('ApplicationVersion')} — {session.get('DeviceName')} — {stamp}\n\n")
        fh.write("| Row | Media | Expected | Plays | Server | Audio | Subtitle | Detail |\n|---|---|---|---|---|---|---|---|\n")
        for r in results:
            a = r.get("audio", "")
            if r.get("audioOk") is False: a += " ✗"
            sub = r.get("subtitle", "")
            if r.get("subtitleOk") is False: sub += " ✗"
            fh.write(f"| {r['row']} | {r['what']} | {r['expect']} | {'✓' if r.get('plays') else '✗'} | {r['method']} | {a} | {sub} | {r['detail']} |\n")
    print(f"✔ results in {outdir}")


if __name__ == "__main__":
    main()
