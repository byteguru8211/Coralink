import 'package:coralink/data/secure_store.dart';
import 'package:coralink/security/key_backup.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in for the platform secure storage so the backup service can
/// be exercised without a device keystore.
class _FakeStorage extends FlutterSecureStorage {
  final Map<String, String> _data = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _data[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _data.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      Map<String, String>.from(_data);
}

void main() {
  test('key backup round-trips signal state and group keys', () async {
    final source = SecureStore(_FakeStorage());
    final userId = 'user-1';
    await source.writeSignalState(userId, '{"identity":"abc"}');
    await source.write('group.key.g1', 'KEY1');
    await source.write('group.key.g2', 'KEY2');

    final backup = KeyBackup(source);
    await backup.primeKeyFromPassword('correct horse');
    final built = await backup.build(userId);
    expect(built, isNotNull);

    // A brand-new device with only the password restores the same secrets.
    final target = SecureStore(_FakeStorage());
    final restored = await KeyBackup(target).restore(
      userId: userId,
      password: 'correct horse',
      blob: built!.blob,
      salt: built.salt,
    );
    expect(restored, isTrue);
    expect(await target.readSignalState(userId), '{"identity":"abc"}');
    expect(await target.read('group.key.g1'), 'KEY1');
    expect(await target.read('group.key.g2'), 'KEY2');
  });

  test('wrong password cannot decrypt a key backup', () async {
    final source = SecureStore(_FakeStorage());
    await source.writeSignalState('u', 'secret-state');
    final backup = KeyBackup(source);
    await backup.primeKeyFromPassword('right-pw');
    final built = await backup.build('u');

    final target = SecureStore(_FakeStorage());
    final ok = await KeyBackup(target).restore(
      userId: 'u',
      password: 'wrong-pw',
      blob: built!.blob,
      salt: built.salt,
    );
    expect(ok, isFalse);
    expect(await target.readSignalState('u'), isNull);
  });
}
