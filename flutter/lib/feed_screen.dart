/// Flutter side of the comparison: `PageView` + pooled `VideoPlayerController`s.
///
/// Deliberately mirrors `video_feed/lib/demo_video_feed_screen.dart` step for
/// step — same pool window, same 3-decoder cap, same 250 ms dispose grace, same
/// `BoxFit.cover` crop, same overlays, same `Bench` events. Where the two files
/// differ, the difference is the framework, which is the whole point.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'bench.dart';
import 'feed_config.dart';

class VideoFeedScreen extends StatefulWidget {
  const VideoFeedScreen({super.key});

  @override
  State<VideoFeedScreen> createState() => _VideoFeedScreenState();
}

class _VideoFeedScreenState extends State<VideoFeedScreen> {
  final PageController _pageController = PageController();
  final Map<int, VideoPlayerController> _controllers = {};
  final Set<int> _disposeScheduled = {};
  int _activePage = 0;

  @override
  void initState() {
    super.initState();
    // Same placement as the DartNative app so both time the same instant.
    WidgetsBinding.instance.addPostFrameCallback((_) => Bench.event('first_frame'));
    _ensureWindow(0);
  }

  @override
  void dispose() {
    _pageController.dispose();
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
  }

  void _create(int index) {
    final item = _itemFor(index);
    Bench.event('ctrl_create', {'i': index, 'src': kSource});

    final controller = kUseLocal
        ? VideoPlayerController.asset('assets/media/${item.file}')
        : VideoPlayerController.networkUrl(Uri.parse(item.url));

    _controllers[index] = controller;
    controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          Bench.event('ctrl_ready', {'i': index});
          // Asserted post-init to mirror the DartNative side, where `setLooping`
          // is not cached before initialization.
          controller.setLooping(true);
          if (index == _activePage) {
            Bench.event('play_call', {'i': index});
            controller.play();
          }
          setState(() {});
        })
        .catchError((Object e) {
          if (mounted) Bench.event('ctrl_error', {'i': index, 'msg': '$e'});
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
        if (_activePage - 1 <= i && i <= _activePage + FeedTuning.preloadAhead) {
          return;
        }
        _controllers.remove(i)?.dispose();
        _ensureWindow(_activePage);
        if (mounted) setState(() {});
      });
    }
  }

  // -------------------------------------------------------------- playback

  void _applyActive(int page) {
    for (final entry in _controllers.entries) {
      if (entry.key == page) {
        if (entry.value.value.isInitialized) {
          Bench.event('play_call', {'i': page});
          entry.value.play();
        }
      } else {
        entry.value.pause();
      }
    }
  }

  void _onPageChanged(int page) {
    if (page == _activePage) return;
    _activePage = page;
    Bench.event('page_settle', {'i': page});
    _ensureWindow(page);
    _applyActive(page);
    _evictFar(page);
    setState(() {});
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        itemCount: kFeedItemCount,
        scrollDirection: Axis.vertical,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) => FeedPage(
          controller: _controllers[index],
          item: _itemFor(index),
          index: index,
          isActive: index == _activePage,
        ),
      ),
    );
  }
}

/// One full-screen page. Mirrors `FeedRow` in the DartNative app.
class FeedPage extends StatelessWidget {
  final VideoPlayerController? controller;
  final VideoItem item;
  final int index;
  final bool isActive;

  const FeedPage({
    super.key,
    required this.controller,
    required this.item,
    required this.index,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final ready = controller != null && controller!.value.isInitialized;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // BoxFit.cover equivalent: the DartNative player crops to fill via
          // `fit: BoxFit.cover`, so the Flutter side must crop identically or
          // the two are pushing different pixel counts through the GPU.
          if (ready)
            ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: controller!.value.size.width,
                  height: controller!.value.size.height,
                  child: VideoPlayer(controller!),
                ),
              ),
            ),

          if (!ready) Image.network(item.poster, fit: BoxFit.cover),

          if (ready && controller!.value.isBuffering)
            const Center(child: CircularProgressIndicator()),

          if (controller != null && controller!.value.hasError)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "Couldn't play #$index",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),

          Positioned(
            top: 64,
            left: 16,
            child: _Badge(
              child: Text(
                '#$index',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: 48,
            child: _Badge(
              child: Text(
                '${item.duration}s',
                style: const TextStyle(
                  color: Colors.white,
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
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Badge(
                  child: Text(
                    isActive ? '● PLAYING' : '○ PAUSED',
                    style: TextStyle(
                      color: isActive
                          ? const Color(0xFF4ADE80)
                          : Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'pexels · ${item.id}',
                  style: const TextStyle(
                    color: Colors.white,
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
}

class _Badge extends StatelessWidget {
  final Widget child;
  const _Badge({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    color: const Color(0x99000000),
    child: child,
  );
}
