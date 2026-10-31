import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/local_store.dart';

Future<String?> exportChatsImpl(LocalStore store, String myId) async {
  final chats = await store.getChats(includeArchived: true);
  final buffer = StringBuffer()
    ..writeln('Coralink — экспорт чатов')
    ..writeln('Дата: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}')
    ..writeln('Пользователь: $myId')
    ..writeln('=' * 60)
    ..writeln();

  for (final chat in chats) {
    buffer
      ..writeln('### ${chat.peerName} (${chat.peerPhone})')
      ..writeln('Сообщений в экспорте: см. ниже')
      ..writeln('-' * 60);
    final messages = await store.getMessages(
      chat.id,
      limit: 10000,
      includeArchived: true,
    );
    for (final message in messages) {
      final who = message.senderId == myId ? 'Я' : chat.peerName;
      final time = DateFormat('yyyy-MM-dd HH:mm:ss').format(message.createdAt.toLocal());
      final body = message.deleted
          ? '[сообщение удалено]'
          : message.isImage
              ? '[фото]${message.text.isEmpty ? '' : ' ${message.text}'}'
              : message.text;
      buffer.writeln('[$time] $who: $body');
    }
    buffer
      ..writeln()
      ..writeln();
  }

  final dir = await getApplicationDocumentsDirectory();
  final name = 'coralink_export_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.txt';
  final file = File(p.join(dir.path, name));
  await file.writeAsString(buffer.toString(), flush: true);
  return file.path;
}
