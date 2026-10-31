import 'package:coralink/data/local_store_memory.dart';
import 'package:coralink/domain/models.dart';
import 'package:coralink/services/echo.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message(String id, String text, {String chat = 'bob'}) => Message(
      id: id,
      chatId: chat,
      senderId: 'bob',
      text: text,
      status: MessageStatus.read,
      createdAt: DateTime.now(),
    );

void main() {
  test('echo finds messages by synonyms', () async {
    final store = MemoryLocalStore();
    await store.upsertMessage(_message('1', 'Давай созвонимся завтра'));
    await store.upsertMessage(_message('2', 'Купил хлеб и молоко'));
    await store.upsertMessage(_message('3', 'Спасибо за помощь!'));

    final echo = EchoSearch(store);
    final hits = await echo.search('встреча');
    expect(hits, isNotEmpty);
    expect(hits.first.message.id, '1');
  });

  test('echo matches typos via trigram similarity', () async {
    final store = MemoryLocalStore();
    await store.upsertMessage(_message('1', 'Отправил документы по проекту'));
    final echo = EchoSearch(store);
    final hits = await echo.search('докумнеты');
    expect(hits, isNotEmpty);
  });

  test('echo ignores stop words and control messages', () async {
    final store = MemoryLocalStore();
    await store.upsertMessage(_message('1', 'Это просто сообщение'));
    await store.upsertMessage(Message(
      id: '2',
      chatId: 'bob',
      senderId: 'bob',
      kind: MessageKind.reaction,
      status: MessageStatus.read,
      createdAt: DateTime.now(),
    ));
    final echo = EchoSearch(store);
    final hits = await echo.search('и в на');
    expect(hits, isEmpty);
  });

  test('message row round-trip keeps reactions and metadata', () {
    final message = Message(
      id: 'm1',
      chatId: 'bob',
      senderId: 'alice',
      text: 'hello',
      kind: MessageKind.image,
      status: MessageStatus.read,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      meta: const {'mime': 'image/png'},
      imageBase64: 'AAAA',
      reactions: const {'💧': ['bob']},
      deleted: false,
    );
    final restored = Message.fromRow(message.toRow());
    expect(restored.id, message.id);
    expect(restored.kind, MessageKind.image);
    expect(restored.meta['mime'], 'image/png');
    expect(restored.reactions['💧'], ['bob']);
    expect(restored.imageBase64, 'AAAA');
  });
}
