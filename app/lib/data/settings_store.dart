import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum NotificationMode { minimal, medium, advanced, offline }

enum PrivacyScope { everyone, contacts, nobody }

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.localeCode = 'ru',
    this.notificationMode = NotificationMode.medium,
    this.rustleSound = true,
    this.sendSound = true,
    this.receiveSound = true,
    this.volume = 0.7,
    this.privacyScope = PrivacyScope.contacts,
    this.autoArchiveDays = 7,
  });

  final ThemeMode themeMode;
  final String localeCode;
  final NotificationMode notificationMode;
  final bool rustleSound;
  final bool sendSound;
  final bool receiveSound;
  final double volume;
  final PrivacyScope privacyScope;
  final int autoArchiveDays;

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? localeCode,
    NotificationMode? notificationMode,
    bool? rustleSound,
    bool? sendSound,
    bool? receiveSound,
    double? volume,
    PrivacyScope? privacyScope,
    int? autoArchiveDays,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        localeCode: localeCode ?? this.localeCode,
        notificationMode: notificationMode ?? this.notificationMode,
        rustleSound: rustleSound ?? this.rustleSound,
        sendSound: sendSound ?? this.sendSound,
        receiveSound: receiveSound ?? this.receiveSound,
        volume: volume ?? this.volume,
        privacyScope: privacyScope ?? this.privacyScope,
        autoArchiveDays: autoArchiveDays ?? this.autoArchiveDays,
      );

  Map<String, dynamic> toJson() => {
        'theme': themeMode.name,
        'locale': localeCode,
        'notification': notificationMode.name,
        'rustle': rustleSound,
        'sendSound': sendSound,
        'receiveSound': receiveSound,
        'volume': volume,
        'privacy': privacyScope.name,
        'autoArchiveDays': autoArchiveDays,
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
        rustleSound: json['rustle'] != false,
        sendSound: json['sendSound'] != false,
        receiveSound: json['receiveSound'] != false,
        volume: ((json['volume'] as num?) ?? 0.7).toDouble(),
        privacyScope: PrivacyScope.values.firstWhere(
          (scope) => scope.name == json['privacy'],
          orElse: () => PrivacyScope.contacts,
        ),
        autoArchiveDays: (json['autoArchiveDays'] as num?)?.toInt() ?? 7,
      );
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
