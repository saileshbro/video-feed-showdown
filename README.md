# DartNative vs Flutter: an infinite video feed

A TikTok-style vertical video feed, built twice — once in
[DartNative](https://dartnative.com) (native `UITableView`/`RecyclerView`
UI, no Flutter renderer), once in stock Flutter — to answer three
questions honestly: does DartNative's video feed actually load faster,
can you get `PageView`-style paging on a framework that doesn't ship one,
and what does it cost to find out.

Background: [DartNative wants Flutter developers to ship native UI from
Dart](https://saileshdahal.com.np/dartnative-flutter-native-ui-framework)
— a review of the framework's claims and licensing. This repo is the
follow-through on that post's closing line: *"I would give DartNative
one ugly screen... the long interactive list... measure startup,
scrolling and input."*

**Read the numbers first: [`RESULTS.md`](RESULTS.md).** Every figure
there traces to a raw event log in `bench/`, not a guess.

## What's here

```
dartnative/   The DartNative app (FastList + a native paging shim)
flutter/      The Flutter app (PageView + video_player)
bench/        Shared harness: identical data, the event parser, raw logs, screen recordings
RESULTS.md    The actual measurements, with caveats
```

Both apps run the same 13-item Pexels video list
(`bench/gen_items.py` generates `lib/feed_config.dart` identically for
both — verified byte-for-byte), the same pool window (1 behind + focused
+ 2 ahead), the same 3-live-controller cap, the same 250ms dispose grace,
the same `BoxFit.cover` crop. Any measured difference is the framework,
not the setup.

## The headline finding: DartNative has no `PageView`

Confirmed from DartNative's own docs, skill guide, and playground
source — `PageView` is listed **"Not planned"**, and the framework's own
carousel demo says outright *"there is no paging API."* `FastList`'s
controller is index-only; for a row exactly one viewport tall, there's
no way to build a finger-following pager on top of it from Dart.

The fix is 22 lines of Objective-C
(`dartnative/ios/Runner/DNPaging.m`) that flips
`UIScrollView.pagingEnabled` on the native list, looked up from Dart via
`DynamicLibrary.process()`. It works — see `RESULTS.md` §1 for the two
non-obvious things that broke it along the way (a safe-area inset, and a
`contentSize` ceiling past which paging silently stops snapping).

## Watch it

Same swipe script, same simulator session, both apps back to back.
DartNative's paging is locked to one page per swipe; `PageView` carries
further per swipe and lands on rows the pool never warmed, which is the
buffering spinner below.

4 flicks forward, 1 back — one-flick-one-page paging, autoplay tracking
the settled page in both apps.

| DartNative | Flutter |
|---|---|
| <video src="https://github.com/saileshbro/video-feed-showdown/raw/main/bench/repro/dartnative-scroll-autoplay.mp4" controls width="260"></video> | <video src="https://github.com/saileshbro/video-feed-showdown/raw/main/bench/repro/flutter-scroll-autoplay.mp4" controls width="260"></video> |

8 rapid swipes, 500ms apart, deliberately faster than the 2-ahead
preload window. DartNative never stalls; Flutter visibly buffers
mid-clip. This is the direct evidence behind "DartNative loads
noticeably faster" — same device, same session, same script. See
`RESULTS.md` §2/§3 for why (mostly caching, and the two apps not doing
the same amount of work) before reading that as a framework-level decode
difference.

| DartNative — no stall | Flutter — spinner mid-clip |
|---|---|
| <video src="https://github.com/saileshbro/video-feed-showdown/raw/main/bench/repro/dartnative-fast-scroll-loadtest.mp4" controls width="260"></video> | <video src="https://github.com/saileshbro/video-feed-showdown/raw/main/bench/repro/flutter-fast-scroll-loadtest.mp4" controls width="260"></video> |

## Run it

```sh
# DartNative
cd dartnative && dn pub get && dn run -d <device>

# Flutter
cd flutter && flutter pub get && flutter run -d <device>
```

Swipe vertically. The focused row shows `● PLAYING`; a position badge
(`#n`) and a `pexels · <id>` rail sit at the bottom.

## Reproduce the measurements

```sh
python3 bench/parse_bench.py bench/dn_device.log bench/dn_simulator.log \
  bench/fl_simulator.log bench/dn_loadtest.log bench/fl_loadtest.log
```

The raw recordings embedded above (and two more source files) live in
`bench/repro/`. See `bench/repro/README.md`.

## Caveats, stated plainly

- DartNative's video player has built-in byte-range pre-cache and a disk
  cache; `video_player` has neither. TTFF numbers reflect this ecosystem
  gap as well as any framework-level difference — see `RESULTS.md`.
- Flutter would not launch in profile mode on the physical test device
  after four attempts (hung at VM Service discovery, no crash). DartNative
  launched reliably. Reported as a finding, not swept under the rug.
- Memory and frame-drop measurements were not captured this pass.
