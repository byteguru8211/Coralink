import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../data/secure_store.dart';

/// Password-based encrypted backup of the device's secret key material, so the
/// same account can be used from another device.
///
/// The whole Signal Protocol state (identity key pair, prekeys, sessions) plus
/// every group's symmetric key and personal/direct pet keys is serialized,
/// encrypted with a key derived from
/// the account password (PBKDF2-HMAC-SHA256), and stored on the server as an
/// opaque blob. A new device logging in with the same password fetches the blob,
/// re-derives the key, and restores the exact same identity — instead of
/// generating a fresh one (which is what made history and groups undecryptable
/// and tripped "safety number changed").
class KeyBackup {
  KeyBackup(this._secure);

  final SecureStore _secure;
  final AesGcm _aes = AesGcm.with256bits();

  static const _saltKey = 'backup.salt';
  static const _keyKey = 'backup.key';
  static const _iterations = 200000;
  static const _nonceLength = 12;
  static const _tagLength = 16;

  Future<List<int>> _loadOrCreateSalt() async {
    final existing = await _secure.read(_saltKey);
    if (existing != null && existing.isNotEmpty) {
      return base64Decode(existing);
    }
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    await _secure.write(_saltKey, base64Encode(salt));
    return salt;
  }

  Future<SecretKey> _deriveKey(String password, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );
    return pbkdf2.deriveKeyFromPassword(password: password, nonce: salt);
  }

  Future<void> _cacheKey(SecretKey key) async {
    await _secure.write(_keyKey, base64Encode(await key.extractBytes()));
  }

  Future<SecretKey?> _cachedKey() async {
    final raw = await _secure.read(_keyKey);
    if (raw == null || raw.isEmpty) return null;
    return SecretKey(base64Decode(raw));
  }

  Future<Map<String, String>> _readGroupKeys(String userId) async {
    final groups = <String, String>{};
    final all = await _secure.readAll();
    final prefix = '${SecureStore.prefix}group.key.$userId.';
    final legacyPrefix = '${SecureStore.prefix}group.key.';
    all.forEach((key, value) {
      if (key.startsWith(prefix)) {
        groups[key.substring(prefix.length)] = value;
      } else if (key.startsWith(legacyPrefix)) {
        final groupId = key.substring(legacyPrefix.length);
        if (!groupId.contains('.')) groups[groupId] = value;
      }
    });
    return groups;
  }

  Future<Map<String, String>> _readPetKeys(String userId) async {
    final pets = <String, String>{};
    final all = await _secure.readAll();
    final prefix = '${SecureStore.prefix}pet.key.$userId.';
    all.forEach((key, value) {
      if (key.startsWith(prefix)) {
        pets[key.substring(prefix.length)] = value;
      }
    });
    return pets;
  }

  int _signalRevision(String raw) {
    if (raw.isEmpty) return 0;
    try {
      final json = jsonDecode(raw);
      return json is Map ? (json['revision'] as num?)?.toInt() ?? 0 : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _nextBackupRevision(String userId) async {
    final key = 'backup.revision.$userId';
    final current = int.tryParse(await _secure.read(key) ?? '') ?? 0;
    final next = current + 1;
    await _secure.write(key, '$next');
    return next;
  }

  /// Encrypt the current Signal state + group keys with the cached derived key.
  /// Returns null when no key has been cached yet (e.g. first device before
  /// registration completes).
  Future<({String blob, String salt, int revision})?> build(
    String userId,
  ) async {
    final key = await _cachedKey();
    if (key == null) return null;
    final signalState = await _secure.readSignalState(userId) ?? '';
    final groups = await _readGroupKeys(userId);
    final pets = await _readPetKeys(userId);
    final backupRevision = await _nextBackupRevision(userId);
    final payload = utf8.encode(
      jsonEncode({
        'v': 2,
        'userId': userId,
        'backupRevision': backupRevision,
        'signal': signalState,
        'groups': groups,
        'pets': pets,
      }),
    );
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(payload, secretKey: key, nonce: nonce);
    final out = <int>[...nonce, ...box.mac.bytes, ...box.cipherText];
    final salt = await _secure.read(_saltKey) ?? '';
    return (blob: base64Encode(out), salt: salt, revision: backupRevision);
  }

  /// Derive the key from [password], decrypt [blob], and write the restored
  /// Signal state + group keys into secure storage. Returns false when the
  /// password is wrong (GCM auth tag mismatch) so the caller can surface it.
  Future<bool> restore({
    required String userId,
    required String password,
    required String blob,
    required String salt,
  }) async {
    final key = await _deriveKey(password, base64Decode(salt));
    final raw = base64Decode(blob);
    if (raw.length < _nonceLength + _tagLength) return false;
    final box = SecretBox(
      raw.sublist(_nonceLength + _tagLength),
      nonce: raw.sublist(0, _nonceLength),
      mac: Mac(raw.sublist(_nonceLength, _nonceLength + _tagLength)),
    );
    List<int> clear;
    try {
      clear = await _aes.decrypt(box, secretKey: key);
    } catch (_) {
      return false;
    }
    final payload = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    final backupUser = payload['userId'] as String?;
    if (backupUser != null && backupUser != userId) return false;
    final signalState = payload['signal'] as String? ?? '';
    final localState = await _secure.readSignalState(userId) ?? '';
    if (signalState.isNotEmpty &&
        _signalRevision(signalState) >= _signalRevision(localState)) {
      await _secure.writeSignalState(userId, signalState);
    }
    final groups =
        (payload['groups'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final entry in groups.entries) {
      await _secure.write(
        'group.key.$userId.${entry.key}',
        entry.value as String,
      );
    }
    final pets = (payload['pets'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final entry in pets.entries) {
      await _secure.write(
        'pet.key.$userId.${entry.key}',
        entry.value as String,
      );
    }
    final revision = (payload['backupRevision'] as num?)?.toInt() ?? 0;
    await _secure.write('backup.revision.$userId', '$revision');
    await _secure.write(_saltKey, salt);
    await _cacheKey(key);
    return true;
  }

  /// Establish the backup key from the password on a device that just created
  /// (or restored) its identity, so subsequent [build] calls can re-encrypt.
  Future<void> primeKeyFromPassword(String password) async {
    final salt = await _loadOrCreateSalt();
    final key = await _deriveKey(password, salt);
    await _cacheKey(key);
  }

  Future<void> clear() async {
    await _secure.delete(_keyKey);
    await _secure.delete(_saltKey);
  }
}
