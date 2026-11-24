import 'dart:async';
import 'dart:convert';

import 'package:coralink/core/config.dart';
import 'package:coralink/data/api_client.dart';
import 'package:coralink/data/local_store_memory.dart';
import 'package:coralink/data/secure_store.dart';
import 'package:coralink/network/p2p.dart';
import 'package:coralink/network/realtime.dart';
import 'package:coralink/domain/pet.dart';
import 'package:coralink/security/group_crypto.dart';
import 'package:coralink/security/signal_service.dart';
import 'package:coralink/services/message_service.dart';
import 'package:coralink/services/pet_service.dart';
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
    required this.groupCrypto,
    required this.realtime,
    required this.p2p,
    required this.messages,
    required this.pets,
    required this.store,
    required this.userId,
    required this.token,
  });

  final ApiClient api;
  final SignalService signal;
  final GroupCrypto groupCrypto;
  final RealtimeService realtime;
  final P2PManager p2p;
  final MessageService messages;
  final PetService pets;
  final MemoryLocalStore store;
  final String userId;
  final String token;

  Future<void> dispose() async {
    await pets.dispose();
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
  final auth = await api.register(
    username,
    password: 'test-password-123',
    name: username,
  );
  final secure = FakeSecureStore();
  final store = MemoryLocalStore();
  final signal = await SignalService.load(
    secure: secure,
    api: api,
    userId: auth.user.id,
  );
  final realtime = RealtimeService(config.wsUrl, auth.token);
  final p2p = P2PManager(config, realtime);
  final groupCrypto = GroupCrypto(secure);
  final messages = MessageService(
    store: store,
    api: api,
    signal: signal,
    groupCrypto: groupCrypto,
    realtime: realtime,
    p2p: p2p,
    myId: auth.user.id,
  );
  final pets = PetService(
    store: store,
    api: api,
    secure: secure,
    groupCrypto: groupCrypto,
    messages: messages,
    realtime: realtime,
    myId: auth.user.id,
    onKeysChanged: () {},
  );
  await realtime.connect();
  await messages.syncQueue();
  messages.start();
  return TestClient(
    api: api,
    signal: signal,
    groupCrypto: groupCrypto,
    realtime: realtime,
    p2p: p2p,
    messages: messages,
    pets: pets,
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
    skip: !serverUp
        ? 'Coralink server is not running on 127.0.0.1:8080'
        : false,
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
      final incomingAtBob = bob.messages.incoming.first.timeout(
        const Duration(seconds: 15),
      );
      await alice.messages.sendText(bob.userId, 'Привет, Боб! Это Алиса.');
      final bobEvent = await incomingAtBob;
      expect(bobEvent.message.text, 'Привет, Боб! Это Алиса.');
      expect(bobEvent.message.senderId, alice.userId);
      expect(bobEvent.message.status.name, isNot('sending'));

      // B -> A, proving the ratchet works in both directions.
      final incomingAtAlice = alice.messages.incoming.first.timeout(
        const Duration(seconds: 15),
      );
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
      expect(
        utf8.decode(rawBytes, allowMalformed: true).contains('Секретное'),
        isFalse,
      );

      // Bob reconnects through a fresh transport and syncs the queue.
      final config = _config();
      final realtime2 = RealtimeService(config.wsUrl, bob.token);
      final p2p2 = P2PManager(config, realtime2);
      final messages2 = MessageService(
        store: bob.store,
        api: bob.api,
        signal: bob.signal,
        groupCrypto: bob.groupCrypto,
        realtime: realtime2,
        p2p: p2p2,
        myId: bob.userId,
      );
      addTearDown(() async {
        await messages2.dispose();
        await p2p2.dispose();
        await realtime2.dispose();
      });
      final synced = messages2.incoming.first.timeout(
        const Duration(seconds: 20),
      );
      messages2.start();
      await realtime2.connect();
      await messages2.syncQueue();
      final syncedEvent = await synced;
      expect(syncedEvent.message.text, 'Секретное офлайн-сообщение');

      final stored = await bob.store.getMessages(alice.userId);
      expect(stored.any((m) => m.text == 'Секретное офлайн-сообщение'), isTrue);
    },
  );

  test(
    'two clients exchange a group message end-to-end',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final suffix = DateTime.now().millisecondsSinceEpoch % 1000000000;
      final alice = await _connect('ga$suffix');
      final bob = await _connect('gb$suffix');
      addTearDown(() async {
        await alice.dispose();
        await bob.dispose();
      });

      final group = await alice.messages.createGroup(
        title: 'Coral Crew',
        memberIds: [bob.userId],
      );

      // Bob receives the group key over the 1-на-1 channel and registers the
      // chat as a group.
      var joined = false;
      for (var i = 0; i < 50 && !joined; i++) {
        final chat = await bob.store.getChat(group.id);
        if (chat != null && chat.isGroup) joined = true;
        if (!joined)
          await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(
        joined,
        isTrue,
        reason: 'bob should receive the group key and join',
      );

      final incoming = bob.messages.incoming
          .firstWhere((e) => e.message.text == 'Привет, группа!')
          .timeout(const Duration(seconds: 15));
      await alice.messages.sendText(group.id, 'Привет, группа!');
      final event = await incoming;
      expect(event.message.senderId, alice.userId);
      expect(event.message.chatId, group.id);
    },
  );

  test(
    'personal Tamagotchi persists care through the server',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final suffix = DateTime.now().millisecondsSinceEpoch % 1000000000;
      final alice = await _connect('pa$suffix');
      addTearDown(alice.dispose);
      final chatId = 'personal:${alice.userId}';
      final created = await alice.pets.create(
        chatId: chatId,
        species: PetSpecies.lotus,
        name: 'Lagoon',
        personal: true,
      );
      expect(created.state?.name, 'Lagoon');
      await alice.pets.care(chatId, PetAction.feed);
      final refreshed = await alice.pets.find(chatId);
      expect(refreshed?.state?.xp, 3);
      expect(refreshed?.state?.caretakers[alice.userId], 1);
    },
  );

  test(
    'direct Tamagotchi invitation, acceptance and concurrent care stay in sync',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final suffix = DateTime.now().millisecondsSinceEpoch % 1000000000;
      final alice = await _connect('da$suffix');
      final bob = await _connect('db$suffix');
      addTearDown(() async {
        await alice.dispose();
        await bob.dispose();
      });
      await alice.messages.ensureChat(bob.userId);
      await bob.messages.ensureChat(alice.userId);
      final created = await alice.pets.create(
        chatId: bob.userId,
        species: PetSpecies.coral,
        name: 'Pair Reef',
      );
      expect(created.isPending, isTrue);
      await bob.messages.petKeyEvents.first.timeout(
        const Duration(seconds: 20),
      );
      final invitation = await bob.pets.find(alice.userId);
      expect(invitation?.isPending, isTrue);
      await bob.pets.accept(invitation!.id);
      await alice.pets.care(bob.userId, PetAction.feed);
      await bob.pets.care(alice.userId, PetAction.play);
      final aliceState = await alice.pets.find(bob.userId);
      final bobState = await bob.pets.find(alice.userId);
      expect(aliceState?.state?.xp, 8);
      expect(bobState?.state?.xp, 8);
      expect(aliceState?.state?.caretakers[alice.userId], 1);
      expect(bobState?.state?.caretakers[bob.userId], 1);
    },
  );

  test(
    'group Tamagotchi is shared by every member',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      final suffix = DateTime.now().millisecondsSinceEpoch % 1000000000;
      final alice = await _connect('gpa$suffix');
      final bob = await _connect('gpb$suffix');
      addTearDown(() async {
        await alice.dispose();
        await bob.dispose();
      });
      final group = await alice.messages.createGroup(
        title: 'Pet Crew',
        memberIds: [bob.userId],
      );
      var joined = false;
      for (var i = 0; i < 50 && !joined; i++) {
        final chat = await bob.store.getChat(group.id);
        joined = chat?.isGroup == true;
        if (!joined)
          await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(joined, isTrue);
      await alice.pets.create(
        chatId: group.id,
        species: PetSpecies.turtle,
        name: 'Shell',
      );
      await bob.pets.find(group.id);
      await alice.pets.care(group.id, PetAction.feed);
      await bob.pets.care(group.id, PetAction.care);
      final state = await bob.pets.find(group.id);
      expect(state?.state?.xp, 5);
      expect(state?.state?.caretakers, containsPair(alice.userId, 1));
      expect(state?.state?.caretakers, containsPair(bob.userId, 1));
    },
  );
}
