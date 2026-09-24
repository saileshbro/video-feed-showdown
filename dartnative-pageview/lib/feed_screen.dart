/// The feed, rebuilt on DartNative's own `PageView` (September 2026 release).
///
/// The first version (`../dartnative/`) had no pager to use: it drove a
/// `FastList` and switched on `UIScrollView.pagingEnabled` through a 22-line
/// Objective-C shim, with a safe-area workaround. This one uses
/// `PageView.builder` and nothing else for paging.
///
/// Pooling and the bench events are the same as the other two apps: same
/// window (1 behind, the page, 2 ahead), same dispose grace, same `Bench`
/// vocabulary, and `page_settle` fires from `onPageChanged`, as it does in the
/// Flutter app. `TUNING=upstream` switches the pool to what DartNative's own
/// feed demo uses.
///
/// `UI=bench` renders the first comparison's plain overlays and touches no
/// native media API, so startup and TTFF compare like for like. `UI=full`
/// (default) is the TikTok-style screen with Liquid Glass actions,
/// background playback, PiP, the lock-screen player and AirPlay.
library;

import 'dart:async';
import 'dart:math';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative_video_player/dartnative_video_player.dart';
import 'package:feed_native_media/feed_native_media.dart';

import 'bench.dart';
import 'feed_config.dart';
import 'feed_overlay.dart';
import 'feed_social.dart';
import 'profile_page.dart';

const String kUi = String.fromEnvironment('UI', defaultValue: 'full');
const bool kFullUi = kUi != 'bench';

// Startup bisection switches; all off in a normal build.
const bool _kNoTabBar = bool.fromEnvironment('NO_TABBAR');
const bool _kNoProfile = bool.fromEnvironment('NO_PROFILE');
const bool _kNoOuter = bool.fromEnvironment('NO_OUTER');
const bool _kCountPages = bool.fromEnvironment('COUNT_PAGES');

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with WidgetsBindingObserver {
  final Map<int, VideoPlayerController> _controllers = {};
  final Map<int, StreamSubscription<VideoEvent>> _subs = {};
  final Set<int> _disposeScheduled = {};
  final PageController _pages = PageController();

  /// Feed ⇄ creator profile, side by side: swiping left on a video opens the
  /// profile, as on TikTok.
  final PageController _outer = PageController();
  int _outerPage = 0;

  /// The bottom tab bar's selected tab; 0 is Home.
  int _tab = 0;

  /// For You or Following, and the clips that feed loops over.
  bool _forYou = true;
  List<VideoItem> _items = kFullUi ? allClips : demoItems;
  bool _refreshing = false;

  /// The profile page is off-screen until a swipe, so it is built after the
  /// first frame instead of in it.
  bool _profileBuilt = false;
  StreamSubscription<MediaEvent>? _media;
  Timer? _nowPlayingTick;

  int _activeRow = 0;

  /// Pages the user paused by tapping; they stay paused when revisited.
  final Set<int> _userPaused = {};
  bool _pipActive = false;
  bool _airPlayActive = false;
  bool _inBackground = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Bench.event('first_frame');
      if (kFullUi && mounted) setState(() => _profileBuilt = true);
    });
    VideoCache.configure(maxCacheSize: FeedTuning.maxDiskCacheBytes);
    // Every launch opens on the same clip; everything after it is random.
    if (kFullUi) _newSequence(first: allClips.first);
    _ensureWindow(_activeRow);
    if (kFullUi) {
      _installRefresh();
      WidgetsBinding.instance.addObserver(this);
      _media = FeedNativeMedia.events.listen(_onMediaEvent);
      // The lock screen interpolates elapsed time from the rate; a slow
      // refresh keeps it honest across loops and seeks.
      _nowPlayingTick = Timer.periodic(
        const Duration(seconds: 2),
        (_) => FeedNativeMedia.updateNowPlaying(),
      );
    }
  }

  @override
  void dispose() {
    if (kFullUi) WidgetsBinding.instance.removeObserver(this);
    _media?.cancel();
    _nowPlayingTick?.cancel();
    for (final s in _subs.values) {
      s.cancel();
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inBackground = state == AppLifecycleState.paused;
  }

  // ------------------------------------------------------------------ pool

  /// What each page shows. The bench build loops the 17 clips in order, as
  /// the other two apps do. The full UI opens on the same clip every launch,
  /// then deals a random clip nobody has seen yet for each new page: `_bag`
  /// is the shuffled remainder, refilled once it runs out. Pages already
  /// dealt keep their clip, so swiping back shows what was there.
  final List<VideoItem> _sequence = [];
  List<VideoItem> _bag = [];
  final Random _rng = Random();

  VideoItem _itemFor(int index) {
    if (!kFullUi) return _items[index % _items.length];
    while (_sequence.length <= index) {
      if (_bag.isEmpty) _refillBag();
      _sequence.add(_bag.removeLast());
    }
    return _sequence[index];
  }

  void _refillBag() {
    final dealt = _sequence.map((c) => c.url).toSet();
    var fresh = [for (final c in _items) if (!dealt.contains(c.url)) c];
    // Everything has been shown: start over, but not with a clip just seen.
    if (fresh.isEmpty) {
      final recent = _sequence.reversed.take(3).map((c) => c.url).toSet();
      fresh = [for (final c in _items) if (!recent.contains(c.url)) c];
      if (fresh.isEmpty) fresh = List.of(_items);
    }
    _bag = fresh..shuffle(_rng);
  }

  /// Starts a new deal. [first] pins page 0; otherwise page 0 is random too.
  void _newSequence({VideoItem? first}) {
    _sequence
      ..clear()
      ..addAll([?first]);
    _bag = [];
  }

  /// Drops every player and starts the feed over from its first page with
  /// whatever `_items` now holds: a tab switch or a refresh. The pager and its
  /// native scroll view stay, so the refresh control on it does too.
  void _resetFeed() {
    final old = Map.of(_controllers);
    final oldSubs = Map.of(_subs);
    _controllers.clear();
    _subs.clear();
    _disposeScheduled.clear();
    _userPaused.clear();
    _activeRow = 0;
    for (final c in old.values) {
      c.pause();
    }
    if (_pages.hasClients) _pages.jumpToPage(0);
    setState(() {});
    // Dispose after the frame that unmounts their VideoPlayer views.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final s in oldSubs.values) {
        s.cancel();
      }
      for (final c in old.values) {
        c.dispose();
      }
      if (!mounted || _items.isEmpty) return;
      _ensureWindow(0);
      setState(() {});
      _installRefresh();
    });
  }

  int _refreshTries = 0;

  void _installRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ok = FeedNativeMedia.installPullToRefresh();
      if (!ok && _refreshTries++ < 20) {
        Future.delayed(const Duration(milliseconds: 100), _installRefresh);
      } else {
        _refreshTries = 0;
      }
    });
  }

  void _selectFeed(bool forYou) {
    if (forYou == _forYou) return;
    _forYou = forYou;
    _items = forYou ? allClips : followingClips();
    _newSequence();
    Bench.event('feed_switch', {'forYou': forYou});
    _resetFeed();
  }

  /// Pull to refresh, or a Home re-tap. There is no server, so "new content"
  /// is a fresh random deal of clips not yet shown.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    Bench.event('refresh');
    _items = _forYou ? allClips : followingClips();
    // A refresh is a new deal from page 0, so the top of the feed changes.
    _newSequence();
    _resetFeed();
    // Long enough for the spinner to register, short enough not to stall.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    FeedNativeMedia.endRefresh();
    _refreshing = false;
  }

  void _onFollowChanged() {
    setState(() {});
    // The Following feed follows the follow list, from the top.
    if (!_forYou) {
      _items = followingClips();
      _newSequence();
      _resetFeed();
    }
  }

  void _onTab(int tab) {
    HapticFeedback.selectionClick();
    if (tab == 0 && _tab == 0) {
      _homeAgain();
      return;
    }
    setState(() => _tab = tab);
    _applyVisibility();
  }

  /// Home tapped while on Home: back to the top of the feed and refresh.
  void _homeAgain() {
    if (_outerPage != 0) _outer.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    FeedNativeMedia.beginRefresh();
    _refresh();
  }

  /// Plays the active clip only when the feed is what's on screen.
  void _applyVisibility() {
    final c = _controllers[_activeRow];
    if (c == null || !c.isInitialized) return;
    final visible = _tab == 0 && _outerPage == 0;
    if (visible && !_userPaused.contains(_activeRow)) {
      c.play();
    } else {
      c.pause();
    }
  }

  void _openClip(VideoItem clip) {
    // From a profile grid: the clip becomes the next page, and everything
    // dealt after it is dealt again.
    final next = _activeRow + 1;
    if (kFullUi) {
      _sequence
        ..removeRange(next, _sequence.length)
        ..add(clip);
      _bag.remove(clip);
      // Players already built for the old pages go, after the frame that
      // unmounts their views.
      final stale = <VideoPlayerController>[];
      for (final i in _controllers.keys.where((i) => i >= next).toList()) {
        _subs.remove(i)?.cancel();
        stale.add(_controllers.remove(i)!..pause());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final c in stale) {
          c.dispose();
        }
      });
    }
    _outer.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    _pages.jumpToPage(next);
    _onPageChanged(next);
  }


  void _ensureWindow(int center) {
    // With the pool one short of the window, the fill order decides which
    // page goes without a player. Parity keeps the other apps' order (behind
    // first); upstream fills the page under the finger, then the next.
    final needed = <int>{
      if (FeedTuning.upstream) ...[center, center + 1, center - 1]
      else ...[center - 1, center, center + 1],
      for (var k = 2; k <= FeedTuning.preloadAhead; k++) center + k,
    }.where((i) => i >= 0 && (kFeedItemCount == 0 || i < kFeedItemCount));

    for (final i in needed) {
      if (_controllers.containsKey(i) || _disposeScheduled.contains(i)) continue;
      if (_controllers.length >= FeedTuning.maxLiveControllers) break;
      _create(i);
    }

    if (!kUseLocal) {
      final last = center + FeedTuning.preloadAhead + FeedTuning.preCacheBeyond;
      for (var i = center + 1; i <= last; i++) {
        final url = _itemFor(i).url;
        VideoCache.preCache(url, cacheKey: url, preCacheSize: FeedTuning.preCacheBytes);
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
              bufferingConfig: FeedTuning.upstream
                  ? VideoBufferingConfig.feed
                  : const VideoBufferingConfig(),
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
          controller.setLooping(true);
          controller.setFit(BoxFit.cover);
          if (index == _activeRow &&
              !_userPaused.contains(index) &&
              _tab == 0 &&
              _outerPage == 0) {
            Bench.event('play_call', {'i': index});
            controller.play();
          }
          setState(() {});
          if (index == _activeRow) _attachMedia();
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
        if (_activeRow - 1 <= i && i <= _activeRow + FeedTuning.preloadAhead) return;
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
        if (entry.value.isInitialized && !_userPaused.contains(row)) {
          Bench.event('play_call', {'i': row});
          entry.value.play();
        }
      } else {
        entry.value.pause();
      }
    }
  }

  /// Fires as a swipe crosses the midpoint between two pages, as in Flutter.
  void _onPageChanged(int row) {
    if (row == _activeRow) return;
    _activeRow = row;
    Bench.event('page_settle', {'i': row});
    _ensureWindow(row);
    _applyActive(row);
    _evictFar(row);
    if (mounted) setState(() {});
    _attachMedia();
  }

  void _togglePause() {
    final c = _controllers[_activeRow];
    if (c == null || !c.isInitialized) return;
    setState(() {
      if (c.isPlaying) {
        c.pause();
        _userPaused.add(_activeRow);
      } else {
        c.play();
        _userPaused.remove(_activeRow);
      }
    });
    FeedNativeMedia.updateNowPlaying();
  }

  // ---------------------------------------------------------- native media

  int _attachTries = 0;

  /// Points PiP, AirPlay and the lock-screen player at the active page's
  /// player. The video plugin builds its AVPlayerLayer lazily, so a first
  /// attempt can find nothing; it retries on the next few frames.
  void _attachMedia() {
    if (!kFullUi) return;
    final row = _activeRow;
    final c = _controllers[row];
    if (c == null || !c.isInitialized) return;
    final item = _itemFor(row);
    final result = FeedNativeMedia.attach(
      c.nativeViewPtr,
      title: 'Pexels ${item.id}',
      artist: 'Video #$row',
      duration: c.duration,
    );
    Bench.event('media_attach', {'i': row, 'result': result.name});
    if (result == AttachResult.notReady && _attachTries++ < 10) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _activeRow == row) _attachMedia();
      });
    } else {
      _attachTries = 0;
    }
  }

  void _goTo(int row) {
    if (row < 0) return;
    // In the background there is no display link to animate with, so jump.
    if (_inBackground) {
      _pages.jumpToPage(row);
    } else {
      _pages.animateToPage(
        row,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    }
    // Keeps the pool right even if the jump does not report a page change.
    _onPageChanged(row);
  }

  void _onMediaEvent(MediaEvent e) {
    Bench.event('media_event', {'type': e.runtimeType.toString()});
    final c = _controllers[_activeRow];
    switch (e) {
      case RefreshRequested():
        _refresh();
      case RemoteNext():
        _goTo(_activeRow + 1);
      case RemotePrevious():
        _goTo(_activeRow - 1);
      case RemotePlay():
        _userPaused.remove(_activeRow);
        c?.play();
      case RemotePause():
        _userPaused.add(_activeRow);
        c?.pause();
      case RemoteSeek(:final position):
        c?.seekTo(position);
      case PipChanged(:final active):
        setState(() => _pipActive = active);
      case ExternalPlaybackChanged(:final active):
        setState(() => _airPlayActive = active);
    }
    FeedNativeMedia.updateNowPlaying();
  }

  VideoPlayerController? _readyController(int row) {
    final c = _controllers[row];
    return c != null && c.isInitialized ? c : null;
  }

  void _togglePip() {
    if (_pipActive) {
      FeedNativeMedia.stopPictureInPicture();
    } else if (!FeedNativeMedia.startPictureInPicture()) {
      _attachMedia();
    }
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (!kFullUi) {
      return Scaffold(
        brightness: Brightness.dark,
        backgroundColor: Colors.black,
        body: PageView.builder(
          controller: _pages,
          scrollDirection: Axis.vertical,
          itemCount: kFeedItemCount == 0 ? null : kFeedItemCount,
          allowImplicitScrolling: true,
          onPageChanged: _onPageChanged,
          itemBuilder: (context, index) => BenchPage(
            controller: _controllers[index],
            item: _itemFor(index),
            index: index,
            isActive: index == _activeRow,
          ),
        ),
      );
    }

    return Scaffold(
      brightness: Brightness.dark,
      backgroundColor: Colors.black,
      extendBody: true,
      body: IndexedStack(
        index: _tab,
        children: [
          _home(context),
          const _Placeholder(icon: CupertinoIcons.person_2, text: 'Find friends to see their videos here'),
          const _Placeholder(icon: CupertinoIcons.plus_app, text: 'Creating is not part of this demo'),
          const _Placeholder(icon: CupertinoIcons.tray, text: 'No new activity'),
          const _Placeholder(icon: CupertinoIcons.person, text: 'Your profile'),
        ],
      ),
      bottomNavigationBar: _kNoTabBar ? null : BottomNavigationBar(
        currentIndex: _tab,
        onTap: _onTab,
        selectedIconColor: const Color(0xFFFFFFFF),
        iconColor: const Color(0x99FFFFFF),
        items: const [
          BottomNavigationBarItem(
            label: 'Home',
            icon: Icon(CupertinoIcons.house),
            activeIcon: Icon(CupertinoIcons.house_fill),
          ),
          BottomNavigationBarItem(
            label: 'Friends',
            icon: Icon(CupertinoIcons.person_2),
            activeIcon: Icon(CupertinoIcons.person_2_fill),
          ),
          BottomNavigationBarItem(
            label: 'Create',
            icon: Icon(CupertinoIcons.plus_app),
            activeIcon: Icon(CupertinoIcons.plus_app_fill),
          ),
          BottomNavigationBarItem(
            label: 'Inbox',
            icon: Icon(CupertinoIcons.tray),
            activeIcon: Icon(CupertinoIcons.tray_fill),
          ),
          BottomNavigationBarItem(
            label: 'Profile',
            icon: Icon(CupertinoIcons.person),
            activeIcon: Icon(CupertinoIcons.person_fill),
          ),
        ],
      ),
    );
  }

  Widget _home(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    final pages = _homePages(insets);
    if (_kNoOuter) return pages.first;
    return PageView(
      controller: _outer,
      scrollDirection: Axis.horizontal,
      allowImplicitScrolling: true,
      onPageChanged: (page) {
        _outerPage = page;
        Bench.event('outer_page', {'page': page});
        setState(() {});
        _applyVisibility();
      },
      children: pages,
    );
  }

  List<Widget> _homePages(EdgeInsets insets) => [
        Stack(
          children: [
            if (_items.isEmpty)
              const _Placeholder(
                icon: CupertinoIcons.person_2,
                text: 'Follow creators and their videos show up here',
              )
            else
              PageView.builder(
                controller: _pages,
                scrollDirection: Axis.vertical,
                itemCount: kFeedItemCount == 0 ? null : kFeedItemCount,
                // Off: every page here is ~70 native views (UIView + Yoga
                // node each), and two extra pages each side made the first
                // frame lay out hundreds of them. The visible page and its
                // neighbour are enough for a swipe to reveal a built page.
                allowImplicitScrolling: false,
                onPageChanged: _onPageChanged,
                itemBuilder: (context, index) {
                  if (_kCountPages) Bench.event('page_build', {'i': index});
                  final isActive = index == _activeRow;
                  return FeedPage(
                    controller: _controllers[index],
                    item: _itemFor(index),
                    index: index,
                    isActive: isActive,
                    paused: _userPaused.contains(index),
                    pipActive: isActive && _pipActive,
                    airPlayActive: isActive && _airPlayActive,
                    onTogglePause: _togglePause,
                    onTogglePip: _togglePip,
                    onOpenProfile: () => _outer.animateToPage(
                      1,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                    ),
                    onFollowChanged: _onFollowChanged,
                  );
                },
              ),
            Positioned(
              top: insets.top + 4,
              left: 0,
              right: 0,
              child: FeedTabs(forYou: _forYou, onSelect: _selectFeed),
            ),
            if (_items.isNotEmpty)
              Positioned(
                left: 12,
                right: 12,
                bottom: insets.bottom + kTabBarClearance + 6,
                child: PlaybackBar(controller: _readyController(_activeRow)),
              ),
            if (_items.isNotEmpty)
              Positioned(
                top: insets.top + 8,
                right: 12,
                child: GlassEffectContainer(
                  brightness: Brightness.dark,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Text(
                      'Video #$_activeRow',
                      style: const TextStyle(
                        color: Color(0xFFFFFFFF),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (_items.isNotEmpty && !_kNoProfile && _profileBuilt)
          ProfilePage(
            handle: socialFor(_itemFor(_activeRow)).handle,
            onBack: () => _outer.animateToPage(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            ),
            onFollowChanged: _onFollowChanged,
            onOpenClip: _openClip,
          ),
  ];
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.black,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: const Color(0x66FFFFFF)),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 15)),
        ],
      ),
    ),
  );
}
