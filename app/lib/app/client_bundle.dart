import 'dart:async';

import '../core/config.dart';
import '../data/api_client.dart';
import '../data/local_store.dart';
import '../data/secure_store.dart';
import '../domain/models.dart';
import '../network/call.dart';
import '../network/p2p.dart';
import '../network/realtime.dart';
import '../security/group_crypto.dart';
import '../security/signal_service.dart';
import '../services/echo.dart';
import '../services/message_service.dart';

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
  final EchoSearch echo;

  static Future<ClientBundle> create({
    required AppConfig config,
    required SecureStore secure,
    required LocalStore store,
    required String token,
    required User user,
    required int archiveDays,
    required String presenceScope,
  }) async {
    final api = ApiClient(baseUrl: config.apiBaseUrl, token: token);
    try {
      await api.updateProfile(presenceVisibility: presenceScope);
    } catch (_) {
      // Offline start: the setting will be pushed on the next profile save.
    }
    final signal = await SignalService.load(secure: secure, api: api, userId: user.id);
    final groupCrypto = GroupCrypto(secure);
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

    if (archiveDays > 0) {
      await store.autoArchiveInactive(Duration(days: archiveDays));
      await store.archiveMessagesOlderThan(Duration(days: archiveDays));
    }

    unawaited(realtime.connect());
    realtime.statuses.listen((status) {
      if (status == RealtimeStatus.connected) {
        unawaited(signal.ensurePublished());
        unawaited(messages.flushOutbox());
      }
    });
    unawaited(messages.syncQueue());

    // Register known groups as chats (keys are already in secure storage).
    try {
      final groups = await api.myGroups();
      for (final group in groups) {
        await store.upsertChat(Chat.group(
          id: group.id,
          title: group.title,
          avatar: group.avatar,
          memberCount: group.members.length,
        ));
      }
    } catch (_) {
      // Offline start: groups resync on the next connection.
    }

    return ClientBundle._(
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
      echo: EchoSearch(store),
    );
  }

  Future<void> dispose() async {
    await call.dispose();
    await p2p.dispose();
    await realtime.dispose();
    await messages.dispose();
    api.close();
  }
}
