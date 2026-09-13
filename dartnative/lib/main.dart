import 'package:dartnative/dartnative.dart';

import 'bench.dart';
import 'dartnative_plugin_registrant.dart';
import 'demo_video_feed_screen.dart';

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
  runApp(const VideoFeedApp());
}

class VideoFeedApp extends StatelessWidget {
  const VideoFeedApp({super.key});

  @override
  Widget build(BuildContext context) => const DemoVideoFeedScreen();
}
