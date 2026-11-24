import 'dart:convert';
import 'dart:typed_data';

import 'package:coralink/security/signal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

void main() {
  test('Signal Protocol session encrypts both directions', () async {
    final alice = PersistentSignalStore.create();
    final bob = PersistentSignalStore.create();
    final aliceAddress = SignalProtocolAddress('alice', 1);
    final bobAddress = SignalProtocolAddress('bob', 1);

    final bundle = alice.publicBundle();
    final oneTime = bundle.preKeys.first;
    final preKeyBundle = PreKeyBundle(
      bundle.registrationId,
      1,
      oneTime.id,
      Curve.decodePoint(base64Decode(oneTime.publicKey), 0),
      bundle.signedPreKeyId,
      Curve.decodePoint(base64Decode(bundle.signedPreKey), 0),
      Uint8List.fromList(base64Decode(bundle.signedPreKeySignature)),
      IdentityKey(Curve.decodePoint(base64Decode(bundle.identityKey), 0)),
    );

    await SessionBuilder(
      bob,
      bob,
      bob,
      bob,
      aliceAddress,
    ).processPreKeyBundle(preKeyBundle);

    final bobCipher = SessionCipher.fromStore(bob, aliceAddress);
    final first = await bobCipher.encrypt(
      Uint8List.fromList(utf8.encode('привет, это Алиса')),
    );
    expect(first.getType(), CiphertextMessage.prekeyType);

    final aliceCipher = SessionCipher.fromStore(alice, bobAddress);
    final firstPlain = await aliceCipher.decrypt(
      PreKeySignalMessage(first.serialize()),
    );
    expect(utf8.decode(firstPlain), 'привет, это Алиса');

    final reply = await aliceCipher.encrypt(
      Uint8List.fromList(utf8.encode('привет, Боб!')),
    );
    expect(reply.getType(), CiphertextMessage.whisperType);
    final replyPlain = await bobCipher.decryptFromSignal(
      SignalMessage.fromSerialized(reply.serialize()),
    );
    expect(utf8.decode(replyPlain), 'привет, Боб!');

    // The one-time pre-key must be gone after the initial handshake.
    expect(await alice.containsPreKey(oneTime.id), isFalse);
  });

  test('published one-time prekeys are not advertised again', () async {
    final store = PersistentSignalStore.create();
    final first = store.preKeys.keys.first;
    await store.markPreKeysPublished([first]);
    final restored = PersistentSignalStore.fromJson(store.toJson());
    expect(restored.unpublishedPreKeys(), hasLength(99));
    expect(restored.publicBundle().preKeys, hasLength(100));
  });

  test('legacy state treats surviving prekeys as already published', () {
    final store = PersistentSignalStore.create();
    final json = Map<String, dynamic>.from(jsonDecode(store.toJson()) as Map)
      ..remove('publishedPreKeyIds');
    final restored = PersistentSignalStore.fromJson(jsonEncode(json));
    expect(restored.unpublishedPreKeys(), isEmpty);
  });

  test('Signal store survives JSON round-trip', () {
    final store = PersistentSignalStore.create();
    final restored = PersistentSignalStore.fromJson(store.toJson());
    expect(restored.registrationId, store.registrationId);
    expect(
      restored.identityKeyPair.serialize(),
      store.identityKeyPair.serialize(),
    );
    expect(restored.preKeys.length, store.preKeys.length);
    expect(
      restored.publicBundle().identityKey,
      store.publicBundle().identityKey,
    );
  });
}
