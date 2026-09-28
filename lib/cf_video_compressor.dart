/// CombatFlux on-device video compression (Phase B0 proof of concept).
///
/// Platform-agnostic API. The Dart side decides *what* to produce (the
/// [CompressionPlanner] turns duration into a bitrate/resolution plan and
/// owns the single 85 % retry); the platform side only *executes* one encode
/// with the hardware encoder and reports what it produced.
///
/// The source video is never read into Dart memory: only URIs, paths and
/// numbers cross the platform channel.
library;

export 'src/compressor.dart';
export 'src/models.dart';
export 'src/planner.dart';
export 'src/platform.dart';
export 'src/preparer.dart';
