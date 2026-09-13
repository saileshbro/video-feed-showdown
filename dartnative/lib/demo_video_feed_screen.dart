/// DartNative side of the comparison: [FastList] + pooled controllers.
///
/// Deliberately mirrors `video_feed_flutter/lib/feed_screen.dart` step for
/// step — same pool window, same 3-decoder cap, same 250 ms dispose grace,
/// same `BoxFit.cover` crop, same overlays, same [Bench] events.
///
/// The structural difference, which is the finding rather than a flaw: Flutter
/// gets paging from `PageView`; here it has to be built (see `page_snap.dart`).
library;

import 'dart:async';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative_video_player/dartnative_video_player.dart';

import 'bench.dart';
import 'feed_config.dart';
import 'paging.dart';

class DemoVideoFeedScreen extends StatefulWidget {
  const DemoVideoFeedScreen({super.key});

  @override
  State<DemoVideoFeedScreen> createState() => _DemoVideoFeedScreenState();
}

class _DemoVideoFeedScreenState extends State<DemoVideoFeedScreen> {
  final Map<int, VideoPlayerController> _controllers = {};
  final Map<int, StreamSubscription<VideoEvent>> _subs = {};
  final Set<int> _disposeScheduled = {};

  final FastListController _scrollController = FastListController();
  late final FeedPager _pager;
  final PagingMode _mode = pagingModeFromEnv();

  int _activeRow = 0;

  @override
  void initState() {
    super.initState();
    // Registered here rather than before runApp: at that point there is no
    // mounted tree yet, and the callback never fires.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Bench.event('first_frame');
      // The DNTableView only exists once a frame has been laid out, so the
      // paging call is armed here rather than in initState — where the poll
      // window can expire before the list is ever built.
      if (_mode == PagingMode.native) {
        NativePaging.applyWhenReady().then((code) {
          Bench.event('paging_native', {'code': code});
          if (kPagingDebug) NativePaging.dump();
        });
      }
    });
    VideoCache.configure(maxCacheSize: FeedTuning.maxDiskCacheBytes);
    _pager = FeedPager(
      mode: _mode,
      controller: _scrollController,
      itemCount: kFeedItemCount,
      onPageChanged: _onSettle,
    );
    _ensureWindow(_activeRow);
  }

  @override
  void dispose() {
    _pager.dispose();
    for (final s in _subs.values) {
      s.cancel();
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ pool

  VideoItem _itemFor(int index) => demoItems[index % demoItems.length];

  void _ensureWindow(int center) {
    final needed = <int>{
      center - 1,
      center,
      for (var k = 1; k <= FeedTuning.preloadAhead; k++) center + k,
    }.where((i) => i >= 0 && i < kFeedItemCount);

    for (final i in needed) {
      if (_controllers.containsKey(i) || _disposeScheduled.contains(i)) continue;
      if (_controllers.length >= FeedTuning.maxLiveControllers) break;
      _create(i);
    }

    // Byte-range prefetch for what's coming. `video_player` has no equivalent —
    // that asymmetry is an ecosystem finding, and the local-source run exists
    // so the pipeline can also be compared with caching out of the picture.
    if (!kUseLocal) {
      for (final i in needed) {
        if (i > center) {
          VideoCache.preCache(
            _itemFor(i).url,
            cacheKey: _itemFor(i).url,
            preCacheSize: FeedTuning.preCacheBytes,
          );
        }
      }
    }
  }

  void _create(int index) {
    final item = _itemFor(index);
    Bench.event('ctrl_create', {'i': index, 'src': kSource});

    final controller = VideoPlayerController(
      dataSource: kUseLocal
          ? VideoDataSource(
              VideoDataSourceType.asset,
              'assets/media/${item.file}',
              videoExtension: 'mp4',
            )
          : VideoDataSource.network(
              item.url,
              cacheConfig: VideoCacheConfig(
                useCache: true,
                preCacheSize: FeedTuning.preCacheBytes,
                maxCacheSize: FeedTuning.maxDiskCacheBytes,
                key: item.url,
              ),
              videoExtension: 'mp4',
            ),
      autoPlay: false,
      autoDispose: false,
    );
    controller.setHintAspectRatio(item.aspectRatio);
    controller.setFit(BoxFit.cover);
    _attachEvents(index, controller);
    _controllers[index] = controller;
    controller.initialize();
  }

  void _attachEvents(int index, VideoPlayerController controller) {
    _subs[index] = controller.events.listen((e) {
      if (!mounted) return;
      switch (e.type) {
        case VideoEventType.initialized:
          Bench.event('ctrl_ready', {'i': index});
          // `setLooping` is not cached pre-init; `setFit` is, but re-asserting
          // after init avoids a first-frame fit flash on Android.
          controller.setLooping(true);
          controller.setFit(BoxFit.cover);
          if (index == _activeRow) {
            Bench.event('play_call', {'i': index});
            controller.play();
          }
          setState(() {});
        case VideoEventType.error:
          Bench.event('ctrl_error', {'i': index, 'msg': e.errorMessage ?? '?'});
        default:
          break;
      }
    });
  }

  void _evictFar(int center) {
    final keep = <int>{
      center - 1,
      center,
      for (var k = 1; k <= FeedTuning.preloadAhead; k++) center + k,
    };
    for (final i in _controllers.keys.toList()) {
      if (keep.contains(i) || _disposeScheduled.contains(i)) continue;
      _disposeScheduled.add(i);
      _controllers[i]?.pause();
      Future.delayed(FeedTuning.disposeSettle, () {
        _disposeScheduled.remove(i);
        if (!mounted) return;
        if (_activeRow - 1 <= i && i <= _activeRow + FeedTuning.preloadAhead) {
          return;
        }
        _subs.remove(i)?.cancel();
        _controllers.remove(i)?.dispose();
        _ensureWindow(_activeRow);
        if (mounted) setState(() {});
      });
    }
  }

  // -------------------------------------------------------------- playback

  void _applyActive(int row) {
    for (final entry in _controllers.entries) {
      if (entry.key == row) {
        if (entry.value.isInitialized) {
          Bench.event('play_call', {'i': row});
          entry.value.play();
        }
      } else {
        entry.value.pause();
      }
    }
  }

  void _onSettle(int row) {
    if (row == _activeRow) return;
    _activeRow = row;
    Bench.event('page_settle', {'i': row});
    _ensureWindow(row);
    _applyActive(row);
    _evictFar(row);
    if (mounted) setState(() {});
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      brightness: Brightness.dark,
      backgroundColor: Colors.black,
      body: FastList(
        controller: _scrollController,
        itemCount: kFeedItemCount,
        scrollDirection: Axis.vertical,
        keepAliveCount: 2,
        stableItems: false,
        onScroll: _pager.onScroll,
        itemBuilder: (context, index) => FeedRow(
          controller: _controllers[index],
          item: _itemFor(index),
          index: index,
          isActive: index == _activeRow,
        ),
      ),
    );
  }
}

/// One full-screen row. Mirrors `FeedPage` in the Flutter app.
class FeedRow extends StatelessWidget {
  final VideoPlayerController? controller;
  final VideoItem item;
  final int index;
  final bool isActive;

  const FeedRow({
    super.key,
    required this.controller,
    required this.item,
    required this.index,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final ready = controller != null && controller!.isInitialized;
    return SizedBox(
      width: MediaQuery.sizeOf(context).width,
      height: MediaQuery.sizeOf(context).height,
      child: Stack(
        children: [
          if (ready)
            VideoPlayer(controller: controller!, fit: BoxFit.cover),

          if (!ready)
            Positioned.fill(
              child: Image.network(item.poster, fit: BoxFit.cover),
            ),

          Positioned(
            top: 64,
            left: 16,
            child: _badge(
              Text(
                '#$index',
                style: const TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 48,
            child: _badge(
              Text(
                '${item.duration}s',
                style: const TextStyle(
                  color: Color(0xFFFFFFFF),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 80,
            bottom: 48,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _badge(
                  Text(
                    isActive ? '● PLAYING' : '○ PAUSED',
                    style: TextStyle(
                      color: isActive
                          ? const Color(0xFF4ADE80)
                          : const Color(0xFFFFFFFF),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'pexels · ${item.id}',
                  style: const TextStyle(
                    color: Color(0xFFFFFFFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(Widget child) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    color: const Color(0x99000000),
    child: child,
  );
}
