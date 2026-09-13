# dartnative — infinite video feed

The DartNative half of the comparison in the [repo root](../README.md).
`FastList` + pooled `VideoPlayerController`s + a native
`UIScrollView.pagingEnabled` shim (`ios/Runner/DNPaging.m` — DartNative
ships no `PageView` equivalent; see the root README and
[`RESULTS.md`](../RESULTS.md) §1).

## Run it

```sh
dn pub get
dn run -d <device-id>
```

Requires a DartNative license — see
[dartpub.dev/framework](https://dartpub.dev/framework).

## File tour

```
lib/
  main.dart                    entry point — bindings first, dark edge-to-edge chrome
  feed_config.dart             GENERATED — do not hand-edit, see bench/gen_items.py
  bench.dart                   GENERATED — byte-identical to flutter/lib/bench.dart
  paging.dart                  dual-mode pager: snap (pure Dart) or native (the shim)
  demo_video_feed_screen.dart  FastList + pool + visible-range autoplay + eviction
ios/Runner/DNPaging.m          the pagingEnabled shim
```

`dn analyze`: no issues.
