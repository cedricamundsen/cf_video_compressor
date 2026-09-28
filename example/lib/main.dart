import 'dart:async';
import 'dart:io';

import 'package:cf_video_compressor/cf_video_compressor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const PocApp());

class PocApp extends StatelessWidget {
  const PocApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CF Compress POC',
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFFE53935),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const PocHome(),
      );
}

class PocHome extends StatefulWidget {
  const PocHome({super.key});

  @override
  State<PocHome> createState() => _PocHomeState();
}

class _PocHomeState extends State<PocHome> {
  final _c = CfVideoCompressor();

  VideoInfo? _info;
  CompressionPlan? _plan;
  CompressionReport? _report;
  CompressionProgress? _progress;
  EncoderBitrateMode _mode = EncoderBitrateMode.vbr;
  bool _forceBelowFloor = false;
  bool _busy = false;
  bool _compressing = false;
  String? _message;
  String? _tempDir;
  final _wall = Stopwatch();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _c.tempDirectory().then((d) => setState(() => _tempDir = d));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() body) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await body();
    } on CompressionException catch (e) {
      _message = '${e.code}: ${e.message}';
    } catch (e) {
      _message = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() => _run(() async {
        final uri = await _c.pickVideo();
        if (uri == null) return;
        final info = await _c.getVideoInfo(uri);
        setState(() {
          _info = info;
          _plan = _c.plan(info);
          _report = null;
          _progress = null;
        });
      });

  Future<void> _compress() async {
    final info = _info, plan = _plan;
    if (info == null || plan == null) return;
    setState(() {
      _compressing = true;
      _report = null;
      _progress = null;
      _message = null;
    });
    _wall
      ..reset()
      ..start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    final report = await _c.compress(
      info,
      plan,
      bitrateMode: _mode,
      onProgress: (p) => setState(() => _progress = p),
    );
    _wall.stop();
    _ticker?.cancel();
    if (!mounted) return;
    setState(() {
      _compressing = false;
      _report = report;
    });
  }

  Future<void> _deleteAll() => _run(() async {
        final n = await _c.deleteAllOutputs();
        setState(() {
          _report = null;
          _message = 'Deleted $n temp file(s). The original was not touched.';
        });
      });

  Future<void> _saveCopy(String path) => _run(() async {
        final uri = await _c.saveCopyToMovies(path);
        setState(() => _message = 'Copy saved to Movies/CombatFlux POC ($uri)');
      });

  void _copyReport() {
    final r = _report;
    if (r == null) return;
    Clipboard.setData(ClipboardData(text: buildReportText(r, _plan!, _mode, _wall.elapsed)));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Report copied')));
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final canCompress = !_busy &&
        !_compressing &&
        plan != null &&
        plan.status != PlanStatus.invalid &&
        (plan.status == PlanStatus.ok || _forceBelowFloor);

    return Scaffold(
      appBar: AppBar(title: const Text('CombatFlux · compression POC')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          FilledButton.icon(
            onPressed: _busy || _compressing ? null : _pick,
            icon: const Icon(Icons.video_library),
            label: const Text('1. Pick a video'),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_message!, style: const TextStyle(color: Colors.amber)),
            ),
          if (_info != null) _SourceCard(info: _info!),
          if (plan != null) _PlanCard(plan: plan),
          if (plan != null) ...[
            const SizedBox(height: 8),
            SegmentedButton<EncoderBitrateMode>(
              segments: const [
                ButtonSegment(value: EncoderBitrateMode.vbr, label: Text('VBR (default)')),
                ButtonSegment(value: EncoderBitrateMode.cbr, label: Text('CBR')),
              ],
              selected: {_mode},
              onSelectionChanged:
                  _compressing ? null : (s) => setState(() => _mode = s.first),
            ),
            if (plan.status == PlanStatus.belowFloor)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Test anyway (production would reject)'),
                value: _forceBelowFloor,
                onChanged: (v) => setState(() => _forceBelowFloor = v),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: canCompress ? _compress : null,
              icon: const Icon(Icons.compress),
              label: const Text('2. Compress'),
            ),
          ],
          if (_compressing) _progressCard(),
          if (_report != null)
            _ReportCard(
              report: _report!,
              wall: _wall.elapsed,
              onCopy: _copyReport,
              onPlay: (path) => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PlayerPage(path: path))),
              onSaveCopy: _saveCopy,
            ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy || _compressing ? null : _deleteAll,
            icon: const Icon(Icons.delete_sweep),
            label: const Text('Delete all temp outputs'),
          ),
          if (_tempDir != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText('Temp dir: $_tempDir',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _progressCard() {
    final p = _progress;
    final pct = p == null || p.percent < 0 ? null : p.percent / 100;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              'Attempt ${p?.attempt ?? 1} · '
              '${pct == null ? (p?.state ?? 'starting') : '${p!.percent}%'} · '
              '${formatDuration(_wall.elapsedMilliseconds)} elapsed',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            LinearProgressIndicator(value: pct, minHeight: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _c.cancel(),
                icon: const Icon(Icons.cancel),
                label: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Rows extends StatelessWidget {
  const _Rows(this.title, this.rows);

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: t.titleMedium),
            const SizedBox(height: 8),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 150, child: Text(k, style: t.bodySmall)),
                    Expanded(child: Text(v, style: t.bodyMedium)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.info});

  final VideoInfo info;

  @override
  Widget build(BuildContext context) => _Rows('Source (read only)', [
        ('Name', info.displayName ?? '-'),
        ('Size', info.sizeBytes < 0 ? 'unknown' : formatMiB(info.sizeBytes)),
        ('Duration', formatDuration(info.durationMs)),
        ('Resolution', '${info.resolutionLabel} (coded ${info.width}x${info.height}, rot ${info.rotationDegrees}°)'),
        ('Frame rate', info.frameRate?.toStringAsFixed(2) ?? 'unknown'),
        ('Video codec', info.videoMime ?? '-'),
        ('Audio codec', info.hasAudio ? '${info.audioMime} ${info.audioChannels ?? '?'}ch ${info.audioSampleRate ?? '?'} Hz' : 'no audio'),
        ('Bitrate', '${formatMbps(info.bitrate)} total, ${formatMbps(info.videoBitrate)} video'),
        ('HDR', info.isHdr ? 'yes (transfer ${info.colorTransfer})' : 'no'),
      ]);
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan});

  final CompressionPlan plan;

  @override
  Widget build(BuildContext context) => _Rows('Plan (attempt 1)', [
        ('Status', plan.status.name),
        ('Video bitrate', formatMbps(plan.videoBitrate)),
        ('Audio', plan.audioBitrate == 0 ? 'none' : 'AAC ${plan.audioBitrate ~/ 1000} kbps'),
        ('Resolution', plan.resolutionLabel),
        ('Frame rate', plan.maxFrameRate == null ? 'unchanged' : 'max ${plan.maxFrameRate!.toStringAsFixed(0)} fps'),
        ('Estimated size', formatMiB(plan.estimatedOutputBytes)),
        ('Budget / limit', '${formatMiB(plan.targetBytes)} / ${formatMiB(plan.hardLimitBytes)} (${plan.hardLimitBytes} B)'),
        for (final n in plan.notes) ('Note', n),
      ]);
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.report,
    required this.wall,
    required this.onCopy,
    required this.onPlay,
    required this.onSaveCopy,
  });

  final CompressionReport report;
  final Duration wall;
  final VoidCallback onCopy;
  final void Function(String path) onPlay;
  final void Function(String path) onSaveCopy;

  @override
  Widget build(BuildContext context) {
    final s = report.source;
    final f = report.finalAttempt;
    final ok = report.outcome == CompressionOutcome.success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Rows('Result: ${report.outcome.name.toUpperCase()}', [
          if (report.errorCode != null) ('Error', '${report.errorCode}: ${report.errorMessage}'),
          if (report.errorCode == null && report.errorMessage != null) ('Error', report.errorMessage!),
          ('Original size', s.sizeBytes < 0 ? 'unknown' : formatMiB(s.sizeBytes)),
          ('Original resolution', s.resolutionLabel),
          ('Duration', formatDuration(s.durationMs)),
          if (f != null) ...[
            ('Output size', '${formatMiB(f.outputSizeBytes)} (${f.outputSizeBytes} B)'),
            ('Output resolution', f.resolutionLabel),
            ('Output duration', formatDuration(f.outputDurationMs)),
            ('Compression time', '${(report.totalElapsedMs / 1000).toStringAsFixed(1)} s encode, ${wall.inSeconds} s wall'),
            ('Requested bitrate', '${formatMbps(f.requestedVideoBitrate)} video + ${f.requestedAudioBitrate ~/ 1000} kbps audio'),
            ('Resulting bitrate', '${formatMbps(f.averageVideoBitrate)} video, ${formatMbps(f.averageAudioBitrate)} audio, ${formatMbps(f.overallBitrate)} overall'),
            ('Below 95 MiB', f.underHardLimit ? 'YES' : 'NO'),
            ('Retried', report.retried ? 'yes (${report.attempts.length} attempts)' : 'no'),
            ('Encoder', '${f.videoEncoderName ?? '?'} / ${f.audioEncoderName ?? '?'}'),
          ],
        ]),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy),
              label: const Text('Copy report'),
            ),
            if (ok && f != null) ...[
              FilledButton.tonalIcon(
                onPressed: () => onPlay(f.outputPath),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play output'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => onSaveCopy(f.outputPath),
                icon: const Icon(Icons.save_alt),
                label: const Text('Save copy to Movies'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Plain-text report to paste back for evaluation.
String buildReportText(
  CompressionReport r,
  CompressionPlan plan,
  EncoderBitrateMode mode,
  Duration wall,
) {
  final s = r.source;
  final b = StringBuffer()
    ..writeln('CombatFlux B0 compression report')
    ..writeln('Device: ${Platform.operatingSystemVersion}')
    ..writeln('Outcome: ${r.outcome.name}${r.errorCode != null ? ' (${r.errorCode}: ${r.errorMessage})' : ''}')
    ..writeln('Mode: ${mode.name.toUpperCase()}')
    ..writeln('--- source')
    ..writeln('Original size: ${s.sizeBytes < 0 ? 'unknown' : '${formatMiB(s.sizeBytes)} (${s.sizeBytes} B)'}')
    ..writeln('Original resolution: ${s.resolutionLabel} (coded ${s.width}x${s.height}, rotation ${s.rotationDegrees})')
    ..writeln('Duration: ${formatDuration(s.durationMs)} (${s.durationMs} ms)')
    ..writeln('Frame rate: ${s.frameRate?.toStringAsFixed(2) ?? 'unknown'}')
    ..writeln('Codecs: ${s.videoMime} / ${s.hasAudio ? s.audioMime : 'no audio'}')
    ..writeln('Source bitrate: ${formatMbps(s.bitrate)}; HDR: ${s.isHdr}')
    ..writeln('--- plan')
    ..writeln('Status: ${plan.status.name}; ${plan.resolutionLabel}; ${formatMbps(plan.videoBitrate)} video; fps cap ${plan.maxFrameRate ?? 'none'}')
    ..writeln('Estimated: ${formatMiB(plan.estimatedOutputBytes)}');
  for (final a in r.attempts) {
    b
      ..writeln('--- attempt ${a.attempt}${a.deleted ? ' (over limit, deleted)' : ''}')
      ..writeln('Output size: ${formatMiB(a.outputSizeBytes)} (${a.outputSizeBytes} B)')
      ..writeln('Output resolution: ${a.resolutionLabel} (coded ${a.outputWidth}x${a.outputHeight}, rotation ${a.outputRotationDegrees})')
      ..writeln('Output duration: ${formatDuration(a.outputDurationMs)} (${a.outputDurationMs} ms)')
      ..writeln('Output frame rate: ${a.outputFrameRate?.toStringAsFixed(2) ?? 'unknown'}')
      ..writeln('Compression time: ${(a.elapsedMs / 1000).toStringAsFixed(1)} s')
      ..writeln('Requested bitrate: ${formatMbps(a.requestedVideoBitrate)} video + ${a.requestedAudioBitrate ~/ 1000} kbps audio')
      ..writeln('Resulting bitrate: ${formatMbps(a.averageVideoBitrate)} video, ${formatMbps(a.averageAudioBitrate)} audio, ${formatMbps(a.overallBitrate)} overall')
      ..writeln('Below 95 MiB: ${a.underHardLimit ? 'YES' : 'NO'}')
      ..writeln('Encoders: ${a.videoEncoderName} / ${a.audioEncoderName} (${a.videoConversion}/${a.audioConversion})');
  }
  b.writeln('Wall time incl. retry: ${wall.inSeconds} s');
  return b.toString();
}

// ---------------------------------------------------------------------------

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.path});

  final String path;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final VideoPlayerController _v = VideoPlayerController.file(File(widget.path));
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
    _v.addListener(() => setState(() {}));
  }

  Future<void> _init() async {
    try {
      await _v.initialize();
      if (!mounted) return;
      setState(() {});
      await _v.play();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final val = _v.value;
    return Scaffold(
      appBar: AppBar(title: const Text('Compressed output')),
      body: _error != null
          ? Center(child: Text(_error!))
          : !val.isInitialized
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: val.aspectRatio,
                          child: VideoPlayer(_v),
                        ),
                      ),
                    ),
                    VideoProgressIndicator(_v, allowScrubbing: true),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          IconButton(
                            iconSize: 36,
                            onPressed: () => val.isPlaying ? _v.pause() : _v.play(),
                            icon: Icon(val.isPlaying ? Icons.pause : Icons.play_arrow),
                          ),
                          Expanded(
                            child: Text(
                              '${formatDuration(val.position.inMilliseconds)} / '
                              '${formatDuration(val.duration.inMilliseconds)} · '
                              '${val.size.width.toInt()}x${val.size.height.toInt()}',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
