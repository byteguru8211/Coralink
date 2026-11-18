import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin, namespaced wrapper over platform secure storage (Keychain / Keystore /
/// WebCrypto). Used for auth token, SQLCipher key and Signal Protocol state.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _prefix = 'coralink.';

  Future<String?> read(String key) => _storage.read(key: '$_prefix$key');

  Future<void> write(String key, String value) =>
      _storage.write(key: '$_prefix$key', value: value);

  Future<void> delete(String key) => _storage.delete(key: '$_prefix$key');

  static const String prefix = _prefix;

  /// All stored entries (keys include the internal namespace prefix). Used by
  /// the key-backup service to enumerate group keys.
  Future<Map<String, String>> readAll() => _storage.readAll();

  Future<String> databaseKey() async {
    final existing = await read('db.key');
    if (existing != null && existing.length >= 32) return existing;
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final key = base64UrlEncode(bytes);
    await write('db.key', key);
    return key;
  }

  Future<String?> get token => read('auth.token');
  Future<void> setToken(String? value) async {
    if (value == null) {
      await delete('auth.token');
    } else {
      await write('auth.token', value);
    }
  }

  Future<String?> readSignalState(String userId) => read('signal.$userId');
  Future<void> writeSignalState(String userId, String json) =>
      write('signal.$userId', json);
  Future<void> clearSignalState(String userId) => delete('signal.$userId');
}
