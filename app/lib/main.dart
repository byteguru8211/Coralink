import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/dependencies.dart';
import 'core/config.dart';
import 'data/local_store_opener.dart';
import 'data/secure_store.dart';
import 'data/settings_store.dart';
import 'services/audio_service.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.resolve();
  final secure = SecureStore();
  final store = await openLocalStore(secure);
  final prefs = await SharedPreferences.getInstance();
  final settingsStore = SettingsStore(prefs);
  final audio = AudioService();
  final notifications = NotificationService();
  await notifications.init();

  runApp(
    ProviderScope(
      overrides: [
        configProvider.overrideWithValue(config),
        secureStoreProvider.overrideWithValue(secure),
        localStoreProvider.overrideWithValue(store),
        settingsStoreProvider.overrideWithValue(settingsStore),
        audioProvider.overrideWithValue(audio),
        notificationProvider.overrideWithValue(notifications),
      ],
      child: const CoralinkApp(),
    ),
  );
}
