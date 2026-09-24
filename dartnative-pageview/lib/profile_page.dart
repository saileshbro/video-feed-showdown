/// The creator's profile, reached by swiping left on a video (or tapping the
/// avatar or handle), the way TikTok does it.
library;

import 'package:dartnative/dartnative.dart';
import 'package:dartnative_share/dartnative_share.dart';

import 'feed_config.dart';
import 'feed_social.dart';

const _white = Color(0xFFFFFFFF);
const _grey = Color(0xFF8A8A8E);
const _like = Color(0xFFFE2C55);

class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.handle,
    required this.onBack,
    required this.onFollowChanged,
    required this.onOpenClip,
  });

  final String handle;
  final VoidCallback onBack;
  final VoidCallback onFollowChanged;
  final ValueChanged<VideoItem> onOpenClip;

  @override
  Widget build(BuildContext context) {
    final clips = clipsBy(handle);
    final social = clips.isEmpty ? null : socialFor(clips.first);
    final likes = clips.fold<int>(0, (n, c) => n + socialFor(c).likes);
    final isFollowing = followed.contains(handle);
    final insets = MediaQuery.paddingOf(context);
    final width = MediaQuery.sizeOf(context).width;
    final tile = (width - 2) / 3;

    return Container(
      color: const Color(0xFF000000),
      child: SingleChildScrollView(
        child: Column(
          children: [
            SizedBox(height: insets.top),
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  GestureDetector(
                    onTap: onBack,
                    child: const SizedBox(
                      width: 52,
                      height: 44,
                      child: Center(
                        child: Icon(CupertinoIcons.chevron_left, size: 22, color: _white),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        displayName(handle),
                        style: const TextStyle(
                          color: _white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Share.share('https://www.pexels.com/@$handle'),
                    child: const SizedBox(
                      width: 52,
                      height: 44,
                      child: Center(
                        child: Icon(CupertinoIcons.ellipsis, size: 22, color: _white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // The picture sits in the same Liquid Glass ring as on the feed.
            GlassEffectContainer(
              brightness: Brightness.dark,
              borderRadius: BorderRadius.circular(50),
              child: SizedBox(
                width: 100,
                height: 100,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: ClipOval(
                    child: clips.isEmpty
                        ? const SizedBox.shrink()
                        : Image.network(clips.first.poster, fit: BoxFit.cover),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '@$handle',
              style: const TextStyle(color: _white, fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _stat(compactCount(38 + handle.length * 11), 'Following'),
                _divider(),
                _stat(compactCount((social?.likes ?? 0) * 3 + 900), 'Followers'),
                _divider(),
                _stat(compactCount(likes), 'Likes'),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    isFollowing ? followed.remove(handle) : followed.add(handle);
                    onFollowChanged();
                  },
                  child: Container(
                    width: 150,
                    height: 42,
                    decoration: BoxDecoration(
                      color: isFollowing ? const Color(0xFF2C2C2E) : _like,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        isFollowing ? 'Following' : 'Follow',
                        style: const TextStyle(
                          color: _white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GlassEffectContainer(
                  brightness: Brightness.dark,
                  interactive: true,
                  borderRadius: BorderRadius.circular(8),
                  child: GestureDetector(
                    onTap: () => Share.share('https://www.pexels.com/@$handle'),
                    child: const SizedBox(
                      width: 42,
                      height: 42,
                      child: Center(
                        child: Icon(CupertinoIcons.arrowshape_turn_up_right_fill,
                            size: 18, color: _white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                social?.caption ?? '',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _white, fontSize: 14),
              ),
            ),
            const SizedBox(height: 20),
            Container(height: 0.5, color: const Color(0xFF2C2C2E)),
            Wrap(
              spacing: 1,
              runSpacing: 1,
              children: [
                for (final clip in clips)
                  GestureDetector(
                    onTap: () => onOpenClip(clip),
                    child: SizedBox(
                      width: tile,
                      height: tile * 4 / 3,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Image.network(clip.poster, fit: BoxFit.cover),
                          ),
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(CupertinoIcons.play_fill, size: 12, color: _white),
                                const SizedBox(width: 4),
                                Text(
                                  compactCount(socialFor(clip).likes * 6),
                                  style: const TextStyle(
                                    color: _white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: insets.bottom + 90),
          ],
        ),
      ),
    );
  }

  Widget _stat(String value, String label) => SizedBox(
    width: 96,
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(color: _white, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: _grey, fontSize: 13)),
      ],
    ),
  );

  Widget _divider() => Container(width: 0.5, height: 14, color: const Color(0xFF3A3A3C));
}
