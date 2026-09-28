import 'package:cf_video_compressor/cf_video_compressor.dart';
import 'package:flutter_test/flutter_test.dart';

VideoInfo video({
  int minutes = 0,
  int seconds = 0,
  int width = 1920,
  int height = 1080,
  int rotation = 0,
  double? fps = 30,
  int sizeBytes = 400 * kMiB,
  bool hasAudio = true,
  int? colorTransfer,
}) =>
    VideoInfo(
      uri: 'content://test/1',
      sizeBytes: sizeBytes,
      durationMs: (minutes * 60 + seconds) * 1000,
      width: width,
      height: height,
      rotationDegrees: rotation,
      frameRate: fps,
      hasAudio: hasAudio,
      colorTransfer: colorTransfer,
    );

void main() {
  const planner = CompressionPlanner();

  group('limits', () {
    test('budget and hard limit are exact', () {
      const c = PlannerConfig();
      expect(c.targetBytes, 94371840);
      expect(c.hardLimitBytes, 99614720);
      expect(c.audioBitrate, 64000);
    });

    test('720p holds up to ~11:42, 540p floor up to ~18:45', () {
      expect(planner.maxDurationMsFor(1000000), 702467);
      expect(planner.maxDurationMsFor(600000), 1125640);
    });
  });

  group('bitrate ladder', () {
    test('2 min -> capped at 3 Mbps, 720p', () {
      final p = planner.plan(video(minutes: 2));
      expect(planner.budgetVideoBitrate(120000), 6164541);
      expect(p.videoBitrate, 3000000);
      expect(p.targetShortSide, 720);
      expect(p.status, PlanStatus.ok);
      expect(p.estimatedOutputBytes, lessThan(50 * kMiB));
    });

    test('5 min -> ~2.43 Mbps, 720p', () {
      final p = planner.plan(video(minutes: 5));
      expect(p.videoBitrate, 2427416);
      expect(p.targetShortSide, 720);
    });

    test('10 min -> ~1.18 Mbps, 720p', () {
      final p = planner.plan(video(minutes: 10));
      expect(p.videoBitrate, 1181708);
      expect(p.targetShortSide, 720);
    });

    test('12 min -> ~0.97 Mbps, 540p', () {
      final p = planner.plan(video(minutes: 12));
      expect(p.videoBitrate, 974090);
      expect(p.targetShortSide, 540);
      expect(p.status, PlanStatus.ok);
    });

    test('15 min -> ~0.77 Mbps, 540p', () {
      final p = planner.plan(video(minutes: 15));
      expect(p.videoBitrate, 766472);
      expect(p.targetShortSide, 540);
    });

    test('20 min -> below the 0.6 Mbps floor', () {
      final p = planner.plan(video(minutes: 20));
      expect(p.videoBitrate, 558854);
      expect(p.status, PlanStatus.belowFloor);
    });

    test('estimated output stays within the 90 MiB budget', () {
      // (Below ~4 min the 3 Mbps quality cap applies, so less is used.)
      for (final m in [5, 8, 10, 12, 15, 18]) {
        final p = planner.plan(video(minutes: m));
        expect(p.estimatedOutputBytes, lessThanOrEqualTo(p.targetBytes),
            reason: '$m min');
        expect(p.estimatedOutputBytes, greaterThan(p.targetBytes * 0.98),
            reason: '$m min uses the budget');
      }
    });

    test('no audio track -> audio bitrate 0 and more video bitrate', () {
      final p = planner.plan(video(minutes: 10, hasAudio: false));
      expect(p.audioBitrate, 0);
      expect(p.videoBitrate, 1245708);
    });
  });

  group('resolution / aspect', () {
    test('never upscales: 480p source keeps its size', () {
      final p = planner.plan(video(minutes: 5, width: 854, height: 480));
      expect(p.targetShortSide, isNull);
    });

    test('720p source at 720p tier keeps its size', () {
      final p = planner.plan(video(minutes: 5, width: 1280, height: 720));
      expect(p.targetShortSide, isNull);
    });

    test('portrait (rotated) 4K uses the short side', () {
      final v = video(minutes: 5, width: 3840, height: 2160, rotation: 90);
      expect(v.resolutionLabel, '2160x3840');
      expect(planner.plan(v).targetShortSide, 720);
    });
  });

  group('frame rate', () {
    test('60 fps -> capped at 30', () {
      expect(planner.plan(video(minutes: 5, fps: 60)).maxFrameRate, 30);
    });

    test('30 / 29.97 / 30.3 fps -> untouched', () {
      for (final f in [30.0, 29.97, 30.3, 24.0]) {
        expect(planner.plan(video(minutes: 5, fps: f)).maxFrameRate, isNull);
      }
    });

    test('unknown fps -> untouched, with a note', () {
      final p = planner.plan(video(minutes: 5, fps: null));
      expect(p.maxFrameRate, isNull);
      expect(p.notes.join(), contains('frame rate unknown'));
    });
  });

  group('retry', () {
    test('retry is 85 % of the video bitrate', () {
      final first = planner.plan(video(minutes: 5));
      final retry = planner.retryPlan(video(minutes: 5), first);
      expect(retry.attempt, 2);
      expect(retry.videoBitrate, (2427416 * 0.85).floor());
      expect(retry.targetShortSide, 720);
    });

    test('retry can drop 720p -> 540p', () {
      final v = video(minutes: 11);
      final first = planner.plan(v);
      expect(first.targetShortSide, 720);
      final retry = planner.retryPlan(v, first);
      expect(retry.videoBitrate, lessThan(1000000));
      expect(retry.targetShortSide, 540);
    });
  });

  group('misc', () {
    test('invalid duration', () {
      expect(planner.plan(video()).status, PlanStatus.invalid);
    });

    test('source already under the hard limit is flagged', () {
      final p = planner.plan(video(minutes: 2, sizeBytes: 80 * kMiB));
      expect(p.sourceAlreadyFits, isTrue);
    });

    test('HDR source is tone-mapped', () {
      final p = planner.plan(video(minutes: 3, colorTransfer: 6));
      expect(p.toneMapHdrToSdr, isTrue);
      expect(p.notes.join(), contains('HDR'));
    });

    test('platform args carry everything the encoder needs', () {
      final args = planner.plan(video(minutes: 5, fps: 60)).toPlatformArgs('u');
      expect(args, {
        'uri': 'u',
        'attempt': 1,
        'videoBitrate': 2427416,
        'audioBitrate': 64000,
        'targetShortSide': 720,
        'maxFrameRate': 30.0,
        'toneMapHdrToSdr': true,
        'bitrateMode': 'vbr',
      });
    });
  });
}
