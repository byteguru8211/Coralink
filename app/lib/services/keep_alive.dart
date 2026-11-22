import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app process and radios alive while backgrounded so the WebSocket
/// stays connected and incoming messages can raise local notifications without
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

bool _configured = false;

void _configure() {
  if (_configured) return;
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'coralink_keep_alive',
      channelName: 'Coralink · background',
      channelDescription: 'Optional: keeps Coralink connected while closed',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(30000),
      // Holding the CPU and Wi-Fi radio awake is what lets the WebSocket
      // heartbeat and reconnect timers keep firing under Doze; without it the
      // socket is dropped and no notifications arrive while minimized.
      allowWakeLock: true,
      allowWifiLock: true,
      autoRunOnBoot: false,
    ),
  );
  _configured = true;
}

Future<void> startKeepAlive() async {
  if (!_supported) return;
  try {
    _configure();
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Coralink',
      notificationText: 'Coralink на связи',
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
