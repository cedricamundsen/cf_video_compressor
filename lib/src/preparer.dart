import 'dart:async';

import 'compressor.dart';
import 'models.dart';
import 'planner.dart';

/// Why a video could not be turned into an uploadable analysis copy. The app
/// maps each kind to one localized message.
enum PrepareFailure {
  /// Required bitrate below the 0.6 Mbps floor (video too long).
  tooLong,

  /// The encoder/decoder cannot handle this input (codec/container).
  unsupportedInput,

  /// The source could not be opened/read (permission revoked, deleted...).
  sourceUnreadable,

  /// Not enough free storage for the temporary copy.
  insufficientStorage,

  /// The encoder failed for another reason.
  compressionFailed,

  /// Output still above the hard limit after the single 85 % retry.
  stillTooLarge,

  /// The user cancelled.
  cancelled,
}

class PrepareException implements Exception {
  const PrepareException(this.kind, this.detail);

  final PrepareFailure kind;
  final String detail;

  @override
  String toString() => 'PrepareException(${kind.name}): $detail';
}

/// What to do with a picked video.
class VideoDecision {
  const VideoDecision._(this.action, this.plan, this.reject, this.reason);

  factory VideoDecision.upload(String reason) =>
      VideoDecision._(VideoAction.uploadOriginal, null, null, reason);
  factory VideoDecision.compress(CompressionPlan plan, String reason) =>
      VideoDecision._(VideoAction.compress, plan, null, reason);
  factory VideoDecision.reject(PrepareFailure kind, String reason) =>
      VideoDecision._(VideoAction.reject, null, kind, reason);

  final VideoAction action;
  final CompressionPlan? plan;
  final PrepareFailure? reject;
  final String reason;
}

enum VideoAction { uploadOriginal, compress, reject }

/// The <= hard-limit file that goes to the existing uploader.
class PreparedVideo {
  const PreparedVideo({
    required this.path,
    required this.sizeBytes,
    required this.compressed,
    required this.elapsedMs,
    this.report,
  });

  /// Temp file inside the plugin temp dir (never the original).
  final String path;
  final int sizeBytes;
  final bool compressed;
  final int elapsedMs;
  final CompressionReport? report;
}

enum PrepareStage { checking, compressing, copying, ready }

/// Production flow: decide -> (copy | compress + verify + retry) -> file.
/// Platform-agnostic; iOS plugs in through [CfVideoCompressorPlatform].
class AnalysisVideoPreparer {
  AnalysisVideoPreparer({
    CfVideoCompressor? compressor,
    void Function(String line)? log,
  })  : compressor = compressor ?? CfVideoCompressor(),
        _log = log ?? ((_) {});

  final CfVideoCompressor compressor;
  final void Function(String line) _log;

  PlannerConfig get config => compressor.planner.config;

  /// Pure decision (unit-tested). Sources already <= the hard limit are
  /// uploaded as they are; bigger ones are compressed unless too long.
  VideoDecision decide(VideoInfo info) {
    final limit = config.hardLimitBytes;
    if (info.sizeBytes > 0 && info.sizeBytes <= limit) {
      return VideoDecision.upload(
          'source ${formatMiB(info.sizeBytes)} <= ${formatMiB(limit)}: no recompression');
    }
    final plan = compressor.plan(info);
    switch (plan.status) {
      case PlanStatus.invalid:
        return VideoDecision.reject(PrepareFailure.unsupportedInput,
            'duration/dimensions unreadable and size ${info.sizeBytes} B is not uploadable as-is');
      case PlanStatus.belowFloor:
        return VideoDecision.reject(PrepareFailure.tooLong,
            'needs ${formatMbps(plan.videoBitrate)} (< ${formatMbps(config.sdMinVideoBitrate)} floor)');
      case PlanStatus.ok:
        return VideoDecision.compress(plan,
            'source ${info.sizeBytes < 0 ? 'size unknown' : formatMiB(info.sizeBytes)} > ${formatMiB(limit)}: compress');
    }
  }

  /// Longest duration that still passes the floor (for the "too long" text).
  int get maxSupportedDurationMs =>
      compressor.planner.maxDurationMsFor(config.sdMinVideoBitrate);

  Future<PreparedVideo> prepare(
    VideoInfo info, {
    void Function(PrepareStage stage)? onStage,
    void Function(CompressionProgress progress)? onProgress,
  }) async {
    final watch = Stopwatch()..start();
    onStage?.call(PrepareStage.checking);
    _log('source ${info.describe()}');
    final decision = decide(info);
    _log('decision ${decision.action.name}: ${decision.reason}');
    if (decision.action == VideoAction.reject) {
      throw PrepareException(decision.reject!, decision.reason);
    }

    // Remove leftovers of earlier runs (never touches the original).
    try {
      await compressor.deleteAllOutputs();
    } catch (_) {}

    if (decision.action == VideoAction.uploadOriginal) {
      onStage?.call(PrepareStage.copying);
      try {
        final copy = await compressor.copySourceToTemp(info.uri,
            expectedBytes: info.sizeBytes);
        if (copy.sizeBytes > config.hardLimitBytes) {
          await compressor.deleteOutput(copy.path);
          throw PrepareException(PrepareFailure.stillTooLarge,
              'copied source is ${copy.sizeBytes} B');
        }
        _log('compression skipped; temp copy ${copy.sizeBytes} B in ${watch.elapsedMilliseconds} ms');
        onStage?.call(PrepareStage.ready);
        return PreparedVideo(
          path: copy.path,
          sizeBytes: copy.sizeBytes,
          compressed: false,
          elapsedMs: watch.elapsedMilliseconds,
        );
      } on CompressionException catch (e) {
        throw PrepareException(_failureFor(e.code), '${e.code}: ${e.message}');
      }
    }

    final plan = decision.plan!;
    final free = await _free();
    final needed = CfVideoCompressor.requiredFreeBytes(plan);
    if (free != null && free < needed) {
      throw PrepareException(PrepareFailure.insufficientStorage,
          'free $free B < needed $needed B');
    }
    _log('compress requested ${plan.resolutionLabel} '
        '${formatMbps(plan.videoBitrate)} video + ${plan.audioBitrate ~/ 1000} kbps AAC, '
        'fps cap ${plan.maxFrameRate?.toStringAsFixed(0) ?? 'none'}, '
        'estimate ${formatMiB(plan.estimatedOutputBytes)}');
    onStage?.call(PrepareStage.compressing);
    final report = await compressor.compress(info, plan, onProgress: onProgress);
    for (final a in report.attempts) {
      _log('attempt ${a.describe()}${a.deleted ? ' (over limit, deleted)' : ''}');
    }
    switch (report.outcome) {
      case CompressionOutcome.success:
        final a = report.finalAttempt!;
        _log('compression ok in ${(report.totalElapsedMs / 1000).toStringAsFixed(1)} s, '
            '${report.attempts.length} attempt(s)');
        onStage?.call(PrepareStage.ready);
        return PreparedVideo(
          path: a.outputPath,
          sizeBytes: a.outputSizeBytes,
          compressed: true,
          elapsedMs: watch.elapsedMilliseconds,
          report: report,
        );
      case CompressionOutcome.overLimit:
        throw PrepareException(
            PrepareFailure.stillTooLarge, report.errorMessage ?? 'over limit');
      case CompressionOutcome.cancelled:
        throw const PrepareException(PrepareFailure.cancelled, 'cancelled');
      case CompressionOutcome.failed:
        throw PrepareException(_failureFor(report.errorCode ?? ''),
            '${report.errorCode}: ${report.errorMessage}');
    }
  }

  Future<bool> cancel() => compressor.cancel();

  /// Deletes every temp output/copy. Safe to call at any time when idle.
  Future<void> cleanup() async {
    try {
      final n = await compressor.deleteAllOutputs();
      _log('temp cleanup: $n file(s) deleted');
    } catch (e) {
      _log('temp cleanup failed: $e');
    }
  }

  Future<int?> _free() async {
    try {
      return await compressor.availableTempBytes();
    } catch (_) {
      return null;
    }
  }

  static PrepareFailure _failureFor(String code) => switch (code) {
        'NO_SPACE' => PrepareFailure.insufficientStorage,
        'UNSUPPORTED_INPUT' => PrepareFailure.unsupportedInput,
        'SOURCE_UNREADABLE' => PrepareFailure.sourceUnreadable,
        'CANCELLED' => PrepareFailure.cancelled,
        _ => PrepareFailure.compressionFailed,
      };
}
