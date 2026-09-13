import 'package:flutter/material.dart';

import 'bench.dart';
import 'feed_screen.dart';

void main() {
  Bench.event('main_enter');
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VideoFeedApp());
}

class VideoFeedApp extends StatelessWidget {
  const VideoFeedApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: VideoFeedScreen(),
    );
  }
}
