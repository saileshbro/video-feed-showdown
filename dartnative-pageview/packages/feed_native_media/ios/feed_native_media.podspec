Pod::Spec.new do |s|
  s.name             = 'feed_native_media'
  s.version          = '0.1.0'
  s.summary          = 'Background playback, PiP, Now Playing and AirPlay for the feed.'
  s.homepage         = 'https://github.com/saileshbro/video-feed-showdown'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Sailesh Dahal' => 'accounts@launchbox.tech' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.frameworks       = 'AVFoundation', 'AVKit', 'MediaPlayer', 'UIKit'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  # The @_cdecl symbols are only looked up at runtime through
  # DynamicLibrary.process(), so nothing references them at link time. Same
  # two settings the first-party plugins declare to keep them in the binary.
  s.user_target_xcconfig = {
    'DEAD_CODE_STRIPPING' => 'NO',
    'ENABLE_DEBUG_DYLIB' => 'NO',
  }
end
