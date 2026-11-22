import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_service.dart';

enum NotificationMode { minimal, medium, advanced, offline }

enum PrivacyScope { everyone, contacts, nobody }

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.localeCode = 'ru',
    this.notificationMode = NotificationMode.medium,
    this.presenceSoundId = 'rustle',
    this.sendSoundId = 'drop',
    this.receiveSoundId = 'splash',
    this.callSoundId = 'bell',
    this.volume = 0.7,
    this.privacyScope = PrivacyScope.contacts,
    this.autoArchiveDays = 7,
    this.serverUrl = '',
    this.backgroundAlive = false,
    this.trayClose = true,
  });

  final ThemeMode themeMode;
  final String localeCode;
  final NotificationMode notificationMode;

  /// Sound chosen for each cue. An empty string means "no sound".
  final String presenceSoundId;
  final String sendSoundId;
  final String receiveSoundId;
  final String callSoundId;

  final double volume;
  final PrivacyScope privacyScope;
  final int autoArchiveDays;
  final String serverUrl;

  /// Android: keep a foreground service so messages arrive while the app is
  /// backgrounded. Off by default — it shows a permanent notification.
  final bool backgroundAlive;

  /// Windows: the close button hides the window to the tray instead of quitting.
  final bool trayClose;

  String soundIdFor(SoundCue cue) => switch (cue) {
        SoundCue.presence => presenceSoundId,
        SoundCue.send => sendSoundId,
        SoundCue.receive => receiveSoundId,
        SoundCue.call => callSoundId,
      };

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? localeCode,
    NotificationMode? notificationMode,
    String? presenceSoundId,
    String? sendSoundId,
    String? receiveSoundId,
    String? callSoundId,
    double? volume,
    PrivacyScope? privacyScope,
    int? autoArchiveDays,
    String? serverUrl,
    bool? backgroundAlive,
    bool? trayClose,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        localeCode: localeCode ?? this.localeCode,
        notificationMode: notificationMode ?? this.notificationMode,
        presenceSoundId: presenceSoundId ?? this.presenceSoundId,
        sendSoundId: sendSoundId ?? this.sendSoundId,
        receiveSoundId: receiveSoundId ?? this.receiveSoundId,
        callSoundId: callSoundId ?? this.callSoundId,
        volume: volume ?? this.volume,
        privacyScope: privacyScope ?? this.privacyScope,
        autoArchiveDays: autoArchiveDays ?? this.autoArchiveDays,
        serverUrl: serverUrl ?? this.serverUrl,
        backgroundAlive: backgroundAlive ?? this.backgroundAlive,
        trayClose: trayClose ?? this.trayClose,
      );

  Map<String, dynamic> toJson() => {
        'theme': themeMode.name,
        'locale': localeCode,
        'notification': notificationMode.name,
        'presenceSoundId': presenceSoundId,
        'sendSoundId': sendSoundId,
        'receiveSoundId': receiveSoundId,
        'callSoundId': callSoundId,
        'volume': volume,
        'privacy': privacyScope.name,
        'autoArchiveDays': autoArchiveDays,
        'serverUrl': serverUrl,
        'backgroundAlive': backgroundAlive,
        'trayClose': trayClose,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        themeMode: ThemeMode.values.firstWhere(
          (mode) => mode.name == json['theme'],
          orElse: () => ThemeMode.dark,
        ),
        localeCode: (json['locale'] as String?) ?? 'ru',
        notificationMode: NotificationMode.values.firstWhere(
          (mode) => mode.name == json['notification'],
          orElse: () => NotificationMode.medium,
        ),
        presenceSoundId: _soundId(json, 'presenceSoundId', 'rustle', 'rustle'),
        sendSoundId: _soundId(json, 'sendSoundId', 'sendSound', 'drop'),
        receiveSoundId:
            _soundId(json, 'receiveSoundId', 'receiveSound', 'splash'),
        callSoundId: _soundId(json, 'callSoundId', null, 'bell'),
        volume: ((json['volume'] as num?) ?? 0.7).toDouble(),
        privacyScope: PrivacyScope.values.firstWhere(
          (scope) => scope.name == json['privacy'],
          orElse: () => PrivacyScope.contacts,
        ),
        autoArchiveDays: (json['autoArchiveDays'] as num?)?.toInt() ?? 7,
        serverUrl: (json['serverUrl'] as String?) ?? '',
        backgroundAlive: json['backgroundAlive'] == true,
        trayClose: json['trayClose'] != false,
      );

  /// Reads a per-cue sound id, falling back to the old boolean toggles so an
  /// upgrade keeps the user's previous on/off choice.
  static String _soundId(
    Map<String, dynamic> json,
    String key,
    String? legacyKey,
    String fallback,
  ) {
    final value = json[key];
    if (value is String) return value;
    if (legacyKey != null) {
      final legacy = json[legacyKey];
      if (legacy is bool) return legacy ? fallback : '';
    }
    return fallback;
  }
}

class SettingsStore {
  SettingsStore(this._prefs);
  final SharedPreferences _prefs;
  static const _key = 'coralink.settings.v1';

  AppSettings load() {
    final raw = _prefs.getString(_key);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) =>
      _prefs.setString(_key, jsonEncode(settings.toJson()));
}
