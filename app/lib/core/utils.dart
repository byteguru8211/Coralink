import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'strings.dart';

String normalizePhone(String raw) {
  final trimmed = raw.trim();
  final hasPlus = trimmed.startsWith('+');
  final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  return hasPlus ? '+$digits' : digits;
}

bool isValidPhone(String raw) {
  final digits = normalizePhone(raw).replaceAll('+', '');
  if (digits.length < 10 || digits.length > 15) return false;
  return RegExp(r'^[1-9][0-9]+$').hasMatch(digits);
}

String maskPhone(String phone) {
  final digits = normalizePhone(phone).replaceAll('+', '');
  if (digits.length < 6) return phone;
  final head = digits.substring(0, 2);
  final tail = digits.substring(digits.length - 2);
  return '+$head *** ** $tail';
}

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return 'C';
  if (parts.length == 1) return parts.first.characters.first.toUpperCase();
  return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
}

Color colorFromHex(String hex) {
  final cleaned = hex.replaceAll('#', '');
  final value = int.tryParse(cleaned, radix: 16) ?? 0x1A9C7A;
  return Color(0xFF000000 | value);
}

String relativeDay(DateTime time, AppStrings s) {
  final now = DateTime.now();
  final local = time.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return s.get('today');
  if (diff == 1) return s.get('yesterday');
  final locale = s.locale.languageCode == 'en' ? 'en_US' : 'ru_RU';
  return DateFormat('d MMMM', locale).format(local);
}

String formatClock(DateTime time) => DateFormat('HH:mm').format(time.toLocal());

String formatChatStamp(DateTime time, AppStrings s) {
  final now = DateTime.now();
  final local = time.toLocal();
  final sameDay = now.year == local.year && now.month == local.month && now.day == local.day;
  if (sameDay) return formatClock(local);
  final yesterday = now.subtract(const Duration(days: 1));
  if (yesterday.year == local.year &&
      yesterday.month == local.month &&
      yesterday.day == local.day) {
    return s.get('yesterday');
  }
  final locale = s.locale.languageCode == 'en' ? 'en_US' : 'ru_RU';
  return DateFormat('dd.MM.yy', locale).format(local);
}

String lastSeenLabel(DateTime? lastSeen, AppStrings s) {
  if (lastSeen == null) return s.get('offline');
  final diff = DateTime.now().difference(lastSeen);
  if (diff.inMinutes < 2) return s.get('lastSeenRecently');
  if (diff.inMinutes < 60) return '${diff.inMinutes} ${s.locale.languageCode == 'en' ? 'min ago' : 'мин назад'}';
  if (diff.inHours < 24) return '${diff.inHours} ${s.locale.languageCode == 'en' ? 'h ago' : 'ч назад'}';
  return formatChatStamp(lastSeen, s);
}

String truncate(String value, int max) =>
    value.length <= max ? value : '${value.substring(0, max - 1)}…';

String pluralRu(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return few;
  return many;
}
