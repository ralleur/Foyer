#!/usr/bin/env python3
"""Nightly library check: plays every movie and episode of a Jellyfin library in Vela's self-test mode on a
tvOS simulator and keeps a ledger of what was checked.

    Tools/Nightly/nightly.py run [--mode new|all|failed] [--deadline HH:MM] [--limit N] [--per-item S] [--no-build] [--dry-run]
    Tools/Nightly/nightly.py summary [DATE]
    Tools/Nightly/nightly.py status

Configuration lives outside the repository in ~/.config/vela/nightly.env (KEY=VALUE lines):
    JF_SERVER=http://server:8096   JF_USER=name   JF_PW=secret
    VELA_REPO=/path/to/checkout    (default: this repository)
    VELA_NIGHTLY_DIR=~/VelaNightly (reports, ledger)
    VELA_SIM=Apple TV 4K (3rd generation)
    VELA_CAPABILITIES=appleTV4K    (decide routes like a real box)

Output per run in VELA_NIGHTLY_DIR/<date>/: report.jsonl (one line per item, written by the app), summary.md,
app.log. The ledger checked.json remembers each item's file etag/size and result; "new" mode tests items that
are unknown, changed, or failed fewer than three times. Watch state is restored by the app after every item.
Limits: the simulator plays HEVC HDR remuxes through Jellyfin's H.264 variant, so HDR/Dolby Vision decoding on
the box itself is not covered; everything else (routing, server remuxes, subtitles, audio switches, seeks) is.
"""
import argparse, datetime, json, os, re, subprocess, sys, time, urllib.parse, urllib.request, uuid, glob

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
BUNDLE = "com.ralleur.vela"


def load_env():
    path = os.path.expanduser("~/.config/vela/nightly.env")
    env = {}
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"')
    for key in ("JF_SERVER", "JF_USER", "JF_PW", "VELA_REPO", "VELA_NIGHTLY_DIR", "VELA_SIM", "VELA_SIM_UDID", "VELA_CAPABILITIES"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    env.setdefault("VELA_REPO", DEFAULT_REPO)
    env.setdefault("VELA_NIGHTLY_DIR", os.path.expanduser("~/VelaNightly"))
    env.setdefault("VELA_SIM", "Apple TV 4K (3rd generation)")
    env.setdefault("VELA_CAPABILITIES", "appleTV4K")
    env["VELA_NIGHTLY_DIR"] = os.path.expanduser(env["VELA_NIGHTLY_DIR"])
    return env


class Jellyfin:
    def __init__(self, base, user, pw, device_id):
        self.base = base.rstrip("/")
        self.auth = f'MediaBrowser Client="Vela", Device="Apple TV 4K (3rd generation)", DeviceId="{device_id}", Version="1.0"'
        self.token = None
        r = self.call("POST", "/Users/AuthenticateByName", {"Username": user, "Pw": pw})
        self.token, self.user_id, self.server_id, self.user_name = r["AccessToken"], r["User"]["Id"], r["ServerId"], r["User"]["Name"]
        self.info = self.call("GET", "/System/Info/Public")

    def call(self, method, path, body=None, query=None):
        url = self.base + path + ("?" + urllib.parse.urlencode(query) if query else "")
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", self.auth + (f', Token="{self.token}"' if self.token else ""))
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None

    def items(self):
        out, start = [], 0
        while True:
            page = self.call("GET", "/Items", query={"recursive": "true", "includeItemTypes": "Movie,Episode", "fields": "MediaSources,Path,DateCreated,Etag",
                                                     "sortBy": "DateCreated", "sortOrder": "Descending", "startIndex": start, "limit": 200})
            out += page.get("Items", [])
            start += 200
            if start >= page.get("TotalRecordCount", 0) or not page.get("Items"):
                return out


def sh(*args, check=True, capture=False):
    return subprocess.run(list(args), check=check, capture_output=capture, text=True)


def simulator_udid(name, env):
    """A booted simulator of that name wins, otherwise the newest tvOS runtime; VELA_SIM_UDID overrides."""
    if env.get("VELA_SIM_UDID"):
        return env["VELA_SIM_UDID"]
    data = json.loads(sh("xcrun", "simctl", "list", "devices", "available", "-j", capture=True).stdout)
    candidates = []
    for runtime, devices in data["devices"].items():
        if "tvOS" not in runtime:
            continue
        version = tuple(int(x) for x in re.findall(r"\d+", runtime.split(".")[-1]))
        for d in devices:
            if d["name"] == name:
                candidates.append((d["state"] == "Booted", version, d["udid"]))
    if not candidates:
        sys.exit(f"no tvOS simulator named {name!r}")
    candidates.sort(reverse=True)
    return candidates[0][2]


def build(repo, derived):
    print("building the simulator app …", flush=True)
    r = subprocess.run(["xcodebuild", "-project", os.path.join(repo, "Vela.xcodeproj"), "-scheme", "Vela",
                        "-destination", "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)",
                        "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO", "build"], capture_output=True, text=True)
    if r.returncode != 0:
        errors = [l for l in r.stdout.splitlines() if "error:" in l][:10]
        sys.exit("build failed:\n" + "\n".join(errors))


def sign_in(udid, container, jf):
    """Writes the account the way the app stores it on the simulator (defaults + secret file; no Keychain there)."""
    account = {"serverId": jf.server_id, "serverName": jf.info.get("ServerName", "Jellyfin"), "serverURL": jf.base, "serverVersion": jf.info.get("Version"),
               "userId": jf.user_id, "userName": jf.user_name, "userImageTag": None,
               "lastUsed": (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds()}
    def defaults(*args):
        sh("xcrun", "simctl", "spawn", udid, "defaults", "write", BUNDLE, *args)
    defaults("vela.deviceId", jf.auth.split('DeviceId="')[1].split('"')[0])
    defaults("vela.activeAccount", f"{jf.server_id}|{jf.user_id}")
    defaults("vela.accounts", "-data", json.dumps([account]).encode().hex())
    support = os.path.join(container, "Library", "Application Support")
    os.makedirs(support, exist_ok=True)
    json.dump({f"token.{jf.server_id}|{jf.user_id}": jf.token}, open(os.path.join(support, "simulator-secrets.json"), "w"))


def ordered(items):
    """Movies first, then one episode per season (newest series first), then the remaining episodes."""
    movies = [it for it in items if it.get("Type") == "Movie"]
    episodes = [it for it in items if it.get("Type") == "Episode"]
    seen, first, rest = set(), [], []
    for it in episodes:
        key = (it.get("SeriesId"), it.get("ParentIndexNumber"))
        (rest if key in seen else first).append(it)
        seen.add(key)
    return movies + first + rest


def budget_for(it, per_item):
    return per_item if it.get("Type") == "Movie" else min(per_item, 60)


def select_items(items, ledger, mode, limit):
    chosen = []
    for it in ordered(items):
        src = (it.get("MediaSources") or [{}])[0]
        key = it["Id"]
        entry = ledger.get(key)
        signature = f"{it.get('Etag')}|{src.get('Size')}|{src.get('Path')}"
        if mode == "all":
            take = True
        elif mode == "failed":
            take = bool(entry) and entry.get("result") in ("fail", "warn")
        else:  # new: unknown, changed, or failed fewer than three times
            take = entry is None or entry.get("signature") != signature or (entry.get("result") == "fail" and entry.get("failures", 0) < 3)
        if take:
            chosen.append(it)
        if limit and len(chosen) >= limit:
            break
    return chosen


def describe(it):
    if it.get("Type") == "Episode":
        return f"{it.get('SeriesName', '?')} S{it.get('ParentIndexNumber', 0):02d}E{it.get('IndexNumber', 0):02d} {it.get('Name', '')}"
    return f"{it.get('Name', '?')} ({it.get('ProductionYear', '')})"


def run(args, env):
    for key in ("JF_SERVER", "JF_USER", "JF_PW"):
        if not env.get(key):
            sys.exit(f"{key} missing in ~/.config/vela/nightly.env")
    repo, out_root = env["VELA_REPO"], env["VELA_NIGHTLY_DIR"]
    date = datetime.date.today().isoformat()
    out = os.path.join(out_root, date)
    os.makedirs(out, exist_ok=True)
    ledger_path = os.path.join(out_root, "checked.json")
    ledger = json.load(open(ledger_path)) if os.path.exists(ledger_path) else {}
    device_id = "vela-nightly-" + uuid.uuid5(uuid.NAMESPACE_DNS, "vela-nightly").hex[:12]
    jf = Jellyfin(env["JF_SERVER"], env["JF_USER"], env["JF_PW"], device_id)
    items = jf.items()
    chosen = select_items(items, ledger, args.mode, args.limit)
    estimate = sum(budget_for(it, args.per_item) + 8 for it in chosen) / 3600
    print(f"{len(items)} items in the library, {len(chosen)} to check ({args.mode}, about {estimate:.1f} h), deadline {args.deadline}", flush=True)
    if args.dry_run:
        for it in chosen[:50]:
            print("  ", describe(it))
        return
    if not chosen:
        write_summary(out, [], ledger, items, note="nothing to check")
        return
    derived = os.path.join(repo, "build", "DerivedData-sim")
    if not args.no_build:
        build(repo, derived)
    app = os.path.join(derived, "Build", "Products", "Debug-appletvsimulator", "Vela.app")
    udid = simulator_udid(env["VELA_SIM"], env)
    sh("xcrun", "simctl", "boot", udid, check=False, capture=True)
    sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False, capture=True)
    sh("xcrun", "simctl", "install", udid, app)
    container = sh("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data", capture=True).stdout.strip()
    sign_in(udid, container, jf)
    selftest = os.path.join(container, "Library", "Caches", "SelfTest")
    os.makedirs(selftest, exist_ok=True)
    for name in ("report.jsonl", "state.json"):
        path = os.path.join(selftest, name)
        if os.path.exists(path):
            os.remove(path)
    json.dump({"items": [{"id": it["Id"], "seconds": budget_for(it, args.per_item)} for it in chosen], "perItemSeconds": args.per_item, "deadline": args.deadline,
               "startFraction": 0.1, "maxSubtitleTracks": 4, "maxAudioTracks": 2}, open(os.path.join(selftest, "queue.json"), "w"))
    sh("xcrun", "simctl", "launch", udid, BUNDLE, "-selftest", "queue", "-capabilities", env["VELA_CAPABILITIES"], "-AppleLanguages", "(de)", "-AppleLocale", "de_DE", capture=True)
    print("app launched; waiting for the self-test …", flush=True)
    deadline = parse_deadline(args.deadline) + datetime.timedelta(minutes=8)
    state_path, report_path = os.path.join(selftest, "state.json"), os.path.join(selftest, "report.jsonl")
    last_index = -1
    while True:
        time.sleep(15)
        state = json.load(open(state_path)) if os.path.exists(state_path) else None
        if state and state.get("index") != last_index:
            last_index = state["index"]
            print(f"  {datetime.datetime.now():%H:%M:%S} {state['index']}/{state['total']} {state.get('current') or ''}", flush=True)
        if state and state.get("finished"):
            break
        running = BUNDLE in sh("xcrun", "simctl", "listapps", udid, capture=True).stdout and sh("xcrun", "simctl", "spawn", udid, "launchctl", "list", capture=True, check=False).stdout.find("UIKitApplication:" + BUNDLE) >= 0
        if not running:
            print("the app is no longer running", flush=True)
            break
        if datetime.datetime.now() > deadline:
            print("past the deadline; stopping the app", flush=True)
            sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False, capture=True)
            break
    reports = [json.loads(l) for l in open(report_path)] if os.path.exists(report_path) else []
    for name in ("report.jsonl", "state.json", "queue.json"):
        src = os.path.join(selftest, name)
        if os.path.exists(src):
            sh("cp", src, os.path.join(out, name))
    log = os.path.join(container, "Library", "Caches", "Logs", "vela.log")
    if os.path.exists(log):
        sh("cp", log, os.path.join(out, "app.log"))
    by_id = {it["Id"]: it for it in items}
    for r in reports:
        it = by_id.get(r["id"], {})
        src = (it.get("MediaSources") or [{}])[0]
        entry = ledger.get(r["id"], {"failures": 0})
        entry.update({"name": describe(it) if it else r.get("name"), "signature": f"{it.get('Etag')}|{src.get('Size')}|{src.get('Path')}",
                      "lastChecked": date, "result": r["result"], "route": r.get("route"), "failures": entry.get("failures", 0) + (1 if r["result"] == "fail" else 0)})
        if r["result"] != "fail":
            entry["failures"] = 0
        ledger[r["id"]] = entry
    json.dump(ledger, open(ledger_path, "w"), indent=1, sort_keys=True)
    write_summary(out, reports, ledger, items)


def parse_deadline(text):
    hour, minute = [int(x) for x in text.split(":")]
    now = datetime.datetime.now()
    d = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    return d if d > now else d + datetime.timedelta(days=1)


def write_summary(out, reports, ledger, items, note=None):
    counts = {k: sum(1 for r in reports if r["result"] == k) for k in ("ok", "warn", "fail")}
    unchecked = sum(1 for it in items if it["Id"] not in ledger)
    lines = [f"# Vela Nachtprüfung {os.path.basename(out)}", "",
             f"- Geprüft: {len(reports)} Titel (ok {counts['ok']}, Warnung {counts['warn']}, Fehler {counts['fail']})",
             f"- Bibliothek: {len(items)} Titel, davon noch nie geprüft: {unchecked}", ""]
    if note:
        lines.append(f"_{note}_")
    for kind, title in (("fail", "## Fehler"), ("warn", "## Warnungen")):
        rows = [r for r in reports if r["result"] == kind]
        if rows:
            lines.append(title)
            for r in rows:
                label = r["name"] + (f" ({r['series']} {r.get('episode', '')})" if r.get("series") else "")
                lines.append(f"- **{label}** — {r.get('container')} / {r.get('video')} / {r.get('range')} → {r.get('route')} ({r.get('method')})")
                if not r.get("plays"):
                    lines.append("  - spielt nicht" + (f" (bereit nach {r.get('readySeconds')} s)" if r.get('readySeconds') else ""))
                for c in r.get("subtitleChecks", []) + r.get("audioChecks", []):
                    if c["result"] not in ("ok",):
                        lines.append(f"  - Spur #{c['index']} {c['label']}: {c['result']}" + (f" ({c['detail']})" if c.get("detail") else ""))
                if r.get("seekResult") == "fail":
                    lines.append("  - Seek fehlgeschlagen")
                for e in r.get("errors", [])[:6]:
                    lines.append(f"  - `{e[:200]}`")
            lines.append("")
    ok_rows = [r for r in reports if r["result"] == "ok"]
    if ok_rows:
        lines.append("## In Ordnung")
        lines.append(", ".join(r["name"] for r in ok_rows[:80]) + (" …" if len(ok_rows) > 80 else ""))
    text = "\n".join(lines) + "\n"
    open(os.path.join(out, "summary.md"), "w").write(text)
    print(text)


def summary(args, env):
    root = env["VELA_NIGHTLY_DIR"]
    pattern = re.compile(r"\d{4}-\d{2}-\d{2}")
    date = args.date or sorted(d for d in os.listdir(root) if pattern.match(d))[-1]
    print(open(os.path.join(root, date, "summary.md")).read())


def status(args, env):
    root = env["VELA_NIGHTLY_DIR"]
    ledger_path = os.path.join(root, "checked.json")
    ledger = json.load(open(ledger_path)) if os.path.exists(ledger_path) else {}
    counts = {}
    for e in ledger.values():
        counts[e.get("result")] = counts.get(e.get("result"), 0) + 1
    runs = sorted(d for d in os.listdir(root) if re.match(r"\d{4}-\d{2}-\d{2}", d)) if os.path.exists(root) else []
    print(f"ledger: {len(ledger)} items {counts}; runs: {runs}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--mode", choices=["new", "all", "failed"], default="new")
    r.add_argument("--deadline", default="06:00")
    r.add_argument("--limit", type=int, default=0)
    r.add_argument("--per-item", type=float, default=150)
    r.add_argument("--no-build", action="store_true")
    r.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("summary"); s.add_argument("date", nargs="?")
    sub.add_parser("status")
    args = ap.parse_args()
    env = load_env()
    {"run": run, "summary": summary, "status": status}[args.command](args, env)


if __name__ == "__main__":
    main()
