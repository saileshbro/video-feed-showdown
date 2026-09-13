# flutter — infinite video feed

The Flutter half of the comparison in the [repo root](../README.md).
`PageView` + pooled `VideoPlayerController`s (`video_player` package),
built to mirror the DartNative app step for step — same pool window,
same 3-controller cap, same dispose grace, same crop — so a measured
difference is the framework, not the app.

## Run it

```sh
flutter pub get
flutter run -d <device-id>
```

## File tour

```
lib/
  main.dart          entry point
  feed_config.dart   GENERATED — do not hand-edit, see bench/gen_items.py
  bench.dart         GENERATED — byte-identical to dartnative/lib/bench.dart
  feed_screen.dart    PageView + pool + onPageChanged + eviction
```

`flutter analyze`: no issues.
