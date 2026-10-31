import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../core/app_colors.dart';

class PrivacyPolicyScreen extends ConsumerWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEn = ref.watch(settingsProvider).localeCode == 'en';
    final palette = context.palette;
    return Scaffold(
      appBar: AppBar(title: Text(isEn ? 'Privacy policy' : 'Политика конфиденциальности')),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [palette.background, palette.background],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
          children: [
            _section(
              context,
              isEn ? 'Short version' : 'Коротко',
              isEn
                  ? 'Coralink is built so that your conversations belong to you. Messages are end-to-end encrypted, history lives on your device, and the server only relays ciphertext and minimal metadata.'
                  : 'Coralink устроен так, чтобы разговоры принадлежали тебе. Сообщения защищены сквозным шифрованием, история хранится на устройстве, а сервер лишь передаёт шифротекст и минимум метаданных.',
            ),
            _section(
              context,
              isEn ? 'What the server sees' : 'Что видит сервер',
              isEn
                  ? 'Your phone number and display name, a public key bundle, the fact that a message was sent between two accounts (without content), delivery timestamps and push tokens if enabled. Messages are opaque ciphertext.'
                  : 'Твой номер телефона и имя, публичные ключи, факт отправки сообщения между двумя аккаунтами (без содержимого), отметки доставки и push-токены при их включении. Содержимое сообщений — непрозрачный шифротекст.',
            ),
            _section(
              context,
              isEn ? 'What stays on your device' : 'Что остаётся на устройстве',
              isEn
                  ? 'Message history, decrypted media, private identity keys and ratchet state. On Android/iOS the database is encrypted with SQLCipher, and keys live in the system Keychain/Keystore.'
                  : 'История сообщений, расшифрованные медиа, приватные ключи и состояние ratchet. На Android/iOS база шифруется SQLCipher, ключи хранятся в системном Keychain/Keystore.',
            ),
            _section(
              context,
              isEn ? 'Your controls' : 'Твои права',
              isEn
                  ? 'You can clear the local cache, export your chats, switch notification modes, or sign out and delete local data at any time. The demo server keeps queued ciphertext for at most 7 days.'
                  : 'Ты можешь очистить локальный кэш, экспортировать чаты, выбрать режим уведомлений или выйти и удалить локальные данные в любой момент. Демо-сервер хранит очередь шифротекста не дольше 7 дней.',
            ),
            _section(
              context,
              isEn ? 'No tracking' : 'Без слежки',
              isEn
                  ? 'Coralink does not include advertising SDKs or third-party analytics. Notifications are generated locally. The web build keeps chats in memory only.'
                  : 'В Coralink нет рекламных SDK и сторонней аналитики. Уведомления формируются локально. Веб-версия хранит чаты только в памяти.',
            ),
            const SizedBox(height: 20),
            Text(
              isEn ? 'Version 1.0 · 2026' : 'Версия 1.0 · 2026',
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, String body) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(color: palette.textMuted, fontSize: 14, height: 1.55),
          ),
        ],
      ),
    );
  }
}
