import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../core/log.dart';
import '../data/api_client.dart';
import '../data/local_store.dart';
import '../data/secure_store.dart';
import '../domain/pet.dart';
import '../network/realtime.dart';
import '../security/group_crypto.dart';
import 'message_service.dart';

class PetService {
  PetService({
    required this.store,
    required this.api,
    required this.secure,
    required this.groupCrypto,
    required this.messages,
    required this.realtime,
    required this.myId,
    required this.onKeysChanged,
  }) {
    _eventSub = realtime.events.listen(_onRealtime);
    _keySub = messages.petKeyEvents.listen(_onPetKey);
    _timer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => flushOperations(),
    );
  }

  final LocalStore store;
  final ApiClient api;
  final SecureStore secure;
  final GroupCrypto groupCrypto;
  final MessageService messages;
  final RealtimeService realtime;
  final String myId;
  final void Function() onKeysChanged;

  final _updates = StreamController<PetRecord>.broadcast();
  final _uuid = const Uuid();
  final _aes = AesGcm.with256bits();
  final _lastKeySent = <String, DateTime>{};
  final _keyImports = <String, Future<void>>{};
  late final StreamSubscription<RealtimeEvent> _eventSub;
  late final StreamSubscription<PetKeyEvent> _keySub;
  late final Timer _timer;
  bool _flushing = false;
  bool _refreshing = false;
  Future<void> _snapshotTail = Future.value();

  Stream<PetRecord> get updates => _updates.stream;

  String _keyId(PetRecord record) => 'pet.key.$myId.${record.id}';

  Future<String> _createKey(PetRecord record) async {
    final random = Random.secure();
    final key = base64Encode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await secure.write(_keyId(record), key);
    onKeysChanged();
    return key;
  }

  Future<String?> _readKey(PetRecord record) async {
    final key = await secure.read(_keyId(record));
    return key == null || key.isEmpty ? null : key;
  }

  Future<String> _encrypt(PetRecord record, Map<String, dynamic> value) async {
    if (record.scope == PetScope.group) {
      return groupCrypto.encrypt(record.chatId, value);
    }
    final key = await _readKey(record);
    if (key == null) throw StateError('Missing pet key');
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(value)),
      secretKey: SecretKey(base64Decode(key)),
      nonce: nonce,
    );
    return base64Encode([...nonce, ...box.mac.bytes, ...box.cipherText]);
  }

  Future<Map<String, dynamic>> _decrypt(
    PetRecord record,
    String payload,
  ) async {
    if (record.scope == PetScope.group) {
      return groupCrypto.decrypt(record.chatId, payload);
    }
    final key = await _readKey(record);
    if (key == null) throw StateError('Missing pet key');
    final raw = base64Decode(payload);
    if (raw.length < 28) throw const FormatException('Short pet payload');
    final box = SecretBox(
      raw.sublist(28),
      nonce: raw.sublist(0, 12),
      mac: Mac(raw.sublist(12, 28)),
    );
    final clear = await _aes.decrypt(
      box,
      secretKey: SecretKey(base64Decode(key)),
    );
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Pet payload is not an object');
    }
    return decoded;
  }

  Future<PetState?> _decryptSnapshot(PetRecord record) async {
    if (record.encryptedSnapshot.isEmpty) return null;
    if (record.scope != PetScope.group && await _readKey(record) == null) {
      return null;
    }
    try {
      final envelope = await _decrypt(record, record.encryptedSnapshot);
      final raw = envelope['state'];
      return raw is Map ? PetState.fromJson(raw.cast<String, dynamic>()) : null;
    } catch (error) {
      Log.d('pet.snapshot', '$error');
      return null;
    }
  }

  Future<PetRecord> _hydrate(PetRecord serverRecord) async {
    var record = serverRecord;
    final fallback = record.state;
    var detail = await api.petDetail(record.id);
    record = detail.pet;
    var seq = record.seq;
    var state = await _decryptSnapshot(record) ?? fallback;
    var hasMore = true;
    while (hasMore) {
      for (final operation in detail.operations) {
        if (operation.seq <= seq) continue;
        try {
          final payload = await _decrypt(record, operation.payload);
          final next = _applyOperation(state, record, operation, payload);
          if (next != null && !identical(next, state)) {
            state = next;
            if (record.scope != PetScope.personal) {
              await messages.recordPetEvent(
                operationId: operation.id,
                chatId: record.localChatId(myId),
                actorId: operation.actorId,
                action: operation.action,
                state: state,
                at: operation.createdAt,
              );
            }
          }
          seq = operation.seq;
        } catch (error) {
          Log.e('pet.operation', error);
        }
      }
      hasMore = detail.hasMore;
      if (hasMore) {
        detail = await api.petDetail(record.id, afterSeq: seq);
      }
    }
    record = record.copyWith(state: state, seq: seq);
    await store.upsertPetRecord(record);
    if (record.scope == PetScope.direct && record.ownerId == myId) {
      final key = await _readKey(record);
      final last = _lastKeySent[record.id];
      if (key != null &&
          (last == null ||
              DateTime.now().difference(last) > const Duration(minutes: 5))) {
        _lastKeySent[record.id] = DateTime.now();
        unawaited(
          messages
              .sendPetKey(record.localChatId(myId), record.id, key)
              .catchError((Object error) => Log.d('pet.key.send', '$error')),
        );
      }
    }
    if (state != null && record.canCare) {
      _snapshotTail = _snapshotTail.then((_) => _saveSnapshot(record));
    }
    _updates.add(record);
    return record;
  }

  PetState? _applyOperation(
    PetState? current,
    PetRecord record,
    PetOperation operation,
    Map<String, dynamic> payload,
  ) {
    if (payload['v'] != null && payload['v'] != 1) return current;
    if (operation.action == 'reset') {
      final raw = payload['state'];
      if (raw is! Map) return current;
      return PetState.fromJson(raw.cast<String, dynamic>());
    }
    if (current == null) return null;
    switch (operation.action) {
      case 'feed':
      case 'play':
      case 'care':
      case 'sleep':
        return current
            .care(
              petActionFromId(operation.action)!,
              operation.actorId,
              operation.createdAt,
            )
            .copyWith(revision: operation.createdAt.millisecondsSinceEpoch);
      case 'rename':
        final name = payload['name'];
        if (name is! String || name.trim().isEmpty || name.trim().length > 24) {
          return current;
        }
        return current
            .rename(name, operation.createdAt)
            .copyWith(revision: operation.createdAt.millisecondsSinceEpoch);
      default:
        return current;
    }
  }

  Future<void> _saveSnapshot(PetRecord record) async {
    final state = record.state;
    if (state == null || !record.canCare) return;
    try {
      final snapshot = await _encrypt(record, {
        'v': 1,
        'state': state.toJson(),
      });
      await api.savePetSnapshot(
        petId: record.id,
        seq: record.seq,
        snapshot: snapshot,
      );
    } catch (error) {
      Log.d('pet.snapshot.sync', '$error');
    }
  }

  Future<void> refreshAll() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final records = await api.pets();
      for (final record in records) {
        await _hydrate(record);
      }
      final activeIds = records.map((record) => record.id).toSet();
      for (final local in await store.getPetRecords()) {
        if (local.id.isNotEmpty && !activeIds.contains(local.id)) {
          await store.deletePetRecord(local.id);
          _updates.add(
            local.copyWith(status: 'archived', membershipState: 'left'),
          );
        }
      }
      await flushOperations();
    } catch (error) {
      Log.e('pet.refresh', error);
    } finally {
      _refreshing = false;
    }
  }

  Future<PetRecord?> find(String chatId) async {
    final locals = await store.getPetRecords();
    for (final record in locals) {
      if (record.id.isEmpty) {
        final migrated = await _migrateLegacy(record);
        if (migrated != null && migrated.localChatId(myId) == chatId) {
          return migrated;
        }
      } else if (record.localChatId(myId) == chatId) {
        if (record.scope == PetScope.direct && await _readKey(record) == null) {
          await _keyImports[record.id];
        }
        return _hydrate(record);
      }
    }
    await refreshAll();
    final refreshed = await store.getPetRecords();
    for (final record in refreshed) {
      if (record.id.isNotEmpty && record.localChatId(myId) == chatId) {
        return record;
      }
    }
    return null;
  }

  Future<PetRecord?> _migrateLegacy(PetRecord legacy) async {
    final state = legacy.state;
    if (state == null) return null;
    try {
      final createdId = _uuid.v4();
      final record = legacy.copyWith(id: createdId);
      if (record.scope != PetScope.group) {
        await _createKey(record);
      }
      final snapshot = await _encrypt(record, {
        'v': 1,
        'state': state.toJson(),
      });
      final created = await api.createPet(
        petId: createdId,
        scope: record.scope,
        snapshot: snapshot,
        peerId: record.scope == PetScope.direct ? legacy.chatId : null,
        groupId: record.scope == PetScope.group ? legacy.chatId : null,
      );
      if (created.scope == PetScope.direct) {
        final key = await _readKey(record);
        if (key != null)
          await messages.sendPetKey(legacy.chatId, created.id, key);
      }
      return _hydrate(created);
    } catch (error) {
      Log.e('pet.migrate', error);
      return null;
    }
  }

  Future<PetRecord> create({
    required String chatId,
    required PetSpecies species,
    required String name,
    bool personal = false,
  }) async {
    final chat = personal ? null : await store.getChat(chatId);
    final scope = personal
        ? PetScope.personal
        : chat?.isGroup == true
        ? PetScope.group
        : PetScope.direct;
    final canonicalChatId = personal
        ? 'personal:$myId'
        : scope == PetScope.direct
        ? 'direct:${([myId, chatId]..sort()).join(':')}'
        : chatId;
    final now = DateTime.now();
    final state = PetState.adopt(
      chatId: canonicalChatId,
      species: species,
      name: name,
      adopterId: myId,
      now: now,
    );
    final draft = PetRecord(
      id: _uuid.v4(),
      scope: scope,
      chatId: canonicalChatId,
      ownerId: myId,
      status: scope == PetScope.direct ? 'pending' : 'active',
      membershipState: 'active',
      role: 'owner',
      encryptedSnapshot: '',
      seq: 0,
      members: [
        PetMember(userId: myId, role: 'owner', state: 'active', name: ''),
        if (scope == PetScope.direct)
          PetMember(userId: chatId, role: 'member', state: 'pending', name: ''),
      ],
      state: state,
    );
    if (scope != PetScope.group) await _createKey(draft);
    final snapshot = await _encrypt(draft, {'v': 1, 'state': state.toJson()});
    final created = await api.createPet(
      petId: draft.id,
      scope: scope,
      snapshot: snapshot,
      peerId: scope == PetScope.direct ? chatId : null,
      groupId: scope == PetScope.group ? chatId : null,
    );
    final hydrated = await _hydrate(created);
    if (scope == PetScope.direct) {
      final key = await _readKey(hydrated);
      if (key != null) await messages.sendPetKey(chatId, hydrated.id, key);
    }
    return hydrated;
  }

  Future<void> accept(String petId) async {
    final record = (await store.getPetRecords()).firstWhere(
      (r) => r.id == petId,
    );
    if (await _readKey(record) == null)
      throw StateError('Invitation key is missing');
    await api.acceptPet(petId);
    await _hydrate(await api.petDetail(petId).then((detail) => detail.pet));
  }

  Future<void> decline(String petId) async {
    await api.declinePet(petId);
    await store.deletePetRecord(petId);
  }

  Future<void> release(String petId) async {
    await api.releasePet(petId);
    await store.deletePetRecord(petId);
  }

  Future<void> care(String chatId, PetAction action) async {
    final record = await find(chatId);
    if (record == null || !record.canCare) return;
    final now = DateTime.now();
    final current = record.state!;
    if (current.cooldownLeft(action, now) > Duration.zero) return;
    final next = current.care(action, myId, now);
    await _enqueue(record.copyWith(state: next), action.name, const {'v': 1});
  }

  Future<void> rename(String chatId, String name) async {
    final record = await find(chatId);
    if (record == null || !record.canCare) return;
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 24) return;
    final next = record.state!.rename(clean, DateTime.now());
    await _enqueue(record.copyWith(state: next), 'rename', {
      'v': 1,
      'name': clean,
    });
  }

  Future<void> _enqueue(
    PetRecord record,
    String action,
    Map<String, dynamic> payload,
  ) async {
    final encrypted = await _encrypt(record, payload);
    final item = PetOutboxItem(
      id: _uuid.v4(),
      petId: record.id,
      action: action,
      payload: encrypted,
      createdAt: DateTime.now(),
    );
    await store.upsertPetRecord(record);
    _updates.add(record);
    await store.enqueuePetOperation(item);
    await flushOperations();
  }

  Future<void> flushOperations() async {
    if (_flushing || !realtime.isConnected) return;
    _flushing = true;
    try {
      for (final item in await store.getPetOperations()) {
        try {
          await api.sendPetOperation(
            petId: item.petId,
            operationId: item.id,
            action: item.action,
            payload: item.payload,
          );
          await store.removePetOperation(item.id);
          final records = await store.getPetRecords();
          PetRecord? record;
          for (final candidate in records) {
            if (candidate.id == item.petId) {
              record = candidate;
              break;
            }
          }
          if (record != null) await _hydrate(record);
        } on ApiException catch (error) {
          await store.bumpPetOperationAttempts(item.id);
          if (error.statusCode != 0 &&
              error.statusCode != 408 &&
              error.statusCode != 429 &&
              error.statusCode < 500) {
            Log.e('pet.operation.rejected', error);
          }
        } catch (error) {
          await store.bumpPetOperationAttempts(item.id);
          Log.e('pet.operation.sync', error);
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _onPetKey(PetKeyEvent event) async {
    final pending = _importPetKey(event);
    _keyImports[event.petId] = pending;
    try {
      await pending;
    } finally {
      if (identical(_keyImports[event.petId], pending)) {
        _keyImports.remove(event.petId);
      }
    }
  }

  Future<void> _importPetKey(PetKeyEvent event) async {
    try {
      final detail = await api.petDetail(event.petId);
      final member = detail.pet.members.firstWhere(
        (m) => m.userId == event.peerId,
        orElse: () => PetMember(userId: '', role: '', state: '', name: ''),
      );
      if (member.userId.isEmpty ||
          (member.state != 'active' && member.state != 'pending')) {
        return;
      }
      final key = base64Decode(event.key);
      if (key.length != 32) return;
      await secure.write(_keyId(detail.pet), event.key);
      onKeysChanged();
      await _hydrate(detail.pet);
    } catch (error) {
      Log.e('pet.key', error);
    }
  }

  void _onRealtime(RealtimeEvent event) {
    if (event.type == 'pet.operation' ||
        event.type == 'pet.invited' ||
        event.type == 'pet.updated') {
      unawaited(refreshAll());
    }
  }

  Future<void> dispose() async {
    await _snapshotTail;
    _timer.cancel();
    await _eventSub.cancel();
    await _keySub.cancel();
    await _updates.close();
  }
}
