import 'dart:async';

import 'models.dart';
import 'planner.dart';
import 'platform.dart';

/// High-level, platform-agnostic entry point.
///
/// ```dart
/// final c = CfVideoCompressor();
/// final uri = await c.pickVideo();
/// final info = await c.getVideoInfo(uri!);
/// final plan = c.plan(info);
/// final report = await c.compress(info, plan, onProgress: print);
/// ```
class CfVideoCompressor {
  CfVideoCompressor({
    this.planner = const CompressionPlanner(),
    CfVideoCompressorPlatform? platform,
  }) : _platform = platform ?? CfVideoCompressorPlatform.instance;

  final CompressionPlanner planner;
  final CfVideoCompressorPlatform _platform;
  bool _cancelRequested = false;

  Future<String?> pickVideo() => _platform.pickVideo();

  Future<VideoInfo> getVideoInfo(String uri) => _platform.getVideoInfo(uri);

  CompressionPlan plan(VideoInfo source) => planner.plan(source);

  /// Runs attempt 1 and, only if its output is above the hard limit, one
  /// retry at 85 % of the video bitrate. The over-limit output of attempt 1
  /// is deleted before the retry (it is unusable). The source is only read.
  ///
  /// Never throws for encode failures/cancel: the outcome is in the report.
  Future<CompressionReport> compress(
    VideoInfo source,
    CompressionPlan plan, {
    void Function(CompressionProgress progress)? onProgress,
    bool allowRetry = true,
    EncoderBitrateMode bitrateMode = EncoderBitrateMode.vbr,
  }) async {
    _cancelRequested = false;
    final attempts = <CompressionAttempt>[];
    StreamSubscription<CompressionProgress>? sub;
    if (onProgress != null) sub = _platform.progress.listen(onProgress);

    try {
      var current = plan;
      while (true) {
        final raw = await _platform.compress({
          ...current.toPlatformArgs(source.uri, bitrateMode: bitrateMode),
          // Native side refuses to start when this much space is not free.
          'requiredBytes': requiredFreeBytes(current),
        });
        final attempt = CompressionAttempt.fromMap(raw, plan: current);

        if (attempt.underHardLimit) {
          attempts.add(attempt);
          return CompressionReport(
            source: source,
            outcome: CompressionOutcome.success,
            attempts: attempts,
          );
        }

        // Over the hard limit: this file can never be uploaded.
        await _platform.deleteOutput(attempt.outputPath);
        attempts.add(attempt.markDeleted());

        if (!allowRetry || current.attempt >= 2 || _cancelRequested) {
          return CompressionReport(
            source: source,
            outcome: CompressionOutcome.overLimit,
            attempts: attempts,
            errorMessage: 'Output ${formatMiB(attempt.outputSizeBytes)} is '
                'above ${formatMiB(attempt.hardLimitBytes)} after '
                '${attempts.length} attempt(s).',
          );
        }
        current = planner.retryPlan(source, current);
      }
    } on CompressionException catch (e) {
      return CompressionReport(
        source: source,
        outcome: e.isCancelled
            ? CompressionOutcome.cancelled
            : CompressionOutcome.failed,
        attempts: attempts,
        errorCode: e.code,
        errorMessage: e.message,
      );
    } finally {
      await sub?.cancel();
    }
  }

  /// Cancels the running attempt; the pending [compress] resolves with
  /// [CompressionOutcome.cancelled] and the partial file is deleted.
  Future<bool> cancel() {
    _cancelRequested = true;
    return _platform.cancel();
  }

  Future<bool> deleteOutput(String path) => _platform.deleteOutput(path);

  Future<int> deleteAllOutputs() => _platform.deleteAllOutputs();

  Future<String> tempDirectory() => _platform.tempDirectory();

  Future<int> availableTempBytes() => _platform.availableTempBytes();

  Future<({String path, int sizeBytes})> copySourceToTemp(
    String uri, {
    int expectedBytes = -1,
  }) =>
      _platform.copySourceToTemp(uri, expectedBytes: expectedBytes);

  /// Free space needed before an attempt: the hard limit (the worst output
  /// that is still accepted) plus 32 MiB of working margin.
  static int requiredFreeBytes(CompressionPlan plan) =>
      plan.hardLimitBytes + 32 * kMiB;

  Future<String> saveCopyToMovies(String path) =>
      _platform.saveCopyToMovies(path);
}
