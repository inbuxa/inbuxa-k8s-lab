#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Coffey Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""What the soak (K-L7) sees, and its reports.

  soak-watch.py collect        once a minute, from soak.sh
  soak-watch.py report DAY     that day's report, STATE/day-DAY.md
  soak-watch.py final          the whole run, STATE/report.md

collect reads, with kubectl (KCTX):
  - the sink's log: every message soak-load.py sent out, counted once per
    delivery (by the sink's own receive time)
  - the webmail tabs' summaries (chart/webmail-tabs.py, one pod or several
    over the run, summed)
  - every pod in the inbuxa, data, lab-sink and lab-soak namespaces: a pod
    that's new, or a container that restarted, is an event, planned when
    it falls in a chaos window (STATE/chaos.jsonl), unplanned otherwise

Everything is kept in STATE/watch.json, events in STATE/events.jsonl
beside soak-load.py's. Reports compare against the snapshot the previous
day's report took, so each day stands on its own.
"""
import json, os, re, subprocess, sys, time

STATE_DIR = os.environ["STATE"]
KCTX = os.environ["KCTX"]
DAY = int(os.environ.get("SOAK_DAY", "86400"))
NAMESPACES = ("inbuxa", "data", "lab-sink", "lab-soak")
WATCH = os.path.join(STATE_DIR, "watch.json")
EVENTS = os.path.join(STATE_DIR, "events.jsonl")
LOST_AFTER = int(os.environ.get("LOST_AFTER", "3600"))  # not there an hour after it was sent


def kubectl(*args):
    return subprocess.run(["kubectl", "--context", KCTX, *args], capture_output=True, text=True, timeout=120).stdout


def load(path, default):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return default


def save(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def event(kind, detail, at=None):
    with open(EVENTS, "a") as f:
        f.write(json.dumps({"at": at or time.time(), "kind": kind, "detail": str(detail)[:200]}) + "\n")


def new_lines(W, ns, selector, key):
    """Log lines of every pod matching `selector` since we last looked."""
    out = []
    for pod in kubectl("-n", ns, "get", "pods", "-l", selector, "-o", "name").split():
        since = W["since"].get(f"{key}/{pod}")
        args = ["-n", ns, "logs", pod, "--timestamps"] + (["--since-time", since] if since else [])
        last = since
        for line in kubectl(*args).splitlines():
            ts, _, text = line.partition(" ")
            if since and ts <= since:
                continue  # --since-time is inclusive, to the second
            out.append((pod, text))
            last = ts
        if last:
            W["since"][f"{key}/{pod}"] = last
    return out


def collect():
    W = load(WATCH, {"since": {}, "out": {}, "tabs": {}, "pods": {}, "first": True})
    load_state = load(os.path.join(STATE_DIR, "load.json"), {})
    run = load_state.get("run")

    # The sink: each soak message that reached it
    for _, text in new_lines(W, "lab-sink", "app=lab-sink", "sink"):
        try:
            rec = json.loads(text)
        except ValueError:
            continue
        m = re.fullmatch(rf"soak {run} out (\d+)", rec.get("subject", ""))
        if m:
            W["out"][m.group(1)] = W["out"].get(m.group(1), 0) + 1
            if W["out"][m.group(1)] == 2:
                event("out-twice", f"out {m.group(1)} reached the sink again")

    # The webmail tabs: the latest summary of each pod
    for pod, text in new_lines(W, "lab-soak", "app=soak-tabs", "tabs"):
        try:
            rec = json.loads(text)
        except ValueError:
            continue
        for e in rec.get("errors", []):
            event("webmail", f"{pod.split('/')[-1]}: {e}", rec.get("at"))
        rec.pop("errors", None)
        W["tabs"][pod] = rec

    # The pods
    now = time.time()
    seen = {}
    for ns in NAMESPACES:
        for p in json.loads(kubectl("-n", ns, "get", "pods", "-o", "json") or '{"items": []}')["items"]:
            uid = p["metadata"]["uid"]
            name = f"{ns}/{p['metadata']['name']}"
            statuses = p.get("status", {}).get("containerStatuses", []) or []
            restarts = sum(c.get("restartCount", 0) for c in statuses)
            seen[uid] = {"name": name, "restarts": restarts}
            before = W["pods"].get(uid)
            if before is None and not W["first"]:
                owner = (p["metadata"].get("ownerReferences") or [{}])[0].get("kind", "none")
                event("pod-new", f"{name} ({owner})", now)
            elif before and restarts > before["restarts"]:
                why = ", ".join(sorted({(c.get("lastState", {}).get("terminated") or {}).get("reason", "?")
                                        for c in statuses if c.get("restartCount", 0)}))
                event("restart", f"{name}: {restarts - before['restarts']} more ({why})", now)
    for uid, p in W["pods"].items():
        if uid not in seen:
            event("pod-gone", p["name"], now)
    W["pods"], W["first"] = seen, False
    save(WATCH, W)


def counters():
    """Every running total, flattened, for day-to-day differences."""
    L = load(os.path.join(STATE_DIR, "load.json"), {})
    W = load(WATCH, {"out": {}, "tabs": {}})
    tabs = list(W.get("tabs", {}).values())
    c = {f"in_{k}": v for k, v in L.get("inbound", {}).items() if k != "next"}
    c.update({f"out_{k}": v for k, v in L.get("outbound", {}).items() if k != "next"})
    c.update({f"idle_{k}": v for k, v in L.get("idle", {}).items() if k != "longest_quiet_s"})
    c["in_late"] = L.get("arrived_late", 0)
    c["out_received"] = len(W.get("out", {}))
    c["out_twice"] = sum(1 for v in W.get("out", {}).values() if v > 1)
    c["load_starts"] = L.get("starts", 0)
    for k in ("requests", "failed", "signins"):
        c[f"web_{k}"] = sum(t.get(k, 0) for t in tabs)
    for k in ("streams", "clean_ends", "cut_off"):
        c[f"web_{k}"] = sum(x.get(k, 0) for t in tabs for x in t.get("tabs", []))
    return c, L, W


def chaos_windows():
    out = []
    for line in open(os.path.join(STATE_DIR, "chaos.jsonl")) if os.path.exists(os.path.join(STATE_DIR, "chaos.jsonl")) else []:
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def events_between(a, b):
    out = []
    if os.path.exists(EVENTS):
        for line in open(EVENTS):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if a <= e["at"] < b:
                out.append(e)
    return out


def in_chaos(at, windows):
    # A minute's grace after, for what the collector notices late
    return any(w["start"] <= at <= w.get("end", time.time()) + 120 for w in windows)


def day_numbers(day, started):
    """(this day's counters, the day's start and end)."""
    c, L, W = counters()
    snap = os.path.join(STATE_DIR, f"day-{day}.json")
    prev = load(os.path.join(STATE_DIR, f"day-{day - 1}.json"), {}) if day > 1 else {}
    # Taken once, at the day's end; a report written again uses it
    if os.path.exists(snap):
        c = load(snap, c)
    else:
        save(snap, c)
    delta = {k: v - prev.get(k, 0) for k, v in c.items()}
    return delta, c, L, W, started + (day - 1) * DAY, started + day * DAY


def missing(L, W, now):
    lost_in = sorted(int(n) for n, t in L.get("pending", {}).items() if now - t > LOST_AFTER)
    lost_out = sorted(int(n) for n, t in L.get("out_sent", {}).items()
                      if now - t > LOST_AFTER and n not in W.get("out", {}))
    return lost_in, lost_out


def report(day):
    started = float(open(os.path.join(STATE_DIR, "started")).read())
    d, c, L, W, a, b = day_numbers(day, started)
    now = time.time()
    lost_in, lost_out = missing(L, W, now)
    windows = [w for w in chaos_windows() if a <= w["start"] < b]
    evs = events_between(a, b)
    restarts = [e for e in evs if e["kind"] in ("restart", "pod-new")]
    unplanned = [e for e in restarts if not in_chaos(e["at"], chaos_windows())]
    twice = d.get("in_twice", 0) + d.get("out_twice", 0)
    ok = not lost_in and not lost_out and not twice and not unplanned
    fmt = lambda t: time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(t))
    lines = [
        f"# Soak day {day}: {'clean' if ok else 'NOT clean'}",
        "",
        f"{fmt(a)} to {fmt(b)}, run `{L.get('run')}`, context `{KCTX}`.",
        "",
        "| | |",
        "|---|---|",
        f"| Mail in | {d.get('in_sent', 0)} sent, {d.get('in_arrived', 0)} arrived, {d.get('in_late', 0)} after 15 min, "
        f"{d.get('in_twice', 0)} twice, {d.get('in_retries', 0)} sends retried; slowest so far {L.get('slowest_s', 0)} s |",
        f"| Mail out | {d.get('out_sent', 0)} sent, {d.get('out_received', 0)} reached the sink, {d.get('out_twice', 0)} twice, "
        f"{d.get('out_retries', 0)} sends retried |",
        f"| Lost so far | in: {len(lost_in)} {lost_in[:10] if lost_in else ''}, out: {len(lost_out)} {lost_out[:10] if lost_out else ''} "
        f"(not there {LOST_AFTER // 60} min after sending) |",
        f"| IMAP IDLE | {d.get('idle_notices', 0)} new-mail notices, {d.get('idle_drops', 0)} drops; "
        f"longest quiet so far {L.get('idle', {}).get('longest_quiet_s', 0)} s |",
        f"| Webmail tabs | {d.get('web_requests', 0)} requests, {d.get('web_failed', 0)} failed, "
        f"{d.get('web_streams', 0)} streams ({d.get('web_cut_off', 0)} cut off), {d.get('web_signins', 0)} sign-ins |",
        f"| Restarts | {len(unplanned)} unplanned, {len(restarts) - len(unplanned)} during chaos |",
        f"| Load generator | started {d.get('load_starts', 0)} more time(s) |",
        "",
        "## Chaos",
        "",
    ]
    lines += [f"- {w['scenario']}: {w.get('result', 'still running')} ({fmt(w['start'])})" for w in windows] or ["- none today"]
    if unplanned:
        lines += ["", "## Unplanned", ""] + [f"- {fmt(e['at'])} {e['kind']}: {e['detail']}" for e in unplanned[:30]]
    kinds = {}
    for e in evs:
        kinds.setdefault(e["kind"], []).append(e)
    if kinds:
        lines += ["", "## Events", ""]
        for k, es in sorted(kinds.items()):
            lines.append(f"- {k}: {len(es)}; first: {es[0]['detail']}")
    text = "\n".join(lines) + "\n"
    open(os.path.join(STATE_DIR, f"day-{day}.md"), "w").write(text)
    print(text)
    return ok


def final():
    started = float(open(os.path.join(STATE_DIR, "started")).read())
    days = sorted(int(m.group(1)) for f in os.listdir(STATE_DIR) if (m := re.fullmatch(r"day-(\d+)\.md", f)))
    c, L, W = counters()
    lost_in, lost_out = missing(L, W, time.time())
    windows = chaos_windows()
    restarts = [e for e in events_between(started, time.time()) if e["kind"] in ("restart", "pod-new")]
    unplanned = [e for e in restarts if not in_chaos(e["at"], windows)]
    twice = c.get("in_twice", 0) + c.get("out_twice", 0)
    ok = not lost_in and not lost_out and not twice and not unplanned
    lines = [f"# Soak: {'PASSED' if ok else 'FAILED'}", "",
             f"{len(days)} day(s) from {time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(started))}, context `{KCTX}`.", "",
             f"- Mail in: {c.get('in_sent', 0)} sent, {c.get('in_arrived', 0)} arrived, {len(lost_in)} lost, {c.get('in_twice', 0)} twice",
             f"- Mail out: {c.get('out_sent', 0)} sent, {c.get('out_received', 0)} reached the sink, {len(lost_out)} lost, {c.get('out_twice', 0)} twice",
             f"- IMAP IDLE: {c.get('idle_notices', 0)} notices, {c.get('idle_drops', 0)} drops",
             f"- Webmail: {c.get('web_requests', 0)} requests, {c.get('web_failed', 0)} failed, {c.get('web_cut_off', 0)} streams cut off",
             f"- Restarts: {len(unplanned)} unplanned, {len(restarts) - len(unplanned)} during chaos",
             f"- Chaos: " + ", ".join(f"{w['scenario']} {w.get('result', '?')}" for w in windows), "",
             "| Day | |", "|---|---|"]
    for dnum in days:
        first = open(os.path.join(STATE_DIR, f"day-{dnum}.md")).readline().strip("# \n")
        lines.append(f"| {dnum} | {first} |")
    text = "\n".join(lines) + "\n"
    open(os.path.join(STATE_DIR, "report.md"), "w").write(text)
    print(text)
    return ok


if __name__ == "__main__":
    what = sys.argv[1]
    if what == "collect":
        collect()
    elif what == "report":
        sys.exit(0 if report(int(sys.argv[2])) else 1)
    elif what == "final":
        sys.exit(0 if final() else 1)
    else:
        sys.exit(__doc__)
