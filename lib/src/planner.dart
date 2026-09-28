import 'dart:math' as math;

import 'models.dart';

/// All tunables of the compression rules in one place.
class PlannerConfig {
  const PlannerConfig({
    this.targetBytes = 90 * kMiB, // 94,371,840
    this.hardLimitBytes = 95 * kMiB, // 99,614,720
    this.audioBitrate = 64000,
    this.containerOverheadFraction = 0.01,
    this.maxVideoBitrate = 3000000,
    this.hdMinVideoBitrate = 1000000,
    this.hdShortSide = 720,
    this.sdMinVideoBitrate = 600000,
    this.sdShortSide = 540,
    this.maxFrameRate = 30,
    this.frameRateTolerance = 0.5,
    this.retryFactor = 0.85,
    this.toneMapHdrToSdr = true,
  });

  /// Output budget the bitrate is computed from (90 MiB).
  final int targetBytes;

  /// Absolute ceiling (95 MiB). Output above this triggers the one retry.
  final int hardLimitBytes;
  final int audioBitrate;

  /// Share of [targetBytes] reserved for MP4 boxes/index (~1 %).
  final double containerOverheadFraction;

  /// Quality cap: never request more than this, even for short clips.
  final int maxVideoBitrate;

  /// >= this -> 720p short side.
  final int hdMinVideoBitrate;
  final int hdShortSide;

  /// >= this (and < hd) -> 540p short side; below -> reject/warn.
  final int sdMinVideoBitrate;
  final int sdShortSide;
  final double maxFrameRate;
  final double frameRateTolerance;

  /// Retry bitrate = previous video bitrate * this.
  final double retryFactor;

  /// HDR sources (HDR10/HLG) are tone-mapped to SDR H.264.
  final bool toneMapHdrToSdr;
}

/// Pure-Dart rules: duration -> bitrate -> resolution. No platform code,
/// fully unit-tested, shared by Android and (later) iOS.
class CompressionPlanner {
  const CompressionPlanner([this.config = const PlannerConfig()]);

  final PlannerConfig config;

  /// Video bitrate that makes [durationMs] fit the target budget, before
  /// the 3 Mbps cap. Audio and container overhead are subtracted first.
  int budgetVideoBitrate(int durationMs, {bool hasAudio = true}) {
    if (durationMs <= 0) return 0;
    final usableBits =
        config.targetBytes * 8 * (1 - config.containerOverheadFraction);
    final totalBitrate = usableBits * 1000 / durationMs;
    final audio = hasAudio ? config.audioBitrate : 0;
    return math.max(0, (totalBitrate - audio).floor());
  }

  /// Resolution tier for a requested video bitrate (short side in px).
  int shortSideForBitrate(int videoBitrate) =>
      videoBitrate >= config.hdMinVideoBitrate
          ? config.hdShortSide
          : config.sdShortSide;

  /// Longest duration that still gets 720p / still passes the 540p floor.
  int maxDurationMsFor(int minVideoBitrate, {bool hasAudio = true}) {
    final usableBits =
        config.targetBytes * 8 * (1 - config.containerOverheadFraction);
    final audio = hasAudio ? config.audioBitrate : 0;
    return (usableBits * 1000 / (minVideoBitrate + audio)).floor();
  }

  CompressionPlan plan(VideoInfo source) {
    final notes = <String>[];
    final audio = source.hasAudio ? config.audioBitrate : 0;
    final alreadyFits =
        source.sizeBytes > 0 && source.sizeBytes <= config.hardLimitBytes;

    if (source.durationMs <= 0 || source.width <= 0 || source.height <= 0) {
      return _build(
        status: PlanStatus.invalid,
        attempt: 1,
        source: source,
        videoBitrate: 0,
        audio: audio,
        notes: ['Could not read duration/dimensions from this file.'],
        alreadyFits: alreadyFits,
      );
    }

    final budget = budgetVideoBitrate(source.durationMs, hasAudio: source.hasAudio);
    var video = budget;
    if (video > config.maxVideoBitrate) {
      video = config.maxVideoBitrate;
      notes.add('Short clip: capped at ${formatMbps(config.maxVideoBitrate)} '
          '(budget allows ${formatMbps(budget)}).');
    }

    var status = PlanStatus.ok;
    if (video < config.sdMinVideoBitrate) {
      status = PlanStatus.belowFloor;
      notes.add('Needs ${formatMbps(video)} which is below the '
          '${formatMbps(config.sdMinVideoBitrate)} floor: production would '
          'reject this length (max ~${formatDuration(maxDurationMsFor(config.sdMinVideoBitrate, hasAudio: source.hasAudio))}).');
    }
    if (alreadyFits) {
      notes.add('Source is already ${formatMiB(source.sizeBytes)} '
          '(<= ${formatMiB(config.hardLimitBytes)}); compression is optional.');
    }
    if (source.isHdr && config.toneMapHdrToSdr) {
      notes.add('HDR source: will be tone-mapped to SDR.');
    }

    return _build(
      status: status,
      attempt: 1,
      source: source,
      videoBitrate: video,
      audio: audio,
      notes: notes,
      alreadyFits: alreadyFits,
    );
  }

  /// The single retry after an output above the hard limit: 85 % of the
  /// previous video bitrate, re-tiered (may drop 720p -> 540p).
  CompressionPlan retryPlan(VideoInfo source, CompressionPlan previous) {
    final video = (previous.videoBitrate * config.retryFactor).floor();
    return _build(
      status: video < config.sdMinVideoBitrate
          ? PlanStatus.belowFloor
          : previous.status,
      attempt: previous.attempt + 1,
      source: source,
      videoBitrate: video,
      audio: previous.audioBitrate,
      notes: [
        'Retry: previous output exceeded ${formatMiB(config.hardLimitBytes)}; '
            'video bitrate ${formatMbps(previous.videoBitrate)} x '
            '${config.retryFactor} = ${formatMbps(video)}.',
      ],
      alreadyFits: previous.sourceAlreadyFits,
    );
  }

  CompressionPlan _build({
    required PlanStatus status,
    required int attempt,
    required VideoInfo source,
    required int videoBitrate,
    required int audio,
    required List<String> notes,
    required bool alreadyFits,
  }) {
    final tier = shortSideForBitrate(videoBitrate);
    // Never upscale: keep the source size when it is already <= the tier.
    final int? shortSide = source.shortSide > tier ? tier : null;
    if (shortSide == null && status != PlanStatus.invalid) {
      notes.add('Source short side ${source.shortSide}px <= ${tier}p: '
          'resolution kept.');
    }

    final fps = source.frameRate;
    final double? maxFps =
        fps != null && fps > config.maxFrameRate + config.frameRateTolerance
            ? config.maxFrameRate
            : null;
    if (fps == null && status != PlanStatus.invalid) {
      notes.add('Source frame rate unknown: no frame-rate cap applied.');
    }

    final estimated = source.durationMs <= 0
        ? 0
        : ((videoBitrate + audio) * source.durationMs / 1000 / 8 /
                (1 - config.containerOverheadFraction))
            .round();

    return CompressionPlan(
      status: status,
      attempt: attempt,
      durationMs: source.durationMs,
      videoBitrate: videoBitrate,
      audioBitrate: audio,
      targetShortSide: shortSide,
      maxFrameRate: maxFps,
      toneMapHdrToSdr: config.toneMapHdrToSdr,
      targetBytes: config.targetBytes,
      hardLimitBytes: config.hardLimitBytes,
      estimatedOutputBytes: estimated,
      sourceAlreadyFits: alreadyFits,
      notes: List.unmodifiable(notes),
    );
  }
}
