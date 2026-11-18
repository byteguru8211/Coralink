import 'voice_recorder_io.dart'
    if (dart.library.html) 'voice_recorder_web.dart' as impl;

class VoiceRecording {
  const VoiceRecording({
    required this.bytes,
    required this.mimeType,
    required this.durationMs,
  });
  final List<int> bytes;
  final String mimeType;
  final int durationMs;
}

/// Records a short voice note. The implementation is selected per platform so
/// the web build never pulls in `dart:io`.
abstract class VoiceRecorder {
  factory VoiceRecorder() => impl.create();

  Future<bool> hasPermission();
  Future<void> start();
  Future<VoiceRecording> stop();
  Future<void> cancel();
  Future<void> dispose();
}
