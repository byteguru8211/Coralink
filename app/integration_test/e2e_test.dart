import 'dart:async';
import 'dart:convert';

import 'package:coralink/core/config.dart';
import 'package:coralink/data/api_client.dart';
import 'package:coralink/data/local_store_memory.dart';
import 'package:coralink/data/secure_store.dart';
import 'package:coralink/network/p2p.dart';
import 'package:coralink/network/realtime.dart';
import 'package:coralink/security/signal_service.dart';
import 'package:coralink/services/message_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class FakeSecureStore extends SecureStore {
  final _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<String> databaseKey() async =>
      _data.putIfAbsent('db.key', () => 'test-database-key-0123456789abcdef');
}

class TestClient {
  TestClient({
    required this.api,
    required this.signal,
    required this.realtime,
    required this.p2p,
    required this.messages,
    required this.store,
    required this.userId,
    required this.token,
  });

  final ApiClient api;
  final SignalService signal;
  final RealtimeService realtime;
  final P2PManager p2p;
  final MessageService messages;
  final MemoryLocalStore store;
  final String userId;
  final String token;

  Future<void> dispose() async {
    await p2p.dispose();
    await realtime.dispose();
    await messages.dispose();
    api.close();
  }
}

AppConfig _config() => const AppConfig(
      apiBaseUrl: 'http://127.0.0.1:8080',
      wsUrl: 'ws://127.0.0.1:8080/ws',
      devMode: true,
      stunUrl: 'stun:stun.l.google.com:19302',
    );

Future<List<IncomingMessageDto>> _waitForQueue(
  ApiClient api, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final queued = await api.queuedMessages();
    if (queued.isNotEmpty) return queued;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TimeoutException('No queued message appeared within $timeout');
}

Future<TestClient> _connect(String username) async {
  final config = _config();
  final api = ApiClient(baseUrl: config.apiBaseUrl);
  final auth = await api.identify(username, name: username);
  final secure = FakeSecureStore();
  final store = MemoryLocalStore();
  final signal = await SignalService.load(
    secure: secure,
    api: api,
    userId: auth.user.id,
  );
  final realtime = RealtimeService(config.wsUrl, auth.token);
  final p2p = P2PManager(config, realtime);
  final messages = MessageService(
    store: store,
    api: api,
    signal: signal,
    realtime: realtime,
    p2p: p2p,
    myId: auth.user.id,
  );
  await realtime.connect();
  await messages.syncQueue();
  return TestClient(
    api: api,
    signal: signal,
    realtime: realtime,
    p2p: p2p,
    messages: messages,
    store: store,
    userId: auth.user.id,
    token: auth.token,
  );
}

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  var serverUp = false;
  try {
    final api = ApiClient(baseUrl: 'http://127.0.0.1:8080');
    await api.health();
    api.close();
    serverUp = true;
  } catch (error) {
    // ignore: avoid_print
    print('E2E health check failed: $error');
  }

  test(
    'two clients exchange E2EE messages and survive an offline peer',
    skip: !serverUp ? 'Coralink server is not running on 127.0.0.1:8080' : false,
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final suffix = DateTime.now().millisecondsSinceEpoch % 1000000000;
      final nameA = 'u${suffix.toString()}';
      final nameB = 'u${((suffix + 7) % 1000000000).toString()}';

      final alice = await _connect(nameA);
      final bob = await _connect(nameB);
      addTearDown(() async {
        await alice.dispose();
        await bob.dispose();
      });
      expect(alice.realtime.status, RealtimeStatus.connected);
      expect(bob.realtime.status, RealtimeStatus.connected);

      await alice.messages.ensureChat(bob.userId);
      await bob.messages.ensureChat(alice.userId);

      // A -> B, real-time.
      final incomingAtBob = bob.messages.incoming.first
          .timeout(const Duration(seconds: 15));
      await alice.messages.sendText(bob.userId, 'Привет, Боб! Это Алиса.');
      final bobEvent = await incomingAtBob;
      expect(bobEvent.message.text, 'Привет, Боб! Это Алиса.');
      expect(bobEvent.message.senderId, alice.userId);
      expect(bobEvent.message.status.name, isNot('sending'));

      // B -> A, proving the ratchet works in both directions.
      final incomingAtAlice =
          alice.messages.incoming.first.timeout(const Duration(seconds: 15));
      await bob.messages.sendText(alice.userId, 'Привет, Алиса! Боб на связи.');
      final aliceEvent = await incomingAtAlice;
      expect(aliceEvent.message.text, 'Привет, Алиса! Боб на связи.');

      // Server-side storage must contain only ciphertext.
      await bob.realtime.dispose();
      await alice.messages.sendText(bob.userId, 'Секретное офлайн-сообщение');
      final queued = await _waitForQueue(bob.api);
      final offline = queued.last;
      expect(offline.ciphertext.contains('Секретное'), isFalse);
      final rawBytes = base64Decode(offline.ciphertext);
      expect(utf8.decode(rawBytes, allowMalformed: true).contains('Секретное'), isFalse);

      // Bob reconnects through a fresh transport and syncs the queue.
      final config = _config();
      final realtime2 = RealtimeService(config.wsUrl, bob.token);
      final p2p2 = P2PManager(config, realtime2);
      final messages2 = MessageService(
        store: bob.store,
        api: bob.api,
        signal: bob.signal,
        realtime: realtime2,
        p2p: p2p2,
        myId: bob.userId,
      );
      addTearDown(() async {
        await messages2.dispose();
        await p2p2.dispose();
        await realtime2.dispose();
      });
      final synced = messages2.incoming.first.timeout(const Duration(seconds: 20));
      await realtime2.connect();
      await messages2.syncQueue();
      final syncedEvent = await synced;
      expect(syncedEvent.message.text, 'Секретное офлайн-сообщение');

      final stored = await bob.store.getMessages(alice.userId);
      expect(stored.any((m) => m.text == 'Секретное офлайн-сообщение'), isTrue);
    },
  );
}
