/// Page-snapping for a [FastList] feed — the piece DartNative doesn't ship.
///
/// Flutter hands you `PageView`: one child per viewport, native deceleration,
/// `onPageChanged`. DartNative has no paging API at all. Its own playground
/// carousel says so in its header ("Built by hand instead of with a scroll
/// view: there is no paging API") and hand-rolls a decimal page position with a
/// velocity-aware settle — which works for five cards, but that demo builds
/// every item eagerly and so has nothing to say about an infinite feed.
///
/// On top of [FastList] the hand-rolled route isn't available either:
/// [FastListController] is index-only (`jumpToItem` / `scrollToItem` /
/// `animateToItem`) with no fractional `contentOffset`, and when a row is
/// exactly one viewport tall every `alignment` value resolves to the same
/// offset. So the list cannot be made to follow a finger from Dart.
///
/// That leaves two honest options, and this file implements both so they can be
/// compared:
///
///   [PagingMode.snap]   Pure Dart. Debounce [FastList.onScroll], then
///                       `animateToItem` to the nearest row. No native code —
///                       but the snap can only begin after the debounce window
///                       expires, it fights UIKit's own deceleration, and its
///                       fixed duration is unrelated to flick strength.
///
///   [PagingMode.native] Set `pagingEnabled` on the underlying UIScrollView
///                       (see `ios/Runner/DNPaging.m`). UIKit does the paging,
///                       so the feel is identical to `PageView` — the finger
///                       carries the page, one flick moves exactly one page,
///                       and deceleration is the platform's own.
library;

import 'dart:async';
import 'dart:ffi';

import 'package:dartnative/dartnative.dart';

/// How the feed snaps to whole pages.
enum PagingMode { snap, native }

/// Opt-in native view-tree logging. Off by default: the dump walks the view
/// hierarchy and writes to os_log, which is not something a measured run wants.
const bool kPagingDebug = bool.fromEnvironment('PAGING_DEBUG');

PagingMode pagingModeFromEnv() =>
    const String.fromEnvironment('PAGING', defaultValue: 'native') == 'snap'
    ? PagingMode.snap
    : PagingMode.native;

// ---------------------------------------------------------------- native

typedef _SetEnabledC = Int32 Function(Int32);
typedef _SetEnabledDart = int Function(int);

/// Binding to `dn_paging_set_enabled` in `ios/Runner/DNPaging.m`.
///
/// The symbol is compiled into the app binary rather than a plugin, so it is
/// looked up on the process itself.
class NativePaging {
  NativePaging._();

  static _SetEnabledDart? _setEnabled;
  static bool _looked = false;

  static _SetEnabledDart? _resolve() {
    if (_looked) return _setEnabled;
    _looked = true;
    try {
      _setEnabled = DynamicLibrary.process()
          .lookupFunction<_SetEnabledC, _SetEnabledDart>('dn_paging_set_enabled');
    } on ArgumentError {
      _setEnabled = null; // Not linked in (e.g. Android) — caller falls back.
    }
    return _setEnabled;
  }

  /// Diagnostic: ask native to NSLog every scroll view it can see.
  static void dump() {
    try {
      DynamicLibrary.process()
          .lookupFunction<Int32 Function(), int Function()>('dn_paging_dump')();
    } on ArgumentError {
      // Not linked — nothing to dump.
    }
  }

  /// Whether the native symbol is linked into this binary at all.
  static bool get isLinked => _resolve() != null;

  /// Raw result: 1 applied, -1 off main thread, -2 no window, -3 no scroll
  /// view yet, -99 symbol missing.
  static int applyRaw({bool enabled = true}) {
    final fn = _resolve();
    if (fn == null) return -99;
    return fn(enabled ? 1 : 0);
  }

  /// Returns true once the scroll view was found and paging applied.
  static bool apply({bool enabled = true}) => applyRaw(enabled: enabled) == 1;

  /// The native list isn't mounted on the first frame and there's no
  /// "list attached" callback, so retry briefly until it takes.
  static Future<int> applyWhenReady({
    Duration interval = const Duration(milliseconds: 50),
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var last = -99;
    while (DateTime.now().isBefore(deadline)) {
      last = applyRaw();
      if (last >= 1) return last;
      await Future<void>.delayed(interval);
    }
    return last;
  }
}

// ----------------------------------------------------------------- pager

/// Tracks which whole page the feed is resting on and reports changes.
///
/// Used by both modes. In [PagingMode.native] UIKit guarantees the feed comes
/// to rest exactly on a page boundary, so this is purely an observer. In
/// [PagingMode.snap] it also performs the snap.
class FeedPager {
  FeedPager({
    required this.mode,
    required this.controller,
    required this.itemCount,
    required this.onPageChanged,
    this.debounce = const Duration(milliseconds: 120),
    this.animation = const Duration(milliseconds: 280),
  });

  final PagingMode mode;
  final FastListController controller;
  final int itemCount;

  /// Fires when the feed comes to rest on a new page.
  final void Function(int page) onPageChanged;

  final Duration debounce;
  final Duration animation;

  Timer? _timer;
  double _offset = 0;
  double _viewport = 0;
  int _gestureStartPage = 0;
  bool _wasDragging = false;
  int _reportedPage = -1;

  /// Wire to [FastList.onScroll].
  void onScroll(double offset, double maxExtent, double viewport, bool dragging) {
    if (viewport <= 0) return;
    if (dragging && !_wasDragging) {
      _gestureStartPage = (offset / viewport).round();
    }
    _wasDragging = dragging;
    _offset = offset;
    _viewport = viewport;

    // Settle on quiescence, not on the `dragging` flag: when scroll callbacks
    // stop arriving the list has stopped moving. Gating on `dragging` loses the
    // settle whenever the flag doesn't clear after a fling — which is exactly
    // what leaves a flung-to page sitting there unplayed.
    _timer?.cancel();
    _timer = Timer(debounce, _settle);
  }

  void _settle() {
    if (_viewport <= 0) return;
    final nearest = (_offset / _viewport).round().clamp(0, itemCount - 1);

    if (mode == PagingMode.snap) {
      // One page per gesture, the way PageView behaves.
      final target = nearest
          .clamp(_gestureStartPage - 1, _gestureStartPage + 1)
          .clamp(0, itemCount - 1);
      if ((target * _viewport - _offset).abs() >= 1.0) {
        controller.animateToItem(
          target,
          alignment: 0.0,
          duration: animation,
          curve: Curves.easeOut,
        );
        return; // The animation emits more onScroll events; settle again then.
      }
      _report(target);
      return;
    }

    _report(nearest);
  }

  void _report(int page) {
    if (page == _reportedPage) return;
    _reportedPage = page;
    // Deferred off the native scroll callback. Calling back synchronously means
    // the resulting setState re-enters the native list from inside its own
    // scroll callback, which wedges the scroll view.
    Future.microtask(() => onPageChanged(page));
  }

  void dispose() => _timer?.cancel();
}
