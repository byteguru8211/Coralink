import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'voice_recorder.dart';

VoiceRecorder create() => _IoVoiceRecorder();

class _IoVoiceRecorder implements VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  String? _path;
  int _startedAt = 0;

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    _path = p.join(
      dir.path,
      'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: _path!);
    _startedAt = DateTime.now().millisecondsSinceEpoch;
  }

  @override
  Future<VoiceRecording> stop() async {
    final stopped = await _rec.stop();
    final durationMs = DateTime.now().millisecondsSinceEpoch - _startedAt;
    final file = File(stopped ?? _path!);
    final bytes = await file.readAsBytes();
    return VoiceRecording(
      bytes: bytes,
      mimeType: 'audio/mp4a-latm',
      durationMs: durationMs,
    );
  }

  @override
  Future<void> cancel() async {
    await _rec.stop();
  }

  @override
  Future<void> dispose() async {
    await _rec.dispose();
  }
}
