import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../core/strings.dart';
import '../data/local_store.dart';
import '../data/secure_store.dart';
import '../data/settings_store.dart';
import '../services/audio_service.dart';
import '../services/notification_service.dart';

final configProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError('configProvider must be overridden'),
);
final secureStoreProvider = Provider<SecureStore>(
  (ref) => throw UnimplementedError('secureStoreProvider must be overridden'),
);
final localStoreProvider = Provider<LocalStore>(
  (ref) => throw UnimplementedError('localStoreProvider must be overridden'),
);
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw UnimplementedError('settingsStoreProvider must be overridden'),
);
final audioProvider = Provider<AudioService>(
  (ref) => throw UnimplementedError('audioProvider must be overridden'),
);
final notificationProvider = Provider<NotificationService>(
  (ref) => throw UnimplementedError('notificationProvider must be overridden'),
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final settings = ref.read(settingsStoreProvider).load();
    final audio = ref.read(audioProvider);
    audio.volume = settings.volume;
    return settings;
  }

  Future<void> _update(AppSettings next) async {
    state = next;
    ref.read(audioProvider).volume = next.volume;
    await ref.read(settingsStoreProvider).save(next);
  }

  Future<void> setTheme(ThemeMode mode) =>
      _update(state.copyWith(themeMode: mode));

  Future<void> setLocale(String code) => _update(state.copyWith(localeCode: code));

  Future<void> setNotificationMode(NotificationMode mode) async {
    final notifications = ref.read(notificationProvider);
    if (mode != NotificationMode.offline) {
      await notifications.requestPermission();
    }
    await _update(state.copyWith(notificationMode: mode));
  }

  Future<void> setRustle(bool value) =>
      _update(state.copyWith(rustleSound: value));

  Future<void> setSendSound(bool value) =>
      _update(state.copyWith(sendSound: value));

  Future<void> setReceiveSound(bool value) =>
      _update(state.copyWith(receiveSound: value));

  Future<void> setVolume(double value) => _update(state.copyWith(volume: value));

  Future<void> setPrivacy(PrivacyScope scope) =>
      _update(state.copyWith(privacyScope: scope));

  Future<void> setAutoArchiveDays(int days) =>
      _update(state.copyWith(autoArchiveDays: days));
}

final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

final stringsProvider = Provider<AppStrings>((ref) {
  final settings = ref.watch(settingsProvider);
  return AppStrings(Locale(settings.localeCode));
});
