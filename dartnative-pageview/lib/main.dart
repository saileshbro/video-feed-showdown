import 'package:dartnative/dartnative.dart';
import 'package:feed_native_media/feed_native_media.dart';

import 'bench.dart';
import 'dartnative_plugin_registrant.dart';
import 'feed_screen.dart';

void main() {
  Bench.event('main_enter');
  DartNativePluginRegistrant.registerAll();
  SystemChrome.defaultStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  );
  // The bench build stays byte-for-byte what the first comparison measured:
  // no audio session, no lock-screen player, no glass.
  if (kFullUi) {
    Bench.event('media_configure_start');
    FeedNativeMedia.configure();
    Bench.event('media_configure_end');
  }
  Bench.event('run_app');
  runApp(const VideoFeedApp());
}

class VideoFeedApp extends StatelessWidget {
  const VideoFeedApp({super.key});

  @override
  Widget build(BuildContext context) => const FeedScreen();
}
