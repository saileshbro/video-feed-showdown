// GENERATED FILE — DO NOT EDIT BY HAND.
//
// Regenerated automatically on `dn pub get` / `dn create` whenever the set of
// DartNative plugins changes. `registerAll()` selects the platform bindings
// AND loads every plugin's FFI symbols, so `main()` needs only:
//
//   void main() {
//     DartNativePluginRegistrant.registerAll();
//     runApp(const MyApp());
//   }
//
// To hand-own this file, delete the header line above; the CLI then stops
// overwriting it.
//
// Plugins loaded:
//   • dartnative_share
//   • dartnative_video_player
//   • feed_native_media

import 'dart:io' show Platform;

import 'package:dartnative/dartnative.dart';
import 'package:dartnative_ios/dartnative_ios.dart';
import 'package:dartnative_android/dartnative_android.dart';
import 'package:dartnative_share/dartnative_share.dart';
import 'package:dartnative_video_player/dartnative_video_player.dart';
import 'package:feed_native_media/feed_native_media.dart';

abstract final class DartNativePluginRegistrant {
  /// Registers the platform bindings and loads every DartNative plugin's
  /// FFI symbols. Call once as the first line of `main()`, before `runApp`.
  static void registerAll() {
    const dnLicenseToken = String.fromEnvironment('DART_NATIVE_LICENSE_TOKEN');
    if (dnLicenseToken.isNotEmpty) {
      DartNativeLicense.instance.provideToken(dnLicenseToken);
    }
    const dnLicenseKey = String.fromEnvironment('DN_LICENSE_KEY');
    if (dnLicenseKey.isNotEmpty) {
      DartNativeLicense.instance.provideLicenseKey(dnLicenseKey);
    }
    const dnTrialEnded = bool.fromEnvironment('DN_TRIAL_ENDED');
    if (dnTrialEnded) {
      DartNativeLicense.instance.noteTrialEnded();
    }
    DartNativeLicense.instance.reportPluginUsage(const <String>[
      'dartnative_share',
      'dartnative_video_player',
      'feed_native_media',
    ]);
    registerNativeBindings(
      Platform.isAndroid
          ? AndroidNativeBindings.instance
          : IOSNativeBindings.instance,
    );
    _load('dartnative_share', () {
      ShareFFIBindings.loadSymbols();
    });
    _load('dartnative_video_player', () {
      VideoFFIBindings.loadSymbols();
    });
    _load('feed_native_media', () {
      FeedNativeMedia.loadSymbols();
    });
  }

  /// Loads one plugin's FFI symbols, turning a missing native side into a
  /// message that names the fix.
  static void _load(String plugin, void Function() load) {
    try {
      load();
    } catch (e) {
      dnLog(
        '[dartnative] $plugin: its native symbols are not in this build.\n'
        '  iOS:     run `pod install` in ios/, then rebuild.\n'
        '  Android: rebuild so the plugin library is packaged.\n'
        '  The app keeps going; this plugin will not work until then.\n'
        '  $e',
      );
    }
  }
}
