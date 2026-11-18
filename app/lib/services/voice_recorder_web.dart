import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'voice_recorder.dart';

VoiceRecorder create() => _WebVoiceRecorder();

class _WebVoiceRecorder implements VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();
  final List<int> _chunks = <int>[];
  StreamSubscription<Uint8List>? _sub;
  int _startedAt = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start() async {
    _chunks.clear();
    _startedAt = DateTime.now().millisecondsSinceEpoch;
    final stream = await _rec.startStream(const RecordConfig());
    _sub = stream.listen(_chunks.addAll);
  }

  @override
  Future<VoiceRecording> stop() async {
    await _rec.stop();
    await _sub?.cancel();
    _sub = null;
    final durationMs = DateTime.now().millisecondsSinceEpoch - _startedAt;
    return VoiceRecording(
      bytes: List<int>.from(_chunks),
      mimeType: 'audio/webm',
      durationMs: durationMs,
    );
  }

  @override
  Future<void> cancel() async {
    await _rec.cancel();
    await _sub?.cancel();
    _sub = null;
    _chunks.clear();
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    await _rec.dispose();
  }
}
