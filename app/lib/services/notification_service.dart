import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/app_colors.dart';
import '../data/settings_store.dart';

/// Four notification modes from the product spec. Android channels carry the
/// behavioural difference; iOS uses interruption levels where available.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  void Function(String chatId)? onOpenChat;

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  static const _appUserModelId = 'com.coralink.app';
  static const _windowsGuid = '7c1f2a4b-9d3e-4c58-8a61-2b0f5e7d9c13';

  static const _minimalChannel = AndroidNotificationChannel(
    'coralink_minimal',
    'Coralink · minimal',
    description: 'Vibration only, no sound',
    importance: Importance.low,
    playSound: false,
    enableVibration: true,
    enableLights: false,
  );

  static const _mediumChannel = AndroidNotificationChannel(
    'coralink_medium',
    'Coralink · gentle',
    description: 'Soft sound and emerald glow',
    importance: Importance.defaultImportance,
    playSound: true,
    enableVibration: true,
    enableLights: true,
    ledColor: BrandColors.emerald,
  );

  static const _advancedChannel = AndroidNotificationChannel(
    'coralink_advanced',
    'Coralink · extended',
    description: 'Heads-up notifications with sound and vibration',
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
    enableLights: true,
    ledColor: BrandColors.emerald,
  );

  Future<void> init() async {
    if (!_supported) return;
    const android = AndroidInitializationSettings('@mipmap/launcher_icon');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const windows = WindowsInitializationSettings(
      appName: 'Coralink',
      appUserModelId: _appUserModelId,
      guid: _windowsGuid,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: ios,
        windows: windows,
      ),
      onDidReceiveNotificationResponse: (response) {
        final chatId = response.payload;
        if (chatId != null && chatId.isNotEmpty) onOpenChat?.call(chatId);
      },
    );
    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(_minimalChannel);
      await androidPlugin?.createNotificationChannel(_mediumChannel);
      await androidPlugin?.createNotificationChannel(_advancedChannel);
    }
    _ready = true;
  }

  Future<bool> requestPermission() async {
    if (!_supported) return true;
    if (!_ready) await init();
    if (defaultTargetPlatform == TargetPlatform.android) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin>()
              ?.requestNotificationsPermission() ??
          false;
    }
    return await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true) ??
        false;
  }

  Future<void> show({
    required String chatId,
    required String title,
    required String body,
    required NotificationMode mode,
  }) async {
    if (!_ready || mode == NotificationMode.offline) return;
    final (channel, details) = switch (mode) {
      NotificationMode.minimal => (
          _minimalChannel,
          const AndroidNotificationDetails(
            'coralink_minimal',
            'Coralink · minimal',
            channelDescription: 'Vibration only, no sound',
            importance: Importance.low,
            priority: Priority.low,
            playSound: false,
            enableVibration: true,
            enableLights: false,
            color: BrandColors.emerald,
          ),
        ),
      NotificationMode.advanced => (
          _advancedChannel,
          const AndroidNotificationDetails(
            'coralink_advanced',
            'Coralink · extended',
            channelDescription: 'Heads-up notifications with sound and vibration',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            enableLights: true,
            ledColor: BrandColors.emerald,
            color: BrandColors.emerald,
            styleInformation: BigTextStyleInformation(''),
          ),
        ),
      _ => (
          _mediumChannel,
          const AndroidNotificationDetails(
            'coralink_medium',
            'Coralink · gentle',
            channelDescription: 'Soft sound and emerald glow',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            playSound: true,
            enableVibration: true,
            enableLights: true,
            ledColor: BrandColors.emerald,
            color: BrandColors.emerald,
          ),
        ),
    };
    // One live notification per conversation: a new message replaces the
    // previous banner instead of stacking a pile of separate notifications.
    await _plugin.show(
      id: chatId.hashCode & 0x7fffffff,
      title: title,
      body: body,
      payload: chatId,
      notificationDetails: NotificationDetails(
        android: details,
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
        windows: const WindowsNotificationDetails(),
      ),
    );
  }

  Future<void> cancelAll() => _plugin.cancelAll();
}
