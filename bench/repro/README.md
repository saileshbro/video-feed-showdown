# Repro recordings

Screen recordings of both feeds on the same iOS Simulator (iPhone 17 Pro
Max, iOS 26.4), same 13-item Pexels list, same pool/eviction/paging logic.
Captured with `argent screen-recording-start/stop`
(`showTouches: true`, so touch markers are visible).

| File | Shows |
|---|---|
| `dartnative-scroll-autoplay.mp4` | 4 flicks forward + 1 back — one-flick-one-page paging, autoplay following the settled page |
| `flutter-scroll-autoplay.mp4` | Same interaction on `PageView` |
| `dartnative-fast-scroll-loadtest.mp4` | 8 rapid swipes (500ms apart) — deliberately outruns the 2-ahead preload window to force cold loads |
| `flutter-fast-scroll-loadtest.mp4` | Same rapid-swipe test — a buffering spinner appears mid-clip |

The two `-loadtest` clips are the direct answer to "the videos load way
faster on DartNative": both apps get the same rapid-swipe stress test,
same device, same session. DartNative's paging is locked to one page per
swipe (see `RESULTS.md` §2), so it visits fewer, always-preloaded rows in
the same time; Flutter's `PageView` carries further per swipe and lands
on rows the 3-controller pool never had a chance to warm, which is what
the visible spinner is.

## How they were made

```sh
# DartNative
cd dartnative && dn run -d <simulator-udid>
# Flutter
cd flutter && flutter run -d <simulator-udid>
```

Then, via argent: `screen-recording-start` → a sequence of
`gesture-swipe` (momentum-free, so the interaction is deterministic
rather than dependent on simulated fling speed) → `screen-recording-stop`.
Only one app runs on the simulator at a time — both apps' native binaries
are named `Runner`, so the OS log stream cross-talks between them if both
are alive simultaneously (caught and discarded once; see the commit
history / `RESULTS.md`).

Videos are re-encoded (`ffmpeg -vf scale=540:-2 -crf 28`) from the raw
argent capture to keep the repo small; the raw captures are not kept.
