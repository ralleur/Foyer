#!/usr/bin/env python3
"""Remote-controls a Vela session through the Jellyfin server (development helper).

    JF_SERVER=http://server:8096 JF_USER=name JF_PW=secret Scripts/remote.py sessions
    Scripts/remote.py play "Dune" [--position 900] [--audio 2] [--subtitle -1]
    Scripts/remote.py pause | unpause | playpause | stop | next | previous | seek 1234 | rewind | forward
    Scripts/remote.py message "Dinner is ready" [--header Kitchen] [--timeout 5000]
    Scripts/remote.py audio 2 | subtitle -1
    Scripts/remote.py watch [seconds]          # prints what the server sees every 2 s

Targets the first session whose client is "Vela" and whose device name equals JF_DEVICE
(default "Apple TV", i.e. a real box; simulators report "Apple TV 4K (…)"), or --session ID.
Credentials come from the environment only; JF_TOKEN can replace JF_USER/JF_PW.
"""
import argparse, json, os, sys, time, urllib.parse, urllib.request

BASE = os.environ.get("JF_SERVER", "").rstrip("/")
AUTH = 'MediaBrowser Client="VelaRemote", Device="mac", DeviceId="vela-remote-mac", Version="1.0"'


def call(method, path, body=None, token=None, query=None):
    url = BASE + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, method=method, data=data)
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", AUTH + (f', Token="{token}"' if token else ""))
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def sign_in():
    if os.environ.get("JF_TOKEN"):
        return os.environ["JF_TOKEN"], False
    user, pw = os.environ.get("JF_USER"), os.environ.get("JF_PW")
    if not (BASE and user and pw is not None):
        sys.exit("set JF_SERVER and JF_USER/JF_PW (or JF_TOKEN)")
    return call("POST", "/Users/AuthenticateByName", {"Username": user, "Pw": pw})["AccessToken"], True


def describe(s):
    np, ps, ti = s.get("NowPlayingItem") or {}, s.get("PlayState") or {}, s.get("TranscodingInfo") or {}
    line = f"{s.get('Client')} | {s.get('DeviceName')} | {s.get('UserName')} | remote={'yes' if s.get('SupportsRemoteControl') else 'no'} | last={s.get('LastActivityDate', '')[11:19]}"
    if np:
        line += f" | ▶ {np.get('Name')} {ps.get('PositionTicks', 0) / 1e7:.0f}s {'paused' if ps.get('IsPaused') else ''} {ps.get('PlayMethod')}"
        if ti:
            line += f" [{ti.get('Container')} v={'copy' if ti.get('IsVideoDirect') else ti.get('VideoCodec')} a={'copy' if ti.get('IsAudioDirect') else ti.get('AudioCodec')} {ti.get('TranscodeReasons') or ''}]"
    return line


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command")
    ap.add_argument("argument", nargs="?")
    ap.add_argument("--session")
    ap.add_argument("--position", type=float, help="seconds")
    ap.add_argument("--audio", type=int)
    ap.add_argument("--subtitle", type=int)
    ap.add_argument("--header")
    ap.add_argument("--timeout", type=int, default=5000)
    args = ap.parse_args()
    token, logout = sign_in()
    try:
        sessions = call("GET", "/Sessions", token=token)
        if args.command == "sessions":
            for s in sessions:
                if s.get("Client") != "VelaRemote":
                    print(describe(s))
            return
        device = os.environ.get("JF_DEVICE", "Apple TV")
        candidates = [s for s in sessions if s.get("Client") == "Vela" and s.get("DeviceName") == device]
        candidates.sort(key=lambda s: (bool(s.get("SupportsRemoteControl")), s.get("LastActivityDate", "")), reverse=True)
        target = next((s for s in sessions if args.session and s["Id"].startswith(args.session)), None) or (candidates[0] if candidates else None)
        if not target:
            sys.exit(f"no Vela session on device '{device}' (see: sessions)")
        sid = target["Id"]
        if args.command == "watch":
            end = time.time() + float(args.argument or 60)
            last = None
            while time.time() < end:
                current = next((s for s in call("GET", "/Sessions", token=token) if s["Id"] == sid), None)
                line = describe(current) if current else "session gone"
                if line != last:
                    print(time.strftime("%H:%M:%S"), line, flush=True)
                    last = line
                time.sleep(2)
            return
        if args.command == "play":
            items = call("GET", "/Items", token=token, query={"searchTerm": args.argument, "recursive": "true", "includeItemTypes": "Movie,Episode", "limit": 5})["Items"]
            if not items:
                sys.exit("no match")
            item = items[0]
            q = {"playCommand": "PlayNow", "itemIds": item["Id"]}
            if args.position is not None:
                q["startPositionTicks"] = int(args.position * 1e7)
            if args.audio is not None:
                q["audioStreamIndex"] = args.audio
            if args.subtitle is not None:
                q["subtitleStreamIndex"] = args.subtitle
            call("POST", f"/Sessions/{sid}/Playing", token=token, query=q)
            print(f"sent PlayNow '{item.get('Name')}' ({item['Id']}) to {target.get('DeviceName')}")
            return
        state = {"pause": "Pause", "unpause": "Unpause", "playpause": "PlayPause", "stop": "Stop", "next": "NextTrack",
                 "previous": "PreviousTrack", "rewind": "Rewind", "forward": "FastForward", "seek": "Seek"}
        if args.command in state:
            q = {"seekPositionTicks": int(float(args.argument) * 1e7)} if args.command == "seek" else None
            call("POST", f"/Sessions/{sid}/Playing/{state[args.command]}", token=token, query=q)
            print(f"sent {state[args.command]}")
            return
        if args.command == "message":
            call("POST", f"/Sessions/{sid}/Message", token=token, body={"Text": args.argument or "", "Header": args.header or "", "TimeoutMs": args.timeout})
            print("sent DisplayMessage")
            return
        if args.command in ("audio", "subtitle"):
            name = "SetAudioStreamIndex" if args.command == "audio" else "SetSubtitleStreamIndex"
            call("POST", f"/Sessions/{sid}/Command", token=token, body={"Name": name, "Arguments": {"Index": str(int(args.argument))}})
            print(f"sent {name} {args.argument}")
            return
        sys.exit(f"unknown command {args.command}")
    finally:
        if logout:
            try:
                call("POST", "/Sessions/Logout", token=token)
            except Exception:
                pass


if __name__ == "__main__":
    main()
