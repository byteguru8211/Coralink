import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app_colors.dart';
import '../core/log.dart';
import '../data/settings_store.dart';

/// Three notification modes: standard, silent and off. Android channels carry
/// the behavioural difference; iOS uses interruption levels where available.
///
/// Channel ids carry a version suffix on purpose: Android freezes a channel's
/// importance/sound the first time it is created, and a channel created by an
/// older build can stay silent forever even after the app changes its settings.
/// New ids guarantee the announced behaviour for every mode.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  void Function(String chatId)? onOpenChat;
  String? pendingChatId;

  String? consumePendingChat() {
    final value = pendingChatId;
    pendingChatId = null;
    return value;
  }

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  static const _appUserModelId = 'com.coralink.app';
  static const _windowsGuid = '7c1f2a4b-9d3e-4c58-8a61-2b0f5e7d9c13';

  static const _minimalChannelId = 'coralink_silent_v3';
  static const _mediumChannelId = 'coralink_standard_v3';
  static const _callChannelId = 'coralink_calls_v3';

  static const _minimalChannel = AndroidNotificationChannel(
    _minimalChannelId,
    'Coralink · без звука',
    description: 'Уведомления без звука',
    importance: Importance.high,
    playSound: false,
    enableVibration: true,
    enableLights: false,
  );

  static const _mediumChannel = AndroidNotificationChannel(
    _mediumChannelId,
    'Coralink · со звуком',
    description: 'Звук и вибрация',
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
    enableLights: false,
  );

  static const _callChannel = AndroidNotificationChannel(
    _callChannelId,
    'Coralink · звонки',
    description: 'Входящие звонки',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
    enableLights: false,
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
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: android,
          iOS: ios,
          windows: windows,
        ),
        onDidReceiveNotificationResponse: (response) {
          final chatId = response.payload;
          if (chatId != null &&
              chatId.isNotEmpty &&
              chatId != 'coralink-test') {
            onOpenChat?.call(chatId);
          }
        },
      );
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final payload = launchDetails!.notificationResponse?.payload;
        if (payload != null &&
            payload.isNotEmpty &&
            payload != 'coralink-test') {
          pendingChatId = payload;
        }
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        final androidPlugin = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await androidPlugin?.createNotificationChannel(_minimalChannel);
        await androidPlugin?.createNotificationChannel(_mediumChannel);
        await androidPlugin?.createNotificationChannel(_callChannel);
      }
      _ready = true;
    } catch (error) {
      // A notification failure must never take messaging down with it.
      Log.e('notifications.init', error);
    }
  }

  Future<bool> areEnabled() async {
    if (!_supported) return false;
    if (!_ready) await init();
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >()
                ?.areNotificationsEnabled() ??
            false;
      } catch (error) {
        Log.e('notifications.enabled', error);
        return false;
      }
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final options = await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.checkPermissions();
      return options?.isEnabled ?? false;
    }
    return true;
  }

  /// Asks the system for permission. Safe to call repeatedly: Android only
  /// shows the dialog while the user has not answered yet.
  Future<bool> requestPermission() async {
    if (!_supported) return true;
    if (!_ready) await init();
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final androidPlugin = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        if (await androidPlugin?.areNotificationsEnabled() == true) return true;
        final granted =
            await androidPlugin?.requestNotificationsPermission() ?? false;
        return granted || (await areEnabled());
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final granted =
            await _plugin
                .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin
                >()
                ?.requestPermissions(alert: true, badge: true, sound: true) ??
            false;
        return granted;
      }
      return true;
    } catch (error) {
      Log.e('notifications.permission', error);
      return false;
    }
  }

  /// Opens the system notification settings for this app, so a user who denied
  /// the permission once can still turn banners back on.
  Future<void> openSystemSettings() async {
    try {
      await openAppSettings();
    } catch (error) {
      Log.e('notifications.openSettings', error);
    }
  }

  Future<void> show({
    required String chatId,
    required String title,
    required String body,
    required NotificationMode mode,
  }) async {
    if (!_ready || mode == NotificationMode.offline) return;
    final details = _detailsFor(mode, body);
    // One live notification per conversation: a new message replaces the
    // previous banner instead of stacking a pile of separate notifications.
    try {
      await _plugin.show(
        id: chatId.hashCode & 0x7fffffff,
        title: title,
        body: body,
        payload: chatId,
        notificationDetails: NotificationDetails(
          android: details,
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: mode != NotificationMode.minimal,
          ),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } catch (error) {
      Log.e('notifications.show', error);
    }
  }

  /// Fires a notification with the current mode so the user can verify their
  /// choice immediately, without waiting for a message.
  Future<void> showTest(NotificationMode mode) {
    final english =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'en';
    return show(
      chatId: 'coralink-test',
      title: english ? 'Coralink is listening' : 'Coralink на связи',
      body: english
          ? 'This is how a new message will look. You can close it.'
          : 'Так будет выглядеть новое сообщение. Можно закрыть.',
      mode: mode,
    );
  }

  AndroidNotificationDetails _detailsFor(NotificationMode mode, String body) =>
      switch (mode) {
        NotificationMode.minimal => AndroidNotificationDetails(
          _minimalChannelId,
          'Coralink · без звука',
          channelDescription: 'Уведомления без звука',
          importance: Importance.high,
          priority: Priority.high,
          playSound: false,
          enableVibration: true,
          enableLights: false,
          color: BrandColors.emerald,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          styleInformation: BigTextStyleInformation(body),
        ),
        _ => AndroidNotificationDetails(
          _mediumChannelId,
          'Coralink · со звуком',
          channelDescription: 'Звук и вибрация',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          enableLights: false,
          color: BrandColors.emerald,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          styleInformation: BigTextStyleInformation(body),
        ),
      };

  Future<void> showCall({required String peerId, required String name}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: 256,
        title: name,
        body: 'Входящий звонок',
        payload: 'call:$peerId',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _callChannelId,
            'Coralink · звонки',
            channelDescription: 'Входящие звонки',
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            enableLights: false,
            color: BrandColors.emerald,
            category: AndroidNotificationCategory.call,
            visibility: NotificationVisibility.public,
            fullScreenIntent: true,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
            interruptionLevel: InterruptionLevel.timeSensitive,
          ),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } catch (error) {
      Log.e('notifications.call', error);
    }
  }

  Future<void> cancelCall() => _plugin.cancel(id: 256);

  Future<void> cancelAll() => _plugin.cancelAll();
}
