/// Made-up social data for the TikTok-style overlay: a handle, a caption and
/// counts per clip. Derived from the clip id, so a clip always reads the same
/// wherever it recurs in the feed. None of it is measured or sent anywhere.
library;

import 'feed_catalog.dart';
import 'feed_config.dart';

class ClipSocial {
  const ClipSocial({
    required this.handle,
    required this.caption,
    required this.likes,
    required this.comments,
    required this.saves,
    required this.shares,
  });

  final String handle;
  final String caption;
  final int likes;
  final int comments;
  final int saves;
  final int shares;
}

const _handles = [
  'kathmandu.frames', 'slowtravel', 'pexels.picks', 'tinyplanet',
  'goldenhour.club', 'streetsofnepal', 'drone.diaries', 'quiet.mornings',
];

const _captions = [
  'Nobody talks about how good this looks at 25fps',
  'Saved this for a rainy day. It is raining.',
  'Found this spot by accident and stayed two hours',
  'Sound on. Trust me.',
  'POV: you finally took the long way home',
  'Filmed on a Tuesday, posted on a Tuesday',
];

ClipSocial socialFor(VideoItem item) {
  final s = item.id;
  return ClipSocial(
    handle: _handles[s % _handles.length],
    caption: _captions[(s ~/ 7) % _captions.length],
    likes: 1200 + (s * 37) % 480000,
    comments: 40 + (s * 13) % 9000,
    saves: 90 + (s * 7) % 30000,
    shares: 15 + (s * 3) % 12000,
  );
}

/// 1.2K, 48.3K, 1.1M: the way the counts read on the real thing.
String compactCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final k = n / 1000;
    return '${k >= 100 ? k.round() : k.toStringAsFixed(1)}K';
  }
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// Creators the viewer follows. Two to start with, so the Following tab has
/// something in it before anyone taps Follow.
final Set<String> followed = {'slowtravel', 'drone.diaries'};

/// Comments the viewer posted, per clip id, newest first.
final Map<int, List<String>> postedComments = {};

/// Everything the full UI can show: the 17 bench clips first, then the
/// hard-coded Pexels catalog when it has been generated.
final List<VideoItem> allClips = [...demoItems, ...catalogItems];

/// The clips a creator posted, in feed order. Capped: a profile grid of
/// thousands of tiles is not what this screen is for.
List<VideoItem> clipsBy(String handle) => [
  for (final c in allClips) if (socialFor(c).handle == handle) c,
].take(18).toList();

/// The Following feed: clips from followed creators, in feed order.
List<VideoItem> followingClips() =>
    [for (final c in allClips) if (followed.contains(socialFor(c).handle)) c];

/// Display name for a handle: `drone.diaries` reads as `Drone Diaries`.
String displayName(String handle) => handle
    .split(RegExp(r'[._]'))
    .where((w) => w.isNotEmpty)
    .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');
