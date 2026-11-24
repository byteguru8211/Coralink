import 'package:coralink/data/local_store_memory.dart';
import 'package:coralink/domain/models.dart';
import 'package:coralink/network/realtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('receipt events accept both ids and messageIds', () {
    expect(
      const RealtimeEvent('message.read', {
        'ids': ['a'],
      }).ids,
      ['a'],
    );
    expect(
      const RealtimeEvent('message.read', {
        'messageIds': ['b'],
      }).ids,
      ['b'],
    );
  });

  test('message status never regresses after read', () async {
    final store = MemoryLocalStore();
    final message = Message(
      id: 'm1',
      chatId: 'c1',
      senderId: 'me',
      text: 'hello',
      createdAt: DateTime(2026),
    );
    await store.upsertMessage(message);
    await store.updateMessageStatus('m1', MessageStatus.delivered);
    await store.markMessagesRead(['m1']);
    await store.updateMessageStatus('m1', MessageStatus.sent);
    expect((await store.getMessage('m1'))!.status, MessageStatus.read);
  });
}
