/// What the feed needs from iOS that `dartnative_video_player` 1.0.1 does not
/// expose: background playback, Picture in Picture, the lock-screen and
/// Control Center player, and an AirPlay route picker in the Dart layout.
///
/// iOS only. Every call is a no-op elsewhere, so the app runs unchanged on
/// Android; it just lacks these features there.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative/plugin.dart';
import 'package:ffi/ffi.dart';

/// Something the system asked the feed to do, or told it happened.
sealed class MediaEvent {
  const MediaEvent();
}

/// Next track: the lock screen, Control Center, or a headphone double-press.
class RemoteNext extends MediaEvent {
  const RemoteNext();
}

class RemotePrevious extends MediaEvent {
  const RemotePrevious();
}

class RemotePlay extends MediaEvent {
  const RemotePlay();
}

class RemotePause extends MediaEvent {
  const RemotePause();
}

/// The lock-screen scrubber moved.
class RemoteSeek extends MediaEvent {
  const RemoteSeek(this.position);
  final Duration position;
}

class PipChanged extends MediaEvent {
  const PipChanged({required this.active, this.error});
  final bool active;
  final String? error;
}

/// The user pulled the feed down to refresh.
class RefreshRequested extends MediaEvent {
  const RefreshRequested();
}

/// AirPlay started or stopped sending video to another screen.
class ExternalPlaybackChanged extends MediaEvent {
  const ExternalPlaybackChanged(this.active);
  final bool active;
}

/// Result of pointing the media session at a player.
enum AttachResult {
  attached,
  noView,

  /// The video plugin has not built its layer yet; try again next frame.
  notReady,
  noPlayer,
  unsupported,
}

enum PipState { unsupported, notReady, possible, active }

// Must match `Event` in FeedNativeMedia.swift.
abstract final class _Event {
  static const remoteNext = 1;
  static const remotePrevious = 2;
  static const remotePlay = 3;
  static const remotePause = 4;
  static const pipStarted = 5;
  static const pipStopped = 6;
  static const externalPlayback = 7;
  static const remoteSeek = 8;
  static const pipFailed = 9;
  static const refresh = 10;
}

typedef _DispatchC = Void Function(Int64, Int32, Pointer<Utf8>);

final StreamController<MediaEvent> _events = StreamController.broadcast();

// One static dispatcher for the whole plugin, per
// docs/plugin_async_callbacks.md. Native re-reads the slot before every call,
// so a hot restart drops events instead of calling a dead pointer.
void _dispatch(int token, int type, Pointer<Utf8> payload) {
  final p = payload.toDartString();
  final event = switch (type) {
    _Event.remoteNext => const RemoteNext(),
    _Event.remotePrevious => const RemotePrevious(),
    _Event.remotePlay => const RemotePlay(),
    _Event.remotePause => const RemotePause(),
    _Event.remoteSeek => RemoteSeek(Duration(milliseconds: int.tryParse(p) ?? 0)),
    _Event.pipStarted => const PipChanged(active: true),
    _Event.pipStopped => const PipChanged(active: false),
    _Event.pipFailed => PipChanged(active: false, error: p),
    _Event.externalPlayback => ExternalPlaybackChanged(p == '1'),
    _Event.refresh => const RefreshRequested(),
    _ => null,
  };
  if (event != null) _events.add(event);
}

abstract final class FeedNativeMedia {
  static bool _loaded = false;
  static late final int Function() _configure;
  static late final int Function(int, Pointer<Utf8>, Pointer<Utf8>, int) _attach;
  static late final void Function() _updateNowPlaying;
  static late final void Function(int) _setBackground;
  static late final int Function() _pipState;
  static late final int Function() _startPip;
  static late final void Function() _stopPip;
  static late final int Function() _externalActive;
  static late final int Function(int) _installRefresh;
  static late final void Function() _endRefresh;
  static late final int Function() _beginRefresh;
  static late final int Function() _showRoutePicker;

  /// Called by the generated plugin registrant.
  static void loadSymbols() {
    if (_loaded || !Platform.isIOS) return;
    final lib = DynamicLibrary.process();
    _configure = lib.lookupFunction<Int32 Function(), int Function()>('FNMConfigure');
    _attach = lib.lookupFunction<
        Int32 Function(Int64, Pointer<Utf8>, Pointer<Utf8>, Int64),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>, int)>('FNMAttach');
    _updateNowPlaying =
        lib.lookupFunction<Void Function(), void Function()>('FNMUpdateNowPlaying');
    _setBackground = lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'FNMSetBackgroundPlayback');
    _pipState = lib.lookupFunction<Int32 Function(), int Function()>('FNMPipState');
    _startPip = lib.lookupFunction<Int32 Function(), int Function()>('FNMStartPip');
    _stopPip = lib.lookupFunction<Void Function(), void Function()>('FNMStopPip');
    _externalActive =
        lib.lookupFunction<Int32 Function(), int Function()>('FNMIsExternalPlaybackActive');
    _installRefresh =
        lib.lookupFunction<Int32 Function(Uint32), int Function(int)>('FNMInstallRefresh');
    _endRefresh = lib.lookupFunction<Void Function(), void Function()>('FNMEndRefresh');
    _beginRefresh = lib.lookupFunction<Int32 Function(), int Function()>('FNMBeginRefresh');
    _showRoutePicker =
        lib.lookupFunction<Int32 Function(), int Function()>('FNMShowRoutePicker');
    lib.lookupFunction<Void Function(Int64), void Function(int)>('FNMSetDispatcher')(
        Pointer.fromFunction<_DispatchC>(_dispatch).address);
    lib.lookupFunction<Void Function(), void Function()>('FNMRegisterProvider')();
    DartNativeReconciler.registerElementFactory<_RoutePicker>(_RoutePickerElement.new);
    _loaded = true;
  }

  static bool get isSupported => _loaded;

  static Stream<MediaEvent> get events => _events.stream;

  /// Sets the audio session to playback (so audio survives the lock screen
  /// and PiP is allowed) and registers the lock-screen commands. Idempotent.
  static bool configure() => _loaded && _configure() == 1;

  /// Points PiP, AirPlay and the lock-screen player at the player drawing
  /// into [nativeViewPtr] (`VideoPlayerController.nativeViewPtr`).
  static AttachResult attach(
    int nativeViewPtr, {
    required String title,
    required String artist,
    Duration? duration,
  }) {
    if (!_loaded) return AttachResult.unsupported;
    final t = title.toNativeUtf8();
    final a = artist.toNativeUtf8();
    try {
      return switch (_attach(nativeViewPtr, t, a, duration?.inMilliseconds ?? 0)) {
        1 => AttachResult.attached,
        -1 => AttachResult.noView,
        -2 => AttachResult.notReady,
        _ => AttachResult.noPlayer,
      };
    } finally {
      calloc.free(t);
      calloc.free(a);
    }
  }

  /// Refresh the lock screen's elapsed time and play/pause state.
  static void updateNowPlaying() {
    if (_loaded) _updateNowPlaying();
  }

  /// Whether audio continues when the app leaves the foreground.
  static set backgroundPlayback(bool on) {
    if (_loaded) _setBackground(on ? 1 : 0);
  }

  static PipState get pipState {
    if (!_loaded) return PipState.unsupported;
    return switch (_pipState()) {
      -1 => PipState.unsupported,
      1 => PipState.possible,
      2 => PipState.active,
      _ => PipState.notReady,
    };
  }

  static bool startPictureInPicture() => _loaded && _startPip() == 1;

  static void stopPictureInPicture() {
    if (_loaded) _stopPip();
  }

  static bool get isExternalPlaybackActive => _loaded && _externalActive() == 1;

  /// Attaches a native UIRefreshControl to the visible vertical pager.
  /// `false` until the pager exists; call again after the next frame.
  static bool installPullToRefresh({Color tint = const Color(0xFFFFFFFF)}) =>
      _loaded && _installRefresh(tint.value) == 1;

  static void endRefresh() {
    if (_loaded) _endRefresh();
  }

  /// Opens the system AirPlay route list from any button, through one shared
  /// hidden `AVRoutePickerView` (see the Swift side for why not one per page).
  static bool showAirPlayPicker() => _loaded && _showRoutePicker() == 1;

  /// Shows the refresh spinner without a pull, for a Home re-tap.
  static bool beginRefresh() => _loaded && _beginRefresh() == 1;
}

/// The system AirPlay button (`AVRoutePickerView`): tapping it opens the
/// system's own route list. Draws nothing on other platforms.
class AirPlayButton extends StatelessWidget {
  const AirPlayButton({super.key, this.size = 28, this.color = const Color(0xFFFFFFFF)});

  final double size;
  final Color color;

  // The native leaf fills its slot, so the size lives on a box around it.
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: _RoutePicker(color: color));
}

class _RoutePicker extends StatelessWidget {
  const _RoutePicker({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      throw UnimplementedError('_RoutePicker is a native leaf widget');
}

final int _routePickerType =
    ViewType.claim('com.saileshbro.feed_native_media/route_picker');

class _RoutePickerElement extends NativeElement {
  _RoutePickerElement(_RoutePicker super.widget);

  _RoutePicker get _w => widget as _RoutePicker;

  @override
  int get viewType => _routePickerType;

  @override
  ViewProps buildProps() => const FlexProps(direction: 0, grow: 1);

  @override
  void mount(Element? parent, UIKitReconciler reconciler) {
    super.mount(parent, reconciler);
    _sendTint();
  }

  @override
  void update(Widget newWidget) {
    final old = _w;
    super.update(newWidget);
    if (old.color != _w.color) _sendTint();
  }

  void _sendTint() {
    final id = viewId;
    if (id == null) return;
    final bytes = ByteData(4)..setUint32(0, _w.color.value, Endian.little);
    emitMutation(PluginMutation(id, 1, bytes.buffer.asUint8List()));
  }
}
