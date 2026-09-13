#!/usr/bin/env python3
"""Turn a captured `##BENCH##` stream into the numbers the comparison reports.

Both apps emit the same events with the same meaning from the same clock, so
the same parser runs over both logs and nothing framework-specific leaks into
the arithmetic.

  startup  main_enter  -> first_frame
  ttff     ctrl_create -> ctrl_ready, per row (player built -> first frame ready)
  settle   page_settle -> play_call, per row (page lands -> playback starts)

Usage: parse_bench.py <log> [<log> ...]
"""
import json
import re
import statistics
import sys

LINE = re.compile(r"##BENCH## (\{.*\})")


def load(path):
    events = []
    with open(path, errors="replace") as fh:
        for line in fh:
            m = LINE.search(line)
            if m:
                try:
                    events.append(json.loads(m.group(1)))
                except json.JSONDecodeError:
                    pass
    return events


def summarize(events):
    by = {}
    for e in events:
        by.setdefault(e["ev"], []).append(e)

    out = {"tag": events[0]["tag"] if events else "?", "n_events": len(events)}

    if "main_enter" in by and "first_frame" in by:
        out["startup_ms"] = round(
            (by["first_frame"][0]["t_us"] - by["main_enter"][0]["t_us"]) / 1000, 1
        )

    # TTFF: pair each create with the ready for the same row.
    created = {e["i"]: e["t_us"] for e in by.get("ctrl_create", [])}
    ttff = [
        (e["t_us"] - created[e["i"]]) / 1000
        for e in by.get("ctrl_ready", [])
        if e["i"] in created
    ]
    if ttff:
        out["ttff_ms"] = {
            "n": len(ttff),
            "median": round(statistics.median(ttff), 1),
            "min": round(min(ttff), 1),
            "max": round(max(ttff), 1),
        }

    # Settle -> play: how fast playback follows the page landing.
    settles = {e["i"]: e["t_us"] for e in by.get("page_settle", [])}
    lag = []
    for e in by.get("play_call", []):
        if e["i"] in settles and e["t_us"] >= settles[e["i"]]:
            lag.append((e["t_us"] - settles[e["i"]]) / 1000)
    if lag:
        out["settle_to_play_ms"] = {
            "n": len(lag),
            "median": round(statistics.median(lag), 1),
            "max": round(max(lag), 1),
        }

    out["pages_visited"] = len(settles)
    out["errors"] = len(by.get("ctrl_error", []))
    if "paging_native" in by:
        out["paging_native_code"] = by["paging_native"][0].get("code")
    return out


if __name__ == "__main__":
    for path in sys.argv[1:]:
        events = load(path)
        if not events:
            print(f"{path}: no ##BENCH## lines")
            continue
        print(json.dumps({"log": path, **summarize(events)}, indent=2))
