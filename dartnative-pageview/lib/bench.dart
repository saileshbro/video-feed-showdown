/// Benchmark instrumentation — byte-identical in the DartNative and Flutter apps.
///
/// Every line is printed as `##BENCH## {json}` so `bench/parse_bench.dart` can
/// scrape it from the device console without depending on either framework's
/// own tracing. Timestamps are wall-clock microseconds from the same source
/// (`DateTime.now()`), so the two apps' numbers are directly comparable.
///
/// Event vocabulary (both apps emit exactly these, at exactly these points):
///
///   main_enter    first executable line of main()
///   first_frame   first frame rasterized (post-frame callback of first build)
///   ctrl_create   a VideoPlayerController is constructed          {i, src}
///   ctrl_ready    that controller reports it can render frame 1   {i}
///   play_call     play() invoked on the focused row               {i}
///   page_settle   the feed has come to rest on a row              {i}
///
/// TTFF is therefore `ctrl_ready - ctrl_create` for the same `i` — a definition
/// that means the same thing on both stacks (player constructed → first frame
/// available), which is the only way the comparison is honest.
library;

class Bench {
  Bench._();

  /// Set from `--dart-define=BENCH_TAG=...` so a run's lines can be attributed
  /// to a configuration (framework × source × mode) during parsing.
  static const tag = String.fromEnvironment('BENCH_TAG', defaultValue: 'untagged');

  static const bool _enabled = bool.fromEnvironment('BENCH', defaultValue: true);

  static void event(String ev, [Map<String, Object?> fields = const {}]) {
    if (!_enabled) return;
    final b = StringBuffer('##BENCH## {"tag":"')
      ..write(tag)
      ..write('","t_us":')
      ..write(DateTime.now().microsecondsSinceEpoch)
      ..write(',"ev":"')
      ..write(ev)
      ..write('"');
    fields.forEach((k, v) {
      b.write(',"');
      b.write(k);
      b.write('":');
      if (v is num) {
        b.write(v);
      } else if (v is bool) {
        b.write(v);
      } else {
        b.write('"');
        b.write(v.toString().replaceAll('"', r'\"'));
        b.write('"');
      }
    });
    b.write('}');
    // ignore: avoid_print
    print(b.toString());
  }
}
