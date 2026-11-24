import 'dart:async';

import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/log.dart';
import '../data/api_client.dart';
import '../data/local_store.dart';
import '../data/secure_store.dart';
import '../domain/models.dart';
import '../network/call.dart';
import '../network/p2p.dart';
import '../network/realtime.dart';
import '../security/group_crypto.dart';
import '../security/key_backup.dart';
import '../security/signal_service.dart';
import '../services/echo.dart';
import '../services/message_service.dart';
import '../services/pet_service.dart';

/// Everything that is scoped to an authenticated session. Recreated on login,
/// disposed on logout without touching the persisted database file.
class ClientBundle {
  ClientBundle._({
    required this.config,
    required this.secure,
    required this.store,
    required this.api,
    required this.signal,
    required this.groupCrypto,
    required this.realtime,
    required this.call,
    required this.p2p,
    required this.messages,
    required this.pets,
    required this.echo,
  });

  final AppConfig config;
  final SecureStore secure;
  final LocalStore store;
  final ApiClient api;
  final SignalService signal;
  final GroupCrypto groupCrypto;
  final RealtimeService realtime;
  final CallService call;
  final P2PManager p2p;
  final MessageService messages;
  final PetService pets;
  final EchoSearch echo;
  StreamSubscription<CallSummary>? _callHistory;
  Timer? _backupTimer;

  static Future<ClientBundle> create({
    required AppConfig config,
    required SecureStore secure,
    required LocalStore store,
    required String token,
    required User user,
    required int archiveDays,
    required String presenceScope,
    bool allowCreateIdentity = false,
  }) async {
    final api = ApiClient(baseUrl: config.apiBaseUrl, token: token);
    try {
      await api.updateProfile(presenceVisibility: presenceScope);
    } catch (_) {
      // Offline start: the setting will be pushed on the next profile save.
    }
    final signal = await SignalService.load(
      secure: secure,
      api: api,
      userId: user.id,
      allowCreate: allowCreateIdentity,
    );
    final groupCrypto = GroupCrypto(secure, userId: user.id);
    final keyBackup = KeyBackup(secure);
    final realtime = RealtimeService(config.wsUrl, token);
    final call = CallService(config, realtime)..identify(user.id);
    final p2p = P2PManager(config, realtime);
    final messages = MessageService(
      store: store,
      api: api,
      signal: signal,
      groupCrypto: groupCrypto,
      realtime: realtime,
      p2p: p2p,
      myId: user.id,
    );
    late final ClientBundle bundle;
    final pets = PetService(
      store: store,
      api: api,
      secure: secure,
      groupCrypto: groupCrypto,
      messages: messages,
      realtime: realtime,
      myId: user.id,
      onKeysChanged: () => bundle._scheduleBackup(),
    );

    final callHistory = call.completed.listen((summary) async {
      try {
        // A call can be the first contact with a peer: make sure the chat exists
        // so the history chip has a conversation to live in, like any messenger.
        await messages.ensureChat(summary.peerId);
        await store.upsertCall(
          CallRecord(
            id: const Uuid().v4(),
            peerId: summary.peerId,
            startedAt: summary.startedAt,
            video: summary.video,
            outgoing: summary.outgoing,
            answered: summary.answered,
            durationSeconds: summary.durationSeconds,
          ),
        );
      } catch (error) {
        Log.e('call.history', error);
      }
    });

    if (archiveDays > 0) {
      await store.autoArchiveInactive(Duration(days: archiveDays));
      await store.archiveMessagesOlderThan(Duration(days: archiveDays));
    }

    unawaited(realtime.connect());
    realtime.statuses.listen((status) {
      if (status == RealtimeStatus.connected) {
        unawaited(signal.ensurePublished());
      }
    });
    unawaited(messages.syncQueue());

    // Register known groups as chats (keys are already in secure storage).
    try {
      final groups = await api.myGroups();
      for (final group in groups) {
        await store.upsertChat(
          Chat.group(
            id: group.id,
            title: group.title,
            avatar: group.avatar,
            memberCount: group.memberCount,
          ),
        );
      }
    } catch (_) {
      // Offline start: groups resync on the next connection.
    }

    bundle = ClientBundle._(
      config: config,
      secure: secure,
      store: store,
      api: api,
      signal: signal,
      groupCrypto: groupCrypto,
      realtime: realtime,
      call: call,
      p2p: p2p,
      messages: messages,
      pets: pets,
      echo: EchoSearch(store),
    );
    bundle._callHistory = callHistory;
    var backupRunning = false;
    bundle._uploadBackup = () async {
      if (backupRunning) return;
      backupRunning = true;
      try {
        final built = await keyBackup.build(user.id);
        if (built != null) {
          await api.uploadBackup(
            blob: built.blob,
            salt: built.salt,
            revision: built.revision,
          );
        }
      } catch (error) {
        Log.d('backup', 'Refresh deferred: $error');
      } finally {
        backupRunning = false;
      }
    };
    signal.onKeysChanged = bundle._scheduleBackup;
    groupCrypto.onKeysChanged = bundle._scheduleBackup;
    unawaited(pets.refreshAll());
    return bundle;
  }

  void _scheduleBackup() {
    _backupTimer?.cancel();
    _backupTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(_uploadBackup?.call() ?? Future.value()),
    );
  }

  Future<void> Function()? _uploadBackup;

  Future<void> dispose() async {
    _backupTimer?.cancel();
    await _callHistory?.cancel();
    await call.dispose();
    await p2p.dispose();
    await pets.dispose();
    await realtime.dispose();
    await messages.dispose();
    api.close();
  }
}
