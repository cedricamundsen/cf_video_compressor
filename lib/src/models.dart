import 'dart:math' as math;

int? _int(Object? v) => v is num ? v.toInt() : null;
double? _double(Object? v) => v is num ? v.toDouble() : null;

/// 1 MiB = 1,048,576 bytes.
const int kMiB = 1024 * 1024;

String formatMiB(int bytes) => '${(bytes / kMiB).toStringAsFixed(2)} MiB';

String formatMbps(int? bitsPerSecond) => bitsPerSecond == null || bitsPerSecond <= 0
    ? 'n/a'
    : '${(bitsPerSecond / 1e6).toStringAsFixed(2)} Mbps';

String formatDuration(int ms) {
  final s = (ms / 1000).round();
  final m = s ~/ 60;
  return '$m:${(s % 60).toString().padLeft(2, '0')}';
}

/// Metadata of a video, probed natively without decoding or loading it.
class VideoInfo {
  const VideoInfo({
    required this.uri,
    required this.sizeBytes,
    required this.durationMs,
    required this.width,
    required this.height,
    this.displayName,
    this.rotationDegrees = 0,
    this.frameRate,
    this.videoMime,
    this.audioMime,
    this.bitrate,
    this.videoBitrate,
    this.audioBitrate,
    this.audioChannels,
    this.audioSampleRate,
    this.hasAudio = true,
    this.colorTransfer,
  });

  /// content:// or file:// URI (or absolute path) of the source.
  final String uri;
  final String? displayName;

  /// Size in bytes, or -1 if the provider does not report it.
  final int sizeBytes;
  final int durationMs;

  /// Coded (stored) dimensions. See [displayWidth]/[displayHeight] for the
  /// dimensions after applying [rotationDegrees].
  final int width;
  final int height;
  final int rotationDegrees;
  final double? frameRate;

  /// e.g. `video/avc`, `video/hevc`.
  final String? videoMime;

  /// e.g. `audio/mp4a-latm`.
  final String? audioMime;

  /// Overall container bitrate (bits/s) if reported.
  final int? bitrate;
  final int? videoBitrate;
  final int? audioBitrate;
  final int? audioChannels;
  final int? audioSampleRate;
  final bool hasAudio;

  /// MediaFormat color transfer (6 = PQ/HDR10, 7 = HLG), when reported.
  final int? colorTransfer;

  bool get isRotated => rotationDegrees % 180 != 0;
  int get displayWidth => isRotated ? height : width;
  int get displayHeight => isRotated ? width : height;
  int get shortSide => math.min(width, height);
  bool get isHdr => colorTransfer == 6 || colorTransfer == 7;
  String get resolutionLabel => '${displayWidth}x$displayHeight';

  /// Inverse of [VideoInfo.fromMap] (JSON-safe; used to keep a picked video
  /// in app state as a string).
  Map<String, Object?> toMap() => {
        'uri': uri,
        'displayName': displayName,
        'sizeBytes': sizeBytes,
        'durationMs': durationMs,
        'width': width,
        'height': height,
        'rotationDegrees': rotationDegrees,
        'frameRate': frameRate,
        'videoMime': videoMime,
        'audioMime': audioMime,
        'bitrate': bitrate,
        'videoBitrate': videoBitrate,
        'audioBitrate': audioBitrate,
        'audioChannels': audioChannels,
        'audioSampleRate': audioSampleRate,
        'hasAudio': hasAudio,
        'colorTransfer': colorTransfer,
      };

  /// One-line summary for logs.
  String describe() => 'size=${sizeBytes < 0 ? 'unknown' : '$sizeBytes B (${formatMiB(sizeBytes)})'} '
      'duration=${formatDuration(durationMs)} (${durationMs}ms) '
      'resolution=$resolutionLabel (coded ${width}x$height rot $rotationDegrees) '
      'fps=${frameRate?.toStringAsFixed(2) ?? 'unknown'} '
      'video=${videoMime ?? 'unknown'} audio=${hasAudio ? (audioMime ?? 'unknown') : 'none'} '
      'bitrate=${formatMbps(bitrate)} hdr=$isHdr';

  factory VideoInfo.fromMap(Map<Object?, Object?> m) => VideoInfo(
        uri: m['uri'] as String,
        displayName: m['displayName'] as String?,
        sizeBytes: _int(m['sizeBytes']) ?? -1,
        durationMs: _int(m['durationMs']) ?? 0,
        width: _int(m['width']) ?? 0,
        height: _int(m['height']) ?? 0,
        rotationDegrees: _int(m['rotationDegrees']) ?? 0,
        frameRate: _double(m['frameRate']),
        videoMime: m['videoMime'] as String?,
        audioMime: m['audioMime'] as String?,
        bitrate: _int(m['bitrate']),
        videoBitrate: _int(m['videoBitrate']),
        audioBitrate: _int(m['audioBitrate']),
        audioChannels: _int(m['audioChannels']),
        audioSampleRate: _int(m['audioSampleRate']),
        hasAudio: m['hasAudio'] as bool? ?? true,
        colorTransfer: _int(m['colorTransfer']),
      );
}

enum PlanStatus {
  /// Bitrate is at or above the 540p floor; safe to compress.
  ok,

  /// Required video bitrate is below the floor (video too long for the
  /// budget). Production would reject; the POC lets you force it to see
  /// what the quality looks like.
  belowFloor,

  /// Duration unknown or zero.
  invalid,
}

/// What one encode attempt should produce. Pure data; built by
/// [CompressionPlanner].
class CompressionPlan {
  const CompressionPlan({
    required this.status,
    required this.attempt,
    required this.durationMs,
    required this.videoBitrate,
    required this.audioBitrate,
    required this.targetShortSide,
    required this.maxFrameRate,
    required this.toneMapHdrToSdr,
    required this.targetBytes,
    required this.hardLimitBytes,
    required this.estimatedOutputBytes,
    required this.sourceAlreadyFits,
    required this.notes,
  });

  final PlanStatus status;

  /// 1 = first attempt, 2 = the single retry at 85 %.
  final int attempt;
  final int durationMs;

  /// Requested video bitrate (bits/s) handed to the hardware encoder.
  final int videoBitrate;

  /// Requested AAC bitrate (bits/s); 0 if the source has no audio.
  final int audioBitrate;

  /// Output short side in px (720 or 540), or null to keep the source size
  /// (never upscale).
  final int? targetShortSide;

  /// Frame-rate cap (30) or null when the source is already <= 30 fps.
  final double? maxFrameRate;
  final bool toneMapHdrToSdr;
  final int targetBytes;
  final int hardLimitBytes;
  final int estimatedOutputBytes;

  /// The source file is already <= the hard limit (compression optional).
  final bool sourceAlreadyFits;
  final List<String> notes;

  String get resolutionLabel =>
      targetShortSide == null ? 'source resolution' : '${targetShortSide}p';

  /// Arguments for the platform `compress` call.
  Map<String, Object?> toPlatformArgs(
    String sourceUri, {
    EncoderBitrateMode bitrateMode = EncoderBitrateMode.vbr,
  }) =>
      {
        'uri': sourceUri,
        'attempt': attempt,
        'videoBitrate': videoBitrate,
        'audioBitrate': audioBitrate,
        'targetShortSide': targetShortSide,
        'maxFrameRate': maxFrameRate,
        'toneMapHdrToSdr': toneMapHdrToSdr,
        'bitrateMode': bitrateMode.name,
      };
}

/// Encoder rate control. VBR (default) spends bits where the motion is;
/// CBR is more size-predictable. The POC exposes both for comparison.
enum EncoderBitrateMode { vbr, cbr }

/// Raw result of one native encode attempt.
class CompressionAttempt {
  const CompressionAttempt({
    required this.attempt,
    required this.requestedVideoBitrate,
    required this.requestedAudioBitrate,
    required this.requestedShortSide,
    required this.outputPath,
    required this.outputSizeBytes,
    required this.outputWidth,
    required this.outputHeight,
    required this.outputRotationDegrees,
    required this.outputDurationMs,
    required this.elapsedMs,
    required this.hardLimitBytes,
    this.averageVideoBitrate,
    this.averageAudioBitrate,
    this.outputFrameRate,
    this.videoEncoderName,
    this.audioEncoderName,
    this.videoConversion,
    this.audioConversion,
    this.outputVideoMime,
    this.outputAudioMime,
    this.deleted = false,
  });

  /// Codecs actually found in the output file (re-probed).
  final String? outputVideoMime;
  final String? outputAudioMime;

  final int attempt;
  final int requestedVideoBitrate;
  final int requestedAudioBitrate;
  final int? requestedShortSide;
  final String outputPath;
  final int outputSizeBytes;

  /// Coded dimensions of the output track.
  final int outputWidth;
  final int outputHeight;
  final int outputRotationDegrees;
  final int outputDurationMs;
  final int elapsedMs;
  final int hardLimitBytes;
  final int? averageVideoBitrate;
  final int? averageAudioBitrate;
  final double? outputFrameRate;
  final String? videoEncoderName;
  final String? audioEncoderName;
  final String? videoConversion;
  final String? audioConversion;

  /// True when the over-limit output was deleted before the retry.
  final bool deleted;

  bool get underHardLimit => outputSizeBytes <= hardLimitBytes;
  bool get isRotated => outputRotationDegrees % 180 != 0;
  String get resolutionLabel =>
      isRotated ? '${outputHeight}x$outputWidth' : '${outputWidth}x$outputHeight';

  /// Whole-file bitrate: size * 8 / duration.
  int get overallBitrate => outputDurationMs <= 0
      ? 0
      : (outputSizeBytes * 8 * 1000 / outputDurationMs).round();

  CompressionAttempt markDeleted() => CompressionAttempt(
        attempt: attempt,
        requestedVideoBitrate: requestedVideoBitrate,
        requestedAudioBitrate: requestedAudioBitrate,
        requestedShortSide: requestedShortSide,
        outputPath: outputPath,
        outputSizeBytes: outputSizeBytes,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        outputRotationDegrees: outputRotationDegrees,
        outputDurationMs: outputDurationMs,
        elapsedMs: elapsedMs,
        hardLimitBytes: hardLimitBytes,
        averageVideoBitrate: averageVideoBitrate,
        averageAudioBitrate: averageAudioBitrate,
        outputFrameRate: outputFrameRate,
        videoEncoderName: videoEncoderName,
        audioEncoderName: audioEncoderName,
        videoConversion: videoConversion,
        audioConversion: audioConversion,
        outputVideoMime: outputVideoMime,
        outputAudioMime: outputAudioMime,
        deleted: true,
      );

  /// One-line summary for logs.
  String describe() => 'attempt=$attempt size=$outputSizeBytes B (${formatMiB(outputSizeBytes)}) '
      'resolution=$resolutionLabel duration=${formatDuration(outputDurationMs)} '
      'fps=${outputFrameRate?.toStringAsFixed(2) ?? 'unknown'} '
      'codec=${outputVideoMime ?? '?'}/${outputAudioMime ?? '?'} '
      'requested=${formatMbps(requestedVideoBitrate)}+${requestedAudioBitrate ~/ 1000}kbps '
      '@${requestedShortSide == null ? 'source' : '${requestedShortSide}p'} '
      'result=${formatMbps(averageVideoBitrate)} video, ${formatMbps(overallBitrate)} overall '
      'time=${(elapsedMs / 1000).toStringAsFixed(1)}s encoder=${videoEncoderName ?? '?'} '
      'underLimit=$underHardLimit';

  factory CompressionAttempt.fromMap(
    Map<Object?, Object?> m, {
    required CompressionPlan plan,
  }) =>
      CompressionAttempt(
        attempt: plan.attempt,
        requestedVideoBitrate: plan.videoBitrate,
        requestedAudioBitrate: plan.audioBitrate,
        requestedShortSide: plan.targetShortSide,
        hardLimitBytes: plan.hardLimitBytes,
        outputPath: m['outputPath'] as String,
        outputSizeBytes: _int(m['outputSizeBytes']) ?? 0,
        outputWidth: _int(m['outputWidth']) ?? 0,
        outputHeight: _int(m['outputHeight']) ?? 0,
        outputRotationDegrees: _int(m['outputRotationDegrees']) ?? 0,
        outputDurationMs: _int(m['outputDurationMs']) ?? 0,
        elapsedMs: _int(m['elapsedMs']) ?? 0,
        averageVideoBitrate: _positive(_int(m['averageVideoBitrate'])),
        averageAudioBitrate: _positive(_int(m['averageAudioBitrate'])),
        outputFrameRate: _double(m['outputFrameRate']),
        videoEncoderName: m['videoEncoderName'] as String?,
        audioEncoderName: m['audioEncoderName'] as String?,
        videoConversion: m['videoConversion'] as String?,
        audioConversion: m['audioConversion'] as String?,
        outputVideoMime: m['outputVideoMime'] as String?,
        outputAudioMime: m['outputAudioMime'] as String?,
      );

  static int? _positive(int? v) => v == null || v <= 0 ? null : v;
}

enum CompressionOutcome {
  /// Final output is <= the hard limit.
  success,

  /// Both attempts ended above the hard limit.
  overLimit,
  cancelled,
  failed,
}

/// Everything the POC needs to report for one source video.
class CompressionReport {
  const CompressionReport({
    required this.source,
    required this.outcome,
    required this.attempts,
    this.errorCode,
    this.errorMessage,
  });

  final VideoInfo source;
  final CompressionOutcome outcome;
  final List<CompressionAttempt> attempts;
  final String? errorCode;
  final String? errorMessage;

  CompressionAttempt? get finalAttempt => attempts.isEmpty ? null : attempts.last;
  bool get retried => attempts.length > 1;

  /// Total wall time spent encoding across attempts.
  int get totalElapsedMs => attempts.fold(0, (s, a) => s + a.elapsedMs);
}

/// Progress event for the running attempt. [percent] comes from the
/// encoder pipeline itself (Transformer.getProgress), not from a timer.
class CompressionProgress {
  const CompressionProgress({
    required this.attempt,
    required this.percent,
    required this.state,
  });

  final int attempt;

  /// 0-100, or -1 while the platform cannot report progress yet.
  final int percent;

  /// `waiting`, `running`, `unavailable`.
  final String state;

  factory CompressionProgress.fromMap(Map<Object?, Object?> m) =>
      CompressionProgress(
        attempt: _int(m['attempt']) ?? 1,
        percent: _int(m['percent']) ?? -1,
        state: m['state'] as String? ?? 'running',
      );
}

/// Error from the platform side.
class CompressionException implements Exception {
  const CompressionException(this.code, this.message);

  /// `CANCELLED`, `BUSY`, `EXPORT_FAILED`, `SOURCE_UNREADABLE`, ...
  final String code;
  final String message;
  bool get isCancelled => code == 'CANCELLED';

  @override
  String toString() => 'CompressionException($code): $message';
}
