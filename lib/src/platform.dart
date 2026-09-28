import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'models.dart';

/// The native surface every platform implements. Android implements it
/// with Media3 Transformer (Phase B0). iOS will implement the same contract
/// with AVAssetReader/AVAssetWriter; nothing above this layer changes.
///
/// Contract:
/// * Only URIs/paths and numbers cross this boundary, never file bytes.
/// * [compress] runs exactly one encode attempt with the requested
///   settings and never retries on its own (retry policy lives in Dart).
/// * Outputs go to a plugin-owned temp directory ([tempDirectory]), are
///   named `cf_<timestamp>_a<attempt>.mp4`, and never overwrite the source.
abstract class CfVideoCompressorPlatform extends PlatformInterface {
  CfVideoCompressorPlatform() : super(token: _token);

  static final Object _token = Object();
  static CfVideoCompressorPlatform _instance = MethodChannelCfVideoCompressor();

  static CfVideoCompressorPlatform get instance => _instance;

  static set instance(CfVideoCompressorPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Opens the system picker. Returns a URI (Android: content://) or null
  /// when the user backs out. The file is not copied.
  Future<String?> pickVideo();

  Future<VideoInfo> getVideoInfo(String uri);

  /// One encode attempt. Resolves with the raw attempt map; throws
  /// [CompressionException] (code `CANCELLED` after [cancel]).
  Future<Map<Object?, Object?>> compress(Map<String, Object?> args);

  /// Progress of the running attempt.
  Stream<CompressionProgress> get progress;

  /// Cancels the running attempt and deletes its partial output.
  Future<bool> cancel();

  /// Deletes one output file; refuses paths outside [tempDirectory].
  Future<bool> deleteOutput(String path);

  /// Deletes every file in [tempDirectory]. Returns the number deleted.
  Future<int> deleteAllOutputs();

  Future<String> tempDirectory();

  /// Free bytes on the volume holding [tempDirectory].
  Future<int> availableTempBytes();

  /// Streams the source into [tempDirectory] (no RAM load) so it can be read
  /// as a plain file. Used when the source is already small enough.
  /// Throws [CompressionException] `NO_SPACE` / `SOURCE_UNREADABLE`.
  Future<({String path, int sizeBytes})> copySourceToTemp(
    String uri, {
    int expectedBytes = -1,
  });

  /// POC helper: copies an output (not the source) to the shared Movies
  /// folder so it can be inspected on a computer. Returns the new URI.
  Future<String> saveCopyToMovies(String path);
}

class MethodChannelCfVideoCompressor extends CfVideoCompressorPlatform {
  static const MethodChannel _methods =
      MethodChannel('com.combatflux/cf_video_compressor');
  static const EventChannel _events =
      EventChannel('com.combatflux/cf_video_compressor/progress');

  Stream<CompressionProgress>? _progress;

  Future<T> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return (await _methods.invokeMethod<T>(method, args)) as T;
    } on PlatformException catch (e) {
      throw CompressionException(e.code, e.message ?? e.code);
    }
  }

  @override
  Future<String?> pickVideo() async {
    try {
      return await _methods.invokeMethod<String>('pickVideo');
    } on PlatformException catch (e) {
      throw CompressionException(e.code, e.message ?? e.code);
    }
  }

  @override
  Future<VideoInfo> getVideoInfo(String uri) async => VideoInfo.fromMap(
      await _call<Map<Object?, Object?>>('getVideoInfo', {'uri': uri}));

  @override
  Future<Map<Object?, Object?>> compress(Map<String, Object?> args) =>
      _call<Map<Object?, Object?>>('compress', args);

  @override
  Stream<CompressionProgress> get progress => _progress ??= _events
      .receiveBroadcastStream()
      .map((e) => CompressionProgress.fromMap(e as Map<Object?, Object?>));

  @override
  Future<bool> cancel() => _call<bool>('cancel');

  @override
  Future<bool> deleteOutput(String path) =>
      _call<bool>('deleteOutput', {'path': path});

  @override
  Future<int> deleteAllOutputs() => _call<int>('deleteAllOutputs');

  @override
  Future<String> tempDirectory() => _call<String>('tempDirectory');

  @override
  Future<int> availableTempBytes() async =>
      (await _call<num>('availableTempBytes')).toInt();

  @override
  Future<({String path, int sizeBytes})> copySourceToTemp(
    String uri, {
    int expectedBytes = -1,
  }) async {
    final m = await _call<Map<Object?, Object?>>(
        'copySourceToTemp', {'uri': uri, 'expectedBytes': expectedBytes});
    return (path: m['path'] as String, sizeBytes: (m['sizeBytes'] as num).toInt());
  }

  @override
  Future<String> saveCopyToMovies(String path) =>
      _call<String>('saveCopyToMovies', {'path': path});
}
