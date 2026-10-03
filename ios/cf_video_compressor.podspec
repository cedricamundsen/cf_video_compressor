#
# cf_video_compressor - iOS side (AVFoundation: AVAssetReader + AVAssetWriter).
#
Pod::Spec.new do |s|
  s.name             = 'cf_video_compressor'
  s.version          = '0.2.0'
  s.summary          = 'CombatFlux on-device video compression (iOS: AVFoundation, Android: Media3).'
  s.description      = <<-DESC
Probes, compresses (H.264/AAC, upright, <= 30 fps, 720p/540p, HDR -> SDR) and
manages temp files for CombatFlux match videos. Same Dart contract on iOS and Android.
                       DESC
  s.homepage         = 'https://github.com/cedricamundsen/cf_video_compressor'
  s.license          = { :type => 'Proprietary', :text => 'Copyright CombatFlux. All rights reserved.' }
  s.author           = { 'CombatFlux' => 'cedricamundsen@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '14.0'
  s.frameworks       = 'AVFoundation', 'CoreMedia', 'PhotosUI', 'UniformTypeIdentifiers', 'UIKit'
  s.swift_version    = '5.0'
  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  # Privacy manifest: required-reason API "disk space" (free space is checked before writing).
  s.resource_bundles = { 'cf_video_compressor_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
