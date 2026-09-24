# September revisit: results

Everything here comes from files in this directory. Re-derive any startup
number with the parser at the bottom. Nothing below is estimated.

## Setup

- **Device**: iPhone 16 Pro Max, iOS 27.0, cabled. The September run was on
  iOS 26.6.1, so September's numbers are context, not a baseline.
- **SDK**: DartNative SDK `2f59a91bf44` (framework edition `db1e0369`), the
  release that shipped `PageView` on 2026-09-17. `dartnative_video_player`
  1.0.1.
- **Builds**: `dn build ios --profile`, installed with `devicectl`, launched
  without a debugger (`devicectl device process launch`). `##BENCH##` lines are
  read from the device syslog (`idevicesyslog -m "##BENCH##"`).
- **Startup** = `main_enter` → `first_frame` (post-frame callback of the first
  build). **First clip ready** = `main_enter` → first `ctrl_ready`.

## Startup on the phone

| Build | Startup (ms) | First clip ready (ms) | Logs |
|---|---|---|---|
| `dartnative-pageview`, `UI=bench` (the September overlays on `PageView`) | 608, 477, 490 | 801, 608, 634 | `logs/dnpv_bench_{1,2,3}.log` |
| `dartnative-pageview`, full TikTok-style UI | 3452, 2990, 2724 | 4802, 4180, 3759 | `logs/su_dnpv_full_{1,2,3}.log` |
| Same full UI, right-hand action rail removed (`NO_RAIL`) | 806, 886, 844 | 1091, 1370, 1335 | `logs/su_norail_{1,2,3}.log` |

September, for context only: 863ms startup on iOS 26.6.1 (`../dn_device.log`).

The full-UI and `NO_RAIL` rows are the same build apart from the rail: one
page built each side off, profile page built after the first frame, one
shared AirPlay picker, one playback bar.

## PageView.builder builds every page

`logs/countpages.log`: the full UI with a `page_build` event in
`PageView.builder`'s `itemBuilder` (`COUNT_PAGES=true`), `itemCount: 1000`,
`allowImplicitScrolling: false`, one launch.

- `itemBuilder` calls before the first frame: **1000**, indices 0 to 999.
- Calls in the first 12 seconds: **3000** (1000 distinct). Each `setState` on
  the screen (a clip reporting ready) rebuilt all 1000 pages.
- Startup in this run: 3034ms.

DartNative's `PageView` docs say a page outside the kept window "releases what
it built and rebuilds when it comes back". On this build it built all of them.
The bench build (`UI=bench`) was not instrumented, so whether it also builds
1000 pages is not measured; its pages are about 8 views each against about 70
for the full UI.

## Update, 2026-09-24: 30 pages instead of 1,000

After the post, the DartNative team suggested a feed only needs about 30
pages loaded. Same code, same phone, same session, only `FEED_COUNT`
changed. This build has the fixed-size rail (`kRailWidth`) that the rows
above did not, so compare the two rows below with each other, not with the
table above.

| `itemCount` | Startup (ms) | First clip ready (ms) | `itemBuilder` calls before first frame | Calls in 12s | Logs |
|---|---|---|---|---|---|
| 30 | 342, 353, 356 | 613, 536, 592 | 30 | 150, 150, 120 | `logs/feed30_{1,2,3}.log` |
| 1000 | 2341, 2221, 2263 | 2850, 2693, 2763 | 1000 | 3000 each | `logs/feed1000_{1,2,3}.log` |

`PageView.builder` still built every page it was given before the first
frame and rebuilt all of them on each `setState`; with 30 pages that is
cheap. A 30-page feed also ends at page 30. How a feed that grows its
`itemCount` as the reader nears the end behaves was not tested.

## Why the full UI is slow: Time Profiler

`traces/launch_full.trace` and `traces/l2.trace` (exported tables:
`traces/*.time-profile.xml`). Main-thread samples, 1ms each.

`launch_full.trace` (before the picker and progress-bar changes): the main
thread is busy from about 1.0s to 6.0s after launch. Under
`DNApplyMutationBatch` (the native side applying the first frame's view
mutations):

- `DNUIViewCreate`: 1268 samples
- `AVRoutePickerView` creation (one per built page; each parses a CAML package
  for its icon): ~516 samples
- `UIProgressView` creation and track-image rendering (one per built page):
  ~300 + 125 samples
- `DNGlassEffectView.init`: 183 samples

`l2.trace` (one shared picker, one playback bar): busy about 1.0s to 4.5s.
2825 samples are inside native calls from Dart, 103 in Dart widget mounting.
Of 1526 samples inside the Core Animation commit, 966 are
`-[YGLayout calculateLayoutWithSize:]`, most of them in
`layoutAbsoluteDescendants` / `layoutAbsoluteChild` (Yoga laying out
absolutely positioned subtrees).

Bisection with the pre-fix build (`logs/bisect_results.txt`, two launches
each, `runApp` → `first_frame`): removing the tab bar, the profile page, the
horizontal pager, or both of the latter did not bring startup under 2.9s.
Removing the rail did (table above).

Not done: a build with the fixed-size rail (`kRailWidth`, flattened
`_GlassSlot`) was written but never built or measured.

## Sizes (profile `Runner.app`, not App Store sizes)

| Build | Size |
|---|---|
| `dartnative-pageview`, `UI=bench` | 17.1MB |
| `dartnative-pageview`, full UI, 17 clips | 17.3MB |
| `dartnative-pageview`, full UI, 10,000-clip catalog | 20.6MB |
| September `dartnative/` app rebuilt on the new SDK (Skia `full`) | 26.4MB |
| `flutter/`, Flutter 3.41.5 | 22.2MB |

## Not measured

- Flutter on the phone: built (after raising its iOS target to 15.0), never
  launched or timed.
- Any swipe, TTFF-per-row or rapid-swipe load test on any app.
- Memory, leaks, dropped frames.
- Timings for the native features. Whether they work was checked by hand on
  the phone (2026-09-24): AirPlay, Picture in Picture (button and swipe
  home), audio with the screen locked, lock-screen and Control Center
  controls including next and previous, pull to refresh, the Home re-tap,
  the comments sheet, the share sheet, swipe left for the profile and the
  loading bar all worked. That is a manual check, with no log behind it.

## Known bugs seen while taking screenshots

- The comments sheet title ("4.9K comments") is dark text on the dark sheet:
  the native title follows the phone's light theme, not the sheet colour.
- On a profile, the avatar and some grid tiles never render their poster,
  although the same URLs return 200 `image/jpeg`. Not investigated.

## Invalid, and removed

A second bisection round (`NO_GLASS`, `NO_AIRPLAY`, `NO_PROGRESS`) ran with a
bug of mine: the `_glass` helper called itself, so those builds were busy
throwing stack-overflow errors. Its logs are not kept.

## Parser

```sh
python3 - bench/v2/logs/dnpv_bench_1.log <<'EOF'
import json, re, sys
ev = {}
for line in open(sys.argv[1]):
    m = re.search(r'##BENCH## (\{.*\})', line)
    if m:
        d = json.loads(m.group(1)); ev.setdefault(d['ev'], d['t_us'])
print((ev['first_frame'] - ev['main_enter']) / 1000, 'ms')
EOF
```
