/// What sits on top of each video.
///
/// [BenchPage] is the first comparison's overlay, unchanged, for `UI=bench`.
/// [FeedPage] is the TikTok-style screen: the actions down the right edge are
/// iOS 26 Liquid Glass (`GlassEffectContainer`, the system material itself,
/// sampling the live video under it), and two of them reach past what
/// `dartnative_video_player` exposes: AirPlay and Picture in Picture.
library;

import 'dart:async';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative_share/dartnative_share.dart';
import 'package:dartnative_video_player/dartnative_video_player.dart';
import 'package:feed_native_media/feed_native_media.dart';

import 'feed_config.dart';
import 'feed_social.dart';

const _white = Color(0xFFFFFFFF);
const _dim = Color(0xB3FFFFFF);
const _like = Color(0xFFFE2C55);
const _save = Color(0xFFFACE15);

// Page widgets are rebuilt when they leave PageView's kept window, so
// per-clip state lives here rather than in the page.

// Startup bisection switches; all off in a normal build.
const bool _kNoGlass = bool.fromEnvironment('NO_GLASS');
const bool _kNoRail = bool.fromEnvironment('NO_RAIL');

/// A [GlassEffectContainer], or with `NO_GLASS` a plain translucent box of
/// the same shape, so a build can measure what the glass itself costs.
Widget _glass({
  required Widget child,
  required BorderRadius borderRadius,
  bool interactive = false,
  Color? tint,
}) => _kNoGlass
    ? Container(
        decoration: BoxDecoration(
          color: tint ?? const Color(0x33FFFFFF),
          borderRadius: borderRadius,
        ),
        child: child,
      )
    : GlassEffectContainer(
        // Pinned dark: glass takes its tone from the system theme, and a
        // light-mode phone would wash the rail out over a dark clip.
        brightness: Brightness.dark,
        interactive: interactive,
        tint: tint,
        borderRadius: borderRadius,
        child: child,
      );

/// Room for the floating Liquid Glass tab bar under the overlays.
const double kTabBarClearance = 62;
final Set<int> _liked = {};
final Set<int> _saved = {};

/// The first comparison's overlay, kept identical for the bench build.
class BenchPage extends StatelessWidget {
  const BenchPage({
    super.key,
    required this.controller,
    required this.item,
    required this.index,
    required this.isActive,
  });

  final VideoPlayerController? controller;
  final VideoItem item;
  final int index;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final ready = controller != null && controller!.isInitialized;
    return Stack(
      children: [
        if (ready) VideoPlayer(controller: controller!, fit: BoxFit.cover),
        if (!ready)
          Positioned.fill(child: Image.network(item.poster, fit: BoxFit.cover)),
        Positioned(
          top: 64,
          left: 16,
          child: _badge(Text('#$index', style: _bold(13))),
        ),
        Positioned(
          right: 16,
          bottom: 48,
          child: _badge(Text('${item.duration}s', style: _bold(12))),
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
                    color: isActive ? const Color(0xFF4ADE80) : _white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text('pexels · ${item.id}', style: _bold(13)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _badge(Widget child) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    color: const Color(0x99000000),
    child: child,
  );
}

TextStyle _bold(double size, [Color color = _white]) =>
    TextStyle(color: color, fontSize: size, fontWeight: FontWeight.w700);

/// One full-screen page of the TikTok-style feed.
class FeedPage extends StatefulWidget {
  const FeedPage({
    super.key,
    required this.controller,
    required this.item,
    required this.index,
    required this.isActive,
    required this.paused,
    required this.pipActive,
    required this.airPlayActive,
    required this.onTogglePause,
    required this.onTogglePip,
    required this.onOpenProfile,
    required this.onFollowChanged,
  });

  final VideoPlayerController? controller;
  final VideoItem item;
  final int index;
  final bool isActive;
  final bool paused;
  final bool pipActive;
  final bool airPlayActive;
  final VoidCallback onTogglePause;
  final VoidCallback onTogglePip;
  final VoidCallback onOpenProfile;
  final VoidCallback onFollowChanged;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  bool _heartBurst = false;
  Timer? _burstTimer;

  // Likes belong to the clip, not the page: a refresh reorders pages.
  int get _key => widget.item.id;

  @override
  void dispose() {
    _burstTimer?.cancel();
    super.dispose();
  }

  void _toggleLike() {
    HapticFeedback.lightImpact();
    setState(() => _liked.contains(_key) ? _liked.remove(_key) : _liked.add(_key));
  }

  // Double tap likes and never unlikes, like the real thing.
  void _doubleTapLike() {
    HapticFeedback.mediumImpact();
    _burstTimer?.cancel();
    setState(() {
      _liked.add(_key);
      _heartBurst = true;
    });
    _burstTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _heartBurst = false);
    });
  }

  void _toggleSave() {
    HapticFeedback.selectionClick();
    setState(() => _saved.contains(_key) ? _saved.remove(_key) : _saved.add(_key));
  }

  Future<void> _openComments(ClipSocial social) async {
    final item = widget.item;
    final count = social.comments + (postedComments[item.id]?.length ?? 0);
    // UISheetPresentationController: native detents, grabber, spring and
    // swipe-to-dismiss. The body is a Scaffold so the composer can sit in
    // bottomInputBar and ride the keyboard.
    await showModalSheet<void>(
      context: context,
      detent: SheetDetent.large,
      backgroundColor: const Color(0xFF161616),
      header: SheetHeader(title: '${compactCount(count)} comments'),
      builder: (context) => CommentsSheet(item: item),
    );
    if (mounted) setState(() {});
  }

  void _follow(String handle) {
    HapticFeedback.mediumImpact();
    setState(() => followed.add(handle));
    widget.onFollowChanged();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final social = socialFor(item);
    final insets = MediaQuery.paddingOf(context);
    final controller = widget.controller;
    final ready = controller != null && controller.isInitialized;
    final liked = _liked.contains(_key);
    final saved = _saved.contains(_key);

    return Stack(
      children: [
        // Fixed order: poster, player slot, gestures, then overlays. Filling
        // the player slot changes one child instead of moving the rest.
        Positioned.fill(child: Image.network(item.poster, fit: BoxFit.cover)),
        Positioned.fill(
          child: ready
              ? VideoPlayer(controller: controller, fit: BoxFit.cover)
              : const SizedBox.shrink(),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTogglePause,
            onDoubleTap: _doubleTapLike,
            child: const SizedBox.expand(),
          ),
        ),
        // Scrim so white text reads over a bright clip.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 280,
          child: IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0x99000000)],
                ),
              ),
            ),
          ),
        ),
        if (widget.isActive && widget.paused)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Icon(CupertinoIcons.play_fill, size: 72, color: Color(0x99FFFFFF)),
              ),
            ),
          ),
        if (widget.airPlayActive || widget.pipActive)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: _glass(
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    child: Text(
                      widget.airPlayActive
                          ? 'Playing on AirPlay'
                          : 'Playing in Picture in Picture',
                      style: _bold(15),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: AnimatedOpacity(
                opacity: _heartBurst ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: AnimatedScale(
                  scale: _heartBurst ? 1 : 0.4,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: const Icon(CupertinoIcons.heart_fill, size: 110, color: _like),
                ),
              ),
            ),
          ),
        ),
        if (!_kNoRail)
        Positioned(
          right: 4,
          width: kRailWidth,
          bottom: insets.bottom + kTabBarClearance + 22,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Avatar(
                poster: item.poster,
                following: followed.contains(social.handle),
                onTap: widget.onOpenProfile,
                onFollow: () => _follow(social.handle),
              ),
              const SizedBox(height: 18),
              _GlassAction(
                icon: CupertinoIcons.heart_fill,
                color: liked ? _like : _white,
                label: compactCount(social.likes + (liked ? 1 : 0)),
                onTap: _toggleLike,
              ),
              _GlassAction(
                icon: CupertinoIcons.chat_bubble_fill,
                label: compactCount(
                  social.comments + (postedComments[item.id]?.length ?? 0),
                ),
                onTap: () => _openComments(social),
              ),
              _GlassAction(
                icon: CupertinoIcons.bookmark_fill,
                color: saved ? _save : _white,
                label: compactCount(social.saves + (saved ? 1 : 0)),
                onTap: _toggleSave,
              ),
              _GlassAction(
                icon: CupertinoIcons.arrowshape_turn_up_right_fill,
                label: compactCount(social.shares),
                onTap: () => Share.share(item.url),
              ),
              if (FeedNativeMedia.isSupported) ...[
                // One shared system picker behind a plain glass button:
                // an AVRoutePickerView per page cost ~100ms each to create.
                const _GlassAction(
                  icon: CupertinoIcons.tv,
                  label: 'AirPlay',
                  onTap: _showAirPlay,
                ),
                _GlassAction(
                  icon: CupertinoIcons.rectangle_fill_on_rectangle_fill,
                  label: widget.pipActive ? 'Exit' : 'PiP',
                  onTap: widget.onTogglePip,
                ),
              ],
            ],
          ),
        ),
        Positioned(
          left: 16,
          right: 96,
          bottom: insets.bottom + kTabBarClearance + 24,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: widget.onOpenProfile,
                child: Text('@${social.handle}', style: _bold(16)),
              ),
              const SizedBox(height: 6),
              Text(
                '${social.caption} #pexels #${item.fps}fps',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _white, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.music_note_2, size: 14, color: _white),
                  const SizedBox(width: 6),
                  Text(
                    'original sound · ${social.handle}',
                    style: const TextStyle(color: _white, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Following | For You, fixed over the feed rather than part of each page.
///
/// Both labels have the same structure (text, gap, underline) and only the
/// underline's colour differs, so they share a baseline whichever is active.
class FeedTabs extends StatelessWidget {
  const FeedTabs({super.key, required this.forYou, required this.onSelect});

  final bool forYou;
  final ValueChanged<bool> onSelect;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _tab('Following', !forYou, () => onSelect(false)),
      const SizedBox(width: 24),
      _tab('For You', forYou, () => onSelect(true)),
    ],
  );

  Widget _tab(String label, bool active, VoidCallback onTap) => GestureDetector(
    onTap: () {
      if (!active) HapticFeedback.selectionClick();
      onTap();
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: _bold(17, active ? _white : _dim)),
          const SizedBox(height: 5),
          Container(
            width: 26,
            height: 2.5,
            color: active ? _white : const Color(0x00FFFFFF),
          ),
        ],
      ),
    ),
  );
}

/// The creator's picture in a Liquid Glass ring, with the plain Follow badge
/// under it. The badge disappears once the viewer follows.
class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.poster,
    required this.following,
    required this.onTap,
    required this.onFollow,
  });

  final String poster;
  final bool following;
  final VoidCallback onTap;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 52,
    height: 62,
    child: Stack(
      children: [
        _glass(
          interactive: true,
          borderRadius: BorderRadius.circular(26),
          child: GestureDetector(
            onTap: onTap,
            child: SizedBox(
              width: 52,
              height: 52,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: ClipOval(child: Image.network(poster, fit: BoxFit.cover)),
              ),
            ),
          ),
        ),
        if (!following)
          Positioned(
            left: 16,
            bottom: 0,
            child: GestureDetector(
              onTap: onFollow,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(color: _like, shape: BoxShape.circle),
                child: const Center(
                  child: Icon(CupertinoIcons.plus, size: 13, color: _white),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// A circular Liquid Glass button with its count underneath.
class _GlassAction extends StatelessWidget {
  const _GlassAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = _white,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => _GlassSlot(
    label: label,
    interactive: true,
    onTap: onTap,
    child: Icon(icon, size: 24, color: color),
  );
}

/// One rail button: a fixed 48pt glass circle and its label.
///
/// Every size here is fixed on purpose. Each widget is a UIView with a Yoga
/// node, and the rail is absolutely positioned; left content-sized, with a
/// SizedBox > Center pair nested inside another, Yoga re-measured the whole
/// column several times per pass, and seven of these buttons cost ~2.2s of
/// the first frame on an iPhone 16 Pro Max (measured with Time Profiler).
class _GlassSlot extends StatelessWidget {
  const _GlassSlot({
    required this.label,
    required this.child,
    this.interactive = false,
    this.onTap,
  });

  final String label;
  final Widget child;
  final bool interactive;
  final VoidCallback? onTap;

  static const double size = 48;

  @override
  Widget build(BuildContext context) {
    Widget circle = SizedBox(width: size, height: size, child: Center(child: child));
    if (onTap != null) {
      circle = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: circle,
      );
    }
    return SizedBox(
      width: kRailWidth,
      height: size + 4 + 16 + 12,
      child: Column(
        children: [
          _glass(
            interactive: interactive,
            borderRadius: BorderRadius.circular(size / 2),
            child: circle,
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 16,
            child: Text(label, textAlign: TextAlign.center, style: _bold(12)),
          ),
        ],
      ),
    );
  }
}

/// The rail's fixed width.
const double kRailWidth = 64;

void _showAirPlay() => FeedNativeMedia.showAirPlayPicker();

/// The bar above the tab bar: a native UIProgressView. There is one, over the
/// pager, following the active clip: a UIProgressView renders its track
/// images when created, ~80ms each, so one per page was a launch cost. While the clip is
/// still loading it has no value, which the framework draws as an
/// indeterminate bar sweeping end to end; once playing it tracks the position.
class PlaybackBar extends StatefulWidget {
  const PlaybackBar({super.key, required this.controller});

  final VideoPlayerController? controller;

  @override
  State<PlaybackBar> createState() => _PlaybackBarState();
}

class _PlaybackBarState extends State<PlaybackBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PlaybackBar old) {
    super.didUpdateWidget(old);
    _sync();
  }

  // Ticks only while there is a position to show; four times a second is
  // plenty for a 2pt bar.
  void _sync() {
    if (widget.controller == null) {
      _tick?.cancel();
      _tick = null;
    } else {
      _tick ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    double? value;
    if (c != null) {
      final d = c.durationMs;
      value = d <= 0 ? 0.0 : (c.positionMs / d).clamp(0.0, 1.0);
    }
    return LinearProgressIndicator(
      value: value,
      minHeight: 2,
      color: _white,
      backgroundColor: const Color(0x33FFFFFF),
    );
  }
}

/// The comments sheet. Everything in it is native: the sheet is
/// UISheetPresentationController, the list is a native scroll view, and the
/// composer is a UITextField in a Liquid Glass capsule, lifted by the
/// keyboard's own animation through `Scaffold.bottomInputBar`.
class CommentsSheet extends StatefulWidget {
  const CommentsSheet({super.key, required this.item});

  final VideoItem item;

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final TextEditingController _text = TextEditingController();

  static const _seed = [
    ('mira.k', 'the colours in this are unreal', '2h'),
    ('arjun_travels', 'where is this?? need to go', '3h'),
    ('slowtravel', 'saving this for later', '5h'),
    ('nepalinotes', 'watched it five times', '8h'),
    ('film.nerd', 'what lens is this', '1d'),
    ('kathmandu.frames', 'the light at 0:04', '2d'),
  ];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _post([String? submitted]) {
    final text = (submitted ?? _text.text).trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() {
      postedComments.putIfAbsent(widget.item.id, () => []).insert(0, text);
      _text.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mine = postedComments[widget.item.id] ?? const <String>[];
    return Scaffold(
      brightness: Brightness.dark,
      backgroundColor: const Color(0xFF161616),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          for (final text in mine) _comment('you', text, 'now'),
          for (final (user, text, age) in _seed) _comment(user, text, age),
        ],
      ),
      bottomInputBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: _glass(
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: TextField(
                    controller: _text,
                    decoration: const InputDecoration(
                      hintText: 'Add a comment…',
                      hintStyle: TextStyle(color: Color(0x80FFFFFF)),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.only(top: 10, bottom: 10),
                    ),
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _post,
                    style: const TextStyle(color: _white, fontSize: 16),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _glass(
              interactive: true,
              tint: _like,
              borderRadius: BorderRadius.circular(20),
              child: GestureDetector(
                onTap: _post,
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: Icon(CupertinoIcons.arrow_up, size: 20, color: _white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _comment(String user, String text, String age) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: const BoxDecoration(color: Color(0xFF2C2C2E), shape: BoxShape.circle),
          child: Center(
            child: Text(user[0].toUpperCase(), style: _bold(14, _dim)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$user · $age', style: const TextStyle(fontSize: 13, color: Color(0xFF8A8A8E))),
              const SizedBox(height: 3),
              Text(text, style: const TextStyle(fontSize: 15, color: _white)),
            ],
          ),
        ),
      ],
    ),
  );
}
