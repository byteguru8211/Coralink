import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app process alive while backgrounded so the WebSocket stays
/// connected and incoming messages can raise local notifications without
/// requiring Firebase push. No-op on web and non-Android platforms.
@pragma('vm:entry-point')
void _keepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

bool get _supported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<void> startKeepAlive() async {
  if (!_supported) return;
  try {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Coralink',
      notificationText: 'Coralink работает в фоне',
      serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
      callback: _keepAliveCallback,
    );
  } catch (_) {
    // Foreground service failures must never break messaging.
  }
}

Future<void> stopKeepAlive() async {
  if (!_supported) return;
  try {
    await FlutterForegroundTask.stopService();
  } catch (_) {}
}
