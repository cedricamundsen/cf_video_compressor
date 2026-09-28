import 'package:cf_video_compressor/cf_video_compressor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'compressor_test.dart' show FakePlatform;

VideoInfo src({int sizeMiB = 200, int seconds = 180, int? sizeBytes}) => VideoInfo(
      uri: 'content://media/1',
      sizeBytes: sizeBytes ?? sizeMiB * kMiB,
      durationMs: seconds * 1000,
      width: 1920,
      height: 1080,
      frameRate: 30,
      videoMime: 'video/hevc',
    );

AnalysisVideoPreparer preparer(FakePlatform fake, [List<String>? log]) =>
    AnalysisVideoPreparer(
      compressor: CfVideoCompressor(platform: fake),
      log: log?.add,
    );

void main() {
  group('decide', () {
    final p = preparer(FakePlatform([]));

    test('<= 95 MiB -> upload original (no recompression)', () {
      final d = p.decide(src(sizeBytes: 99614720));
      expect(d.action, VideoAction.uploadOriginal);
    });

    test('200 MiB, 3 min -> compress at 720p', () {
      final d = p.decide(src());
      expect(d.action, VideoAction.compress);
      expect(d.plan!.targetShortSide, 720);
      expect(d.plan!.videoBitrate, 3000000);
    });

    test('unknown size -> compress', () {
      expect(p.decide(src(sizeBytes: -1)).action, VideoAction.compress);
    });

    test('too long -> reject tooLong', () {
      final d = p.decide(src(sizeMiB: 2000, seconds: 25 * 60));
      expect(d.action, VideoAction.reject);
      expect(d.reject, PrepareFailure.tooLong);
    });

    test('unreadable metadata and too big -> unsupportedInput', () {
      final d = p.decide(src(seconds: 0));
      expect(d.reject, PrepareFailure.unsupportedInput);
    });

    test('max supported duration ~18:45', () {
      expect(p.maxSupportedDurationMs, 1125640);
    });
  });

  group('prepare', () {
    test('small source -> streamed temp copy, no encoder call', () async {
      final fake = FakePlatform([]);
      final stages = <PrepareStage>[];
      final r = await preparer(fake)
          .prepare(src(sizeMiB: 40), onStage: stages.add);
      expect(r.compressed, isFalse);
      expect(r.sizeBytes, 40 * kMiB);
      expect(fake.calls, isEmpty);
      expect(fake.copies, ['content://media/1']);
      expect(stages, [PrepareStage.checking, PrepareStage.copying, PrepareStage.ready]);
      expect(fake.deleteAllCalls, 1, reason: 'stale temp files cleared first');
    });

    test('large source -> compressed file under the limit', () async {
      final fake = FakePlatform([60 * kMiB]);
      final log = <String>[];
      final stages = <PrepareStage>[];
      final r = await preparer(fake, log).prepare(src(), onStage: stages.add);
      expect(r.compressed, isTrue);
      expect(r.sizeBytes, 60 * kMiB);
      expect(r.path, endsWith('_a1.mp4'));
      expect(stages.last, PrepareStage.ready);
      expect(stages, contains(PrepareStage.compressing));
      expect(log.join('\n'), contains('decision compress'));
      expect(log.join('\n'), contains('attempt attempt=1'));
    });

    test('over limit twice -> stillTooLarge', () async {
      final fake = FakePlatform([100 * kMiB, 96 * kMiB]);
      await expectLater(
        preparer(fake).prepare(src()),
        throwsA(isA<PrepareException>()
            .having((e) => e.kind, 'kind', PrepareFailure.stillTooLarge)),
      );
      expect(fake.calls, hasLength(2));
    });

    test('retry succeeds -> ok', () async {
      final fake = FakePlatform([100 * kMiB, 80 * kMiB]);
      final r = await preparer(fake).prepare(src());
      expect(r.report!.retried, isTrue);
      expect(r.sizeBytes, 80 * kMiB);
    });

    test('not enough free space -> insufficientStorage before encoding', () async {
      final fake = FakePlatform([60 * kMiB], freeBytes: 50 * kMiB);
      await expectLater(
        preparer(fake).prepare(src()),
        throwsA(isA<PrepareException>()
            .having((e) => e.kind, 'kind', PrepareFailure.insufficientStorage)),
      );
      expect(fake.calls, isEmpty);
    });

    test('native error codes map to failures', () async {
      for (final (code, kind) in [
        ('NO_SPACE', PrepareFailure.insufficientStorage),
        ('UNSUPPORTED_INPUT', PrepareFailure.unsupportedInput),
        ('SOURCE_UNREADABLE', PrepareFailure.sourceUnreadable),
        ('EXPORT_FAILED', PrepareFailure.compressionFailed),
        ('CANCELLED', PrepareFailure.cancelled),
      ]) {
        await expectLater(
          preparer(FakePlatform([], throwCode: code)).prepare(src()),
          throwsA(isA<PrepareException>().having((e) => e.kind, code, kind)),
        );
      }
    });

    test('copy failure maps to failure kind', () async {
      await expectLater(
        preparer(FakePlatform([], copyThrowCode: 'NO_SPACE'))
            .prepare(src(sizeMiB: 40)),
        throwsA(isA<PrepareException>()
            .having((e) => e.kind, 'kind', PrepareFailure.insufficientStorage)),
      );
    });

    test('too long is rejected without touching temp or encoder', () async {
      final fake = FakePlatform([]);
      await expectLater(
        preparer(fake).prepare(src(sizeMiB: 2000, seconds: 25 * 60)),
        throwsA(isA<PrepareException>()
            .having((e) => e.kind, 'kind', PrepareFailure.tooLong)),
      );
      expect(fake.calls, isEmpty);
      expect(fake.deleteAllCalls, 0);
    });
  });

  test('VideoInfo survives the JSON round trip used by app state', () {
    final v = src();
    final back = VideoInfo.fromMap(v.toMap());
    expect(back.toMap(), v.toMap());
  });
}
