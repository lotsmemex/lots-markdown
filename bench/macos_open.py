#!/usr/bin/env python3
"""Launch-to-first-frame benchmark for the macOS viewer.

Runs the app binary on each file N times, interleaved, and reports medians of the
app's own LM_BENCH events (process start -> first frame, open -> first frame,
Markdown -> HTML, process start -> preview ready). Optionally runs a floor binary
(an empty AppKit window) the same way, so results on a loaded machine can be read
relative to what AppKit itself costs. Prints the load average with the results.

usage: bench/macos_open.py APP_BINARY FILE... [--runs 15] [--floor FLOOR_BINARY]
"""
import argparse, json, os, statistics, subprocess

ap = argparse.ArgumentParser()
ap.add_argument("app"); ap.add_argument("files", nargs="+")
ap.add_argument("--runs", type=int, default=15); ap.add_argument("--floor")
a = ap.parse_args()

def run_app(path, textkit):
    env = dict(os.environ, LM_BENCH="1", LM_BENCH_EXIT="1", LM_TEXTKIT="1" if textkit == 1 else "0")
    err = subprocess.run([a.app, path], env=env, capture_output=True, text=True, timeout=120).stderr
    ev = {}
    for line in err.splitlines():
        if line.startswith("{"):
            d = json.loads(line); ev[d["event"]] = d
    return {"start_to_frame": ev["first_frame"]["since_start_ms"], "open_to_frame": ev["first_frame"]["open_to_frame_ms"],
            "render": ev["rendered"]["render_ms"], "start_to_preview": ev["preview_ready"]["since_start_ms"]}

def run_floor():
    out = subprocess.run([a.floor], capture_output=True, text=True, timeout=60).stdout.split()
    return float(out[out.index("frame") + 1])

results, floor = {}, []
for _ in range(a.runs):
    for f in a.files:
        for tk in (2, 1):
            results.setdefault((os.path.basename(f), tk), []).append(run_app(f, tk))
        if a.floor: floor.append(run_floor())

print("load average:", " ".join("%.1f" % x for x in os.getloadavg()), "| runs:", a.runs)
if floor: print("empty AppKit window, start->frame median: %.0f ms" % statistics.median(floor))
print("%-10s %-4s %14s %14s %10s %16s" % ("file", "tk", "start->frame", "open->frame", "render", "start->preview"))
for (f, tk), rows in results.items():
    m = lambda k: statistics.median(r[k] for r in rows)
    print("%-10s %-4s %11.0f ms %11.0f ms %7.0f ms %13.0f ms" % (f, tk, m("start_to_frame"), m("open_to_frame"), m("render"), m("start_to_preview")))
