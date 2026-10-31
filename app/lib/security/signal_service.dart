import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../core/log.dart';
import '../data/api_client.dart';
import '../data/secure_store.dart';
import 'signal_store.dart';

class EncryptionException implements Exception {
  EncryptionException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'EncryptionException($code): $message';
}

/// X3DH + Double Ratchet via the Signal Protocol. One device per account:
/// libsignal sessions are addressed as (userId, deviceId=1).
class SignalService {
  SignalService._(this._store, this._secure, this._api, this._userId);

  final PersistentSignalStore _store;
  final SecureStore _secure;
  final ApiClient _api;
  final String _userId;

  Future<void> _tail = Future.value();
  bool _published = false;

  static Future<SignalService> load({
    required SecureStore secure,
    required ApiClient api,
    required String userId,
  }) async {
    final raw = await secure.readSignalState(userId);
    late final PersistentSignalStore store;
    var created = false;
    if (raw == null || raw.isEmpty) {
      store = PersistentSignalStore.create();
      created = true;
      await secure.writeSignalState(userId, store.toJson());
    } else {
      try {
        store = PersistentSignalStore.fromJson(raw);
      } catch (error, stack) {
        Log.e('signal', error, stack);
        throw EncryptionException('corrupt_state', 'Signal state is unreadable');
      }
    }
    store.attachPersistence((json) => secure.writeSignalState(userId, json));
    final service = SignalService._(store, secure, api, userId);
    if (created) {
      try {
        await service.publishKeys();
      } catch (error) {
        // Offline first launch: retry as soon as the socket connects.
        Log.d('signal', 'Key upload deferred: $error');
      }
    } else {
      service._published = false;
    }
    return service;
  }

  Future<void> publishKeys() async {
    final bundle = _store.publicBundle();
    await _api.uploadKeys(
      identityKey: bundle.identityKey,
      registrationId: bundle.registrationId,
      signedPreKeyId: bundle.signedPreKeyId,
      signedPreKey: bundle.signedPreKey,
      signedPreKeySignature: bundle.signedPreKeySignature,
      preKeys: bundle.preKeys,
    );
    _published = true;
  }

  /// Makes sure other users can discover our public bundle. Retried on every
  /// reconnect until the server acknowledges it.
  Future<void> ensurePublished() async {
    if (_published) return;
    try {
      await publishKeys();
    } catch (error) {
      Log.d('signal', 'Key upload still pending: $error');
    }
  }

  Future<List<({int id, String publicKey})>> replenishPreKeys() async {
    final fresh = await _store.generateMorePreKeys(100);
    await _api.replenishPreKeys(fresh);
    return fresh;
  }

  String get identityFingerprint =>
      _store.identityKeyPair.getPublicKey().getFingerprint();

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _ensureSession(String peerId) async {
    final address = SignalProtocolAddress(peerId, 1);
    if (await _store.containsSession(address)) return;
    final KeyBundleDto bundle;
    try {
      bundle = await _api.fetchKeyBundle(peerId);
    } on ApiException catch (error) {
      if (error.statusCode == 404) {
        throw EncryptionException('no_keys', 'The contact has not published keys yet');
      }
      rethrow;
    }
    final identity = IdentityKey(Curve.decodePoint(b64d(bundle.identityKey), 0));
    final signedPublic = Curve.decodePoint(b64d(bundle.signedPreKey), 0);
    final preKeyPublic =
        bundle.preKey == null ? null : Curve.decodePoint(b64d(bundle.preKey!), 0);
    final preKeyBundle = PreKeyBundle(
      bundle.registrationId,
      1,
      bundle.preKeyId,
      preKeyPublic,
      bundle.signedPreKeyId,
      signedPublic,
      Uint8List.fromList(b64d(bundle.signedPreKeySignature)),
      identity,
    );
    final builder =
        SessionBuilder(_store, _store, _store, _store, address);
    await builder.processPreKeyBundle(preKeyBundle);
  }

  /// Encrypts a JSON envelope and returns a self-describing base64 payload:
  /// `[typeByte][libsignal ciphertext]`.
  Future<String> encrypt(String peerId, Map<String, dynamic> envelope) =>
      _exclusive(() async {
        await _ensureSession(peerId);
        final address = SignalProtocolAddress(peerId, 1);
        final cipher = SessionCipher.fromStore(_store, address);
        final plaintext = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
        final message = await cipher.encrypt(plaintext);
        final serialized = message.serialize();
        final framed = Uint8List(serialized.length + 1)
          ..[0] = message.getType()
          ..setRange(1, serialized.length + 1, serialized);
        return base64Encode(framed);
      });

  Future<Map<String, dynamic>> decrypt(String peerId, String payload) =>
      _exclusive(() async {
        final bytes = b64d(payload);
        if (bytes.length < 2) {
          throw EncryptionException('bad_payload', 'Encrypted payload is too short');
        }
        final type = bytes[0];
        final body = Uint8List.fromList(bytes.sublist(1));
        final address = SignalProtocolAddress(peerId, 1);
        final cipher = SessionCipher.fromStore(_store, address);
        Uint8List plaintext;
        try {
          if (type == CiphertextMessage.prekeyType) {
            plaintext = await cipher.decrypt(PreKeySignalMessage(body));
          } else {
            plaintext = await cipher.decryptFromSignal(SignalMessage.fromSerialized(body));
          }
        } on DuplicateMessageException {
          throw EncryptionException('duplicate', 'Message was already decrypted');
        } on UntrustedIdentityException {
          throw EncryptionException('identity_changed', 'Safety number changed');
        } on NoSessionException {
          throw EncryptionException('no_session', 'No session with this contact');
        } on InvalidKeyIdException {
          throw EncryptionException('missing_prekey', 'Pre-key is no longer available');
        } catch (error, stack) {
          Log.e('signal', error, stack);
          throw EncryptionException('decrypt_failed', 'Could not decrypt message');
        }
        return jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      });

  Future<String?> peerFingerprint(String peerId) async {
    final identity = await _store.getIdentity(SignalProtocolAddress(peerId, 1));
    return identity?.getFingerprint();
  }

  Future<void> resetSession(String peerId) async {
    await _store.deleteSession(SignalProtocolAddress(peerId, 1));
  }

  Future<void> wipe() async {
    await _secure.clearSignalState(_userId);
  }
}
