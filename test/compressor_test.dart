import 'dart:async';

import 'package:cf_video_compressor/cf_video_compressor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Fake native side: returns scripted output sizes per attempt.
class FakePlatform extends CfVideoCompressorPlatform
    with MockPlatformInterfaceMixin {
  FakePlatform(
    this.sizes, {
    this.throwCode,
    this.freeBytes = 10 * 1024 * kMiB,
    this.copyThrowCode,
  });

  final List<int> sizes;
  final String? throwCode;
  final int freeBytes;
  final String? copyThrowCode;
  final copies = <String>[];
  int deleteAllCalls = 0;
  final calls = <Map<String, Object?>>[];
  final deleted = <String>[];
  final _progress = StreamController<CompressionProgress>.broadcast();

  @override
  Future<Map<Object?, Object?>> compress(Map<String, Object?> args) async {
    calls.add(args);
    final attempt = args['attempt'] as int;
    _progress.add(CompressionProgress(attempt: attempt, percent: 50, state: 'running'));
    if (throwCode != null) throw CompressionException(throwCode!, 'x');
    return {
      'outputPath': '/cache/cf_compress/cf_1_a$attempt.mp4',
      'outputSizeBytes': sizes[attempt - 1],
      'outputWidth': 1280,
      'outputHeight': 720,
      'outputDurationMs': 300000,
      'elapsedMs': 1000,
      'averageVideoBitrate': 2400000,
    };
  }

  @override
  Stream<CompressionProgress> get progress => _progress.stream;

  @override
  Future<bool> deleteOutput(String path) async {
    deleted.add(path);
    return true;
  }

  @override
  Future<String?> pickVideo() async => null;
  @override
  Future<VideoInfo> getVideoInfo(String uri) => throw UnimplementedError();
  @override
  Future<bool> cancel() async => true;
  @override
  Future<int> deleteAllOutputs() async {
    deleteAllCalls++;
    return 0;
  }

  @override
  Future<String> tempDirectory() async => '/cache/cf_compress';
  @override
  Future<int> availableTempBytes() async => freeBytes;
  @override
  Future<({String path, int sizeBytes})> copySourceToTemp(String uri,
      {int expectedBytes = -1}) async {
    if (copyThrowCode != null) throw CompressionException(copyThrowCode!, 'x');
    copies.add(uri);
    return (path: '/cache/cf_compress/cf_1_src.mp4', sizeBytes: expectedBytes);
  }
  @override
  Future<String> saveCopyToMovies(String path) async => 'content://x';
}

const source = VideoInfo(
  uri: 'content://test/1',
  sizeBytes: 500 * kMiB,
  durationMs: 300000,
  width: 1920,
  height: 1080,
  frameRate: 30,
);

void main() {
  test('success on first attempt: no retry, nothing deleted', () async {
    final fake = FakePlatform([88 * kMiB]);
    final c = CfVideoCompressor(platform: fake);
    final events = <CompressionProgress>[];
    final r = await c.compress(source, c.plan(source), onProgress: events.add);
    expect(r.outcome, CompressionOutcome.success);
    expect(r.attempts, hasLength(1));
    expect(fake.deleted, isEmpty);
    expect(r.finalAttempt!.underHardLimit, isTrue);
    expect(r.finalAttempt!.overallBitrate, (88 * kMiB * 8 / 300).round());
    expect(events.single.percent, 50);
  });

  test('exactly 95 MiB counts as under the limit', () async {
    final r = await CfVideoCompressor(platform: FakePlatform([99614720]))
        .compress(source, const CompressionPlanner().plan(source));
    expect(r.outcome, CompressionOutcome.success);
  });

  test('over limit -> one retry at 85 %, first output deleted', () async {
    final fake = FakePlatform([99614721, 86 * kMiB]);
    final c = CfVideoCompressor(platform: fake);
    final plan = c.plan(source);
    final r = await c.compress(source, plan);
    expect(r.outcome, CompressionOutcome.success);
    expect(r.attempts, hasLength(2));
    expect(r.attempts.first.deleted, isTrue);
    expect(fake.deleted, ['/cache/cf_compress/cf_1_a1.mp4']);
    expect(fake.calls[1]['videoBitrate'], (plan.videoBitrate * 0.85).floor());
    expect(fake.calls[1]['attempt'], 2);
    expect(fake.calls[0]['requiredBytes'], 99614720 + 32 * kMiB);
  });

  test('still over after retry -> overLimit, never a third attempt', () async {
    final fake = FakePlatform([100 * kMiB, 97 * kMiB]);
    final c = CfVideoCompressor(platform: fake);
    final r = await c.compress(source, c.plan(source));
    expect(r.outcome, CompressionOutcome.overLimit);
    expect(fake.calls, hasLength(2));
    expect(fake.deleted, hasLength(2));
  });

  test('cancel is reported, not thrown', () async {
    final c = CfVideoCompressor(platform: FakePlatform([], throwCode: 'CANCELLED'));
    final r = await c.compress(source, c.plan(source));
    expect(r.outcome, CompressionOutcome.cancelled);
    expect(r.errorCode, 'CANCELLED');
  });

  test('encoder failure is reported, not thrown', () async {
    final c =
        CfVideoCompressor(platform: FakePlatform([], throwCode: 'EXPORT_FAILED'));
    final r = await c.compress(source, c.plan(source));
    expect(r.outcome, CompressionOutcome.failed);
  });
}
