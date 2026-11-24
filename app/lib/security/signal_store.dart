import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Persistent Signal Protocol store. The whole key/ratchet state is a single
/// JSON blob kept in Keychain/Keystore, refreshed after every mutation.
///
/// Storing private keys only in platform secure storage is a deliberate
/// security decision: the local message DB never contains key material.
class PersistentSignalStore implements SignalProtocolStore {
  PersistentSignalStore._({
    required this.identityKeyPair,
    required this.registrationId,
    required this.currentSignedPreKeyId,
    required this.nextPreKeyId,
  });

  final IdentityKeyPair identityKeyPair;
  final int registrationId;
  final Map<String, IdentityKey> identities = {};
  final Map<int, PreKeyRecord> preKeys = {};
  final Map<int, SignedPreKeyRecord> signedPreKeys = {};
  final Map<String, SessionRecord> sessions = {};
  final Set<int> publishedPreKeyIds = {};
  int currentSignedPreKeyId;
  int nextPreKeyId;
  int revision = 0;

  Future<void> Function(String json)? _onChanged;

  static const _preKeyBatch = 100;

  void attachPersistence(Future<void> Function(String json) onChanged) {
    _onChanged = onChanged;
  }

  static PersistentSignalStore create() {
    final identity = generateIdentityKeyPair();
    final regId = generateRegistrationId(false);
    final signed = generateSignedPreKey(identity, 1);
    final store = PersistentSignalStore._(
      identityKeyPair: identity,
      registrationId: regId,
      currentSignedPreKeyId: 1,
      nextPreKeyId: 1,
    );
    store.signedPreKeys[1] = signed;
    store._generatePreKeysLocked(_preKeyBatch);
    return store;
  }

  static PersistentSignalStore fromJson(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final store = PersistentSignalStore._(
      identityKeyPair: IdentityKeyPair.fromSerialized(
        base64Decode(json['identity'] as String),
      ),
      registrationId: (json['registrationId'] as num).toInt(),
      currentSignedPreKeyId: (json['signedPreKeyId'] as num?)?.toInt() ?? 1,
      nextPreKeyId: (json['nextPreKeyId'] as num?)?.toInt() ?? 1,
    );
    (json['identities'] as Map<String, dynamic>? ?? {}).forEach((key, value) {
      store.identities[key] = IdentityKey.fromBytes(
        base64Decode(value as String),
        0,
      );
    });
    (json['preKeys'] as Map<String, dynamic>? ?? {}).forEach((key, value) {
      store.preKeys[int.parse(key)] = PreKeyRecord.fromBuffer(
        base64Decode(value as String),
      );
    });
    (json['signedPreKeys'] as Map<String, dynamic>? ?? {}).forEach((
      key,
      value,
    ) {
      store.signedPreKeys[int.parse(key)] = SignedPreKeyRecord.fromSerialized(
        base64Decode(value as String),
      );
    });
    (json['sessions'] as Map<String, dynamic>? ?? {}).forEach((key, value) {
      store.sessions[key] = SessionRecord.fromSerialized(
        base64Decode(value as String),
      );
    });
    final published = json['publishedPreKeyIds'] as List?;
    if (published == null) {
      store.publishedPreKeyIds.addAll(store.preKeys.keys);
    } else {
      store.publishedPreKeyIds.addAll(
        published.map((value) => (value as num).toInt()),
      );
    }
    store.revision = (json['revision'] as num?)?.toInt() ?? 0;
    return store;
  }

  String toJson() => jsonEncode({
    'v': 2,
    'identity': base64Encode(identityKeyPair.serialize()),
    'registrationId': registrationId,
    'signedPreKeyId': currentSignedPreKeyId,
    'nextPreKeyId': nextPreKeyId,
    'revision': revision,
    'publishedPreKeyIds': publishedPreKeyIds.toList(),
    'identities': identities.map(
      (key, value) => MapEntry(key, base64Encode(value.serialize())),
    ),
    'preKeys': preKeys.map(
      (key, value) => MapEntry(key.toString(), base64Encode(value.serialize())),
    ),
    'signedPreKeys': signedPreKeys.map(
      (key, value) => MapEntry(key.toString(), base64Encode(value.serialize())),
    ),
    'sessions': sessions.map(
      (key, value) => MapEntry(key, base64Encode(value.serialize())),
    ),
  });

  Future<void> _changed() async {
    revision += 1;
    final callback = _onChanged;
    if (callback != null) await callback(toJson());
  }

  int get unpublishedPreKeyCount =>
      preKeys.keys.where((id) => !publishedPreKeyIds.contains(id)).length;

  List<({int id, String publicKey})> unpublishedPreKeys() => [
    for (final record in preKeys.values)
      if (!publishedPreKeyIds.contains(record.id))
        (
          id: record.id,
          publicKey: base64Encode(record.getKeyPair().publicKey.serialize()),
        ),
  ];

  Future<void> markPreKeysPublished(Iterable<int> ids) async {
    final before = publishedPreKeyIds.length;
    publishedPreKeyIds.addAll(ids);
    if (publishedPreKeyIds.length != before) await _changed();
  }

  void _generatePreKeysLocked(int count) {
    final start = nextPreKeyId;
    final generated = generatePreKeys(start, count);
    for (final record in generated) {
      preKeys[record.id] = record;
    }
    nextPreKeyId = start + count;
  }

  /// Creates a fresh batch of one-time prekeys (call when the server stock is
  /// low). Returns public parts for upload.
  Future<List<({int id, String publicKey})>> generateMorePreKeys(
    int count,
  ) async {
    _generatePreKeysLocked(count);
    await _changed();
    final start = nextPreKeyId - count;
    return [
      for (var id = start; id < nextPreKeyId; id++)
        (
          id: id,
          publicKey: base64Encode(
            preKeys[id]!.getKeyPair().publicKey.serialize(),
          ),
        ),
    ];
  }

  ({
    String identityKey,
    int registrationId,
    int signedPreKeyId,
    String signedPreKey,
    String signedPreKeySignature,
    List<({int id, String publicKey})> preKeys,
  })
  publicBundle() {
    final signed = signedPreKeys[currentSignedPreKeyId]!;
    return (
      identityKey: base64Encode(identityKeyPair.getPublicKey().serialize()),
      registrationId: registrationId,
      signedPreKeyId: signed.id,
      signedPreKey: base64Encode(signed.getKeyPair().publicKey.serialize()),
      signedPreKeySignature: base64Encode(signed.signature),
      preKeys: [
        for (final record in preKeys.values)
          (
            id: record.id,
            publicKey: base64Encode(record.getKeyPair().publicKey.serialize()),
          ),
      ],
    );
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => identityKeyPair;

  @override
  Future<int> getLocalRegistrationId() async => registrationId;

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
  ) async {
    if (identityKey == null) return false;
    final key = address.toString();
    final existing = identities[key];
    final changed =
        existing == null ||
        !const ListEquality<int>().equals(
          existing.serialize(),
          identityKey.serialize(),
        );
    identities[key] = identityKey;
    if (changed) await _changed();
    return changed;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey? identityKey,
    Direction direction,
  ) async {
    if (identityKey == null) return false;
    final known = identities[address.toString()];
    if (known == null) return true;
    return const ListEquality<int>().equals(
      known.serialize(),
      identityKey.serialize(),
    );
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async =>
      identities[address.toString()];

  Future<void> removeIdentity(SignalProtocolAddress address) async {
    if (identities.remove(address.toString()) != null) await _changed();
  }

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final record = preKeys[preKeyId];
    if (record == null) throw InvalidKeyIdException('No pre-key $preKeyId');
    return record;
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    preKeys[preKeyId] = record;
    await _changed();
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      preKeys.containsKey(preKeyId);

  @override
  Future<void> removePreKey(int preKeyId) async {
    preKeys.remove(preKeyId);
    await _changed();
  }

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async =>
      sessions[address.toString()] ?? SessionRecord();

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final prefix = '$name:';
    return sessions.keys
        .where((key) => key.startsWith(prefix))
        .map((key) => int.tryParse(key.substring(prefix.length)) ?? 1)
        .where((deviceId) => deviceId != 1)
        .toList();
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    sessions[address.toString()] = record;
    await _changed();
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async =>
      sessions.containsKey(address.toString());

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    sessions.remove(address.toString());
    await _changed();
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    sessions.removeWhere((key, _) => key.startsWith('$name:'));
    await _changed();
  }

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final record = signedPreKeys[signedPreKeyId];
    if (record == null)
      throw InvalidKeyIdException('No signed pre-key $signedPreKeyId');
    return record;
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async =>
      signedPreKeys.values.toList();

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    signedPreKeys[signedPreKeyId] = record;
    await _changed();
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      signedPreKeys.containsKey(signedPreKeyId);

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    signedPreKeys.remove(signedPreKeyId);
    await _changed();
  }
}

Uint8List b64d(String value) => base64Decode(value);
