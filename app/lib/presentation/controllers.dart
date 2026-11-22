import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/dependencies.dart';
import '../app/session.dart';
import '../domain/models.dart';
import '../network/realtime.dart';
import '../services/audio_service.dart';

class ChatsState {
  const ChatsState({
    this.loading = true,
    this.chats = const [],
    this.archived = const [],
    this.unread = 0,
    this.connection = RealtimeStatus.idle,
    this.error,
  });

  final bool loading;
  final List<Chat> chats;
  final List<Chat> archived;
  final int unread;
  final RealtimeStatus connection;
  final String? error;

  bool get connected => connection == RealtimeStatus.connected;

  ChatsState copyWith({
    bool? loading,
    List<Chat>? chats,
    List<Chat>? archived,
    int? unread,
    RealtimeStatus? connection,
    String? error,
  }) =>
      ChatsState(
        loading: loading ?? this.loading,
        chats: chats ?? this.chats,
        archived: archived ?? this.archived,
        unread: unread ?? this.unread,
        connection: connection ?? this.connection,
        error: error,
      );
}

class ChatsController extends Notifier<ChatsState> {
  Timer? _debounce;
  final _subscriptions = <StreamSubscription>[];

  @override
  ChatsState build() {
    final client = ref.watch(clientProvider);
    _subscriptions
      ..add(client.messages.messageUpdates.listen((_) => _scheduleReload()))
      ..add(client.messages.incoming.listen((_) => _scheduleReload()))
      ..add(client.messages.presenceEvents.listen((_) => _scheduleReload()))
      ..add(client.messages.groupEvents.listen((_) => _scheduleReload()))
      ..add(client.realtime.statuses.listen((status) {
        if (!ref.mounted) return;
        state = state.copyWith(connection: status);
      }));
    ref.onDispose(() {
      _debounce?.cancel();
      for (final sub in _subscriptions) {
        sub.cancel();
      }
    });
    unawaited(_reload());
    return ChatsState(connection: client.realtime.status);
  }

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _reload);
  }

  Future<void> _reload() async {
    final client = ref.read(clientProvider);
    final all = await client.store.getChats();
    final active = all.where((chat) => !chat.archived).toList();
    final archived = all.where((chat) => chat.archived).toList();
    final unread = await client.store.unreadTotal();
    if (!ref.mounted) return;
    state = state.copyWith(
      loading: false,
      chats: active,
      archived: archived,
      unread: unread,
      connection: client.realtime.status,
    );
  }

  Future<void> refresh() => _reload();

  Future<void> archive(String chatId) async {
    await ref.read(clientProvider).store.setChatFlags(chatId, archived: true);
    await _reload();
  }

  Future<void> unarchive(String chatId) async {
    await ref.read(clientProvider).store.setChatFlags(chatId, archived: false);
    await _reload();
  }

  Future<void> togglePin(String chatId) async {
    final chat = await ref.read(clientProvider).store.getChat(chatId);
    if (chat == null) return;
    await ref.read(clientProvider).store.setChatFlags(chatId, pinned: !chat.pinned);
    await _reload();
  }

  Future<void> toggleMute(String chatId) async {
    final chat = await ref.read(clientProvider).store.getChat(chatId);
    if (chat == null) return;
    await ref.read(clientProvider).store.setChatFlags(chatId, muted: !chat.muted);
    await _reload();
  }

  Future<void> delete(String chatId) async {
    await ref.read(clientProvider).store.deleteChat(chatId);
    await _reload();
  }
}

final chatsProvider = NotifierProvider<ChatsController, ChatsState>(ChatsController.new);

class MessagesState {
  const MessagesState({
    this.loading = true,
    this.messages = const [],
    this.archivedCount = 0,
    this.showArchive = false,
    this.peerTyping = false,
    this.direct = false,
    this.presence = Presence.offline,
    this.lastSeen,
    this.sending = false,
    this.calls = const [],
    this.error,
  });

  final bool loading;
  final List<Message> messages;
  final int archivedCount;
  final bool showArchive;
  final bool peerTyping;
  final bool direct;
  final Presence presence;
  final DateTime? lastSeen;
  final bool sending;
  final List<CallRecord> calls;
  final String? error;

  MessagesState copyWith({
    bool? loading,
    List<Message>? messages,
    int? archivedCount,
    bool? showArchive,
    bool? peerTyping,
    bool? direct,
    Presence? presence,
    DateTime? lastSeen,
    bool? sending,
    List<CallRecord>? calls,
    String? error,
  }) =>
      MessagesState(
        loading: loading ?? this.loading,
        messages: messages ?? this.messages,
        archivedCount: archivedCount ?? this.archivedCount,
        showArchive: showArchive ?? this.showArchive,
        peerTyping: peerTyping ?? this.peerTyping,
        direct: direct ?? this.direct,
        presence: presence ?? this.presence,
        lastSeen: lastSeen ?? this.lastSeen,
        sending: sending ?? this.sending,
        calls: calls ?? this.calls,
        error: error,
      );
}

class MessagesController extends Notifier<MessagesState> {
  MessagesController(this.chatId);
  final String chatId;

  final _subscriptions = <StreamSubscription>[];
  Timer? _typingClear;
  DateTime? _lastTypingSent;
  Timer? _typingStop;

  @override
  MessagesState build() {
    final client = ref.watch(clientProvider);
    _subscriptions
      ..add(client.messages.messageUpdates.listen((message) {
        if (message.chatId != chatId || !ref.mounted) return;
        _upsert(message);
      }))
      ..add(client.messages.removedMessages.listen((id) {
        if (!ref.mounted) return;
        state = state.copyWith(
          messages: state.messages.where((m) => m.id != id).toList(),
        );
      }))
      ..add(client.messages.typingEvents.listen((event) {
        if (event.userId != chatId || !ref.mounted) return;
        state = state.copyWith(peerTyping: event.typing);
        _typingClear?.cancel();
        if (event.typing) {
          _typingClear = Timer(const Duration(seconds: 4), () {
            if (ref.mounted) state = state.copyWith(peerTyping: false);
          });
        }
      }))
      ..add(client.messages.presenceEvents.listen((event) {
        if (event.userId != chatId || !ref.mounted) return;
        state = state.copyWith(presence: event.presence, lastSeen: event.lastSeen);
      }))
      ..add(client.messages.directChanges.listen((event) {
        if (event.peerId != chatId || !ref.mounted) return;
        state = state.copyWith(direct: event.direct);
      }))
      ..add(client.call.completed.listen((call) {
        if (call.peerId != chatId || !ref.mounted) return;
        unawaited(_load());
      }));
    unawaited(client.messages.openChat(chatId));
    unawaited(_load());
    ref.onDispose(() {
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _typingClear?.cancel();
      _typingStop?.cancel();
      ref.read(clientProvider).messages.closeChat(chatId);
      ref.read(clientProvider).realtime.typing(chatId, false);
    });
    return MessagesState(
      direct: client.messages.isDirect(chatId),
    );
  }

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    final chat = await client.store.getChat(chatId);
    final messages = await client.store.getMessages(
      chatId,
      limit: 300,
      includeArchived: state.showArchive,
    );
    final archivedCount = await client.store.countArchivedMessages(chatId);
    final calls = await client.store.getCalls(chatId);
    if (!ref.mounted) return;
    state = state.copyWith(
      loading: false,
      messages: messages,
      archivedCount: archivedCount,
      calls: calls,
      presence: chat?.peerPresence ?? state.presence,
      lastSeen: chat?.peerLastSeen ?? state.lastSeen,
      direct: client.messages.isDirect(chatId),
      error: null,
    );
  }

  void _upsert(Message message) {
    final list = [...state.messages];
    final index = list.indexWhere((item) => item.id == message.id);
    if (index >= 0) {
      list[index] = message;
    } else if (!message.isControl) {
      list.add(message);
    }
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    state = state.copyWith(messages: list);
  }

  Future<void> toggleArchive() async {
    state = state.copyWith(showArchive: !state.showArchive);
    await _load();
  }

  Future<void> sendText(String text) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(sending: true, error: null);
    try {
      await client.messages.sendText(chatId, text);
      final settings = ref.read(settingsProvider);
      await ref.read(audioProvider).playCue(SoundCue.send, settings.sendSoundId);
      await _load();
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
      rethrow;
    } finally {
      if (ref.mounted) state = state.copyWith(sending: false);
    }
  }

  Future<void> sendImage(String base64Data, String mime, String name) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(sending: true, error: null);
    try {
      await client.messages.sendImage(
        chatId,
        base64Data: base64Data,
        mime: mime,
        name: name,
      );
      final settings = ref.read(settingsProvider);
      await ref.read(audioProvider).playCue(SoundCue.send, settings.sendSoundId);
      await _load();
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
      rethrow;
    } finally {
      if (ref.mounted) state = state.copyWith(sending: false);
    }
  }

  Future<void> sendFile(
    String base64Data,
    String mime,
    String name,
    int size,
  ) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(sending: true, error: null);
    try {
      await client.messages.sendFile(
        chatId,
        base64Data: base64Data,
        mime: mime,
        name: name,
        size: size,
      );
      final settings = ref.read(settingsProvider);
      await ref.read(audioProvider).playCue(SoundCue.send, settings.sendSoundId);
      await _load();
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
      rethrow;
    } finally {
      if (ref.mounted) state = state.copyWith(sending: false);
    }
  }

  Future<void> sendAudio(
    String base64Data,
    String mime,
    int size,
    int durationMs,
  ) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(sending: true, error: null);
    try {
      await client.messages.sendAudio(
        chatId,
        base64Data: base64Data,
        mime: mime,
        size: size,
        durationMs: durationMs,
      );
      await _load();
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
      rethrow;
    } finally {
      if (ref.mounted) state = state.copyWith(sending: false);
    }
  }

  Future<void> sendVideo(
    String base64Data,
    String mime,
    String name,
    int size,
  ) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(sending: true, error: null);
    try {
      await client.messages.sendVideo(
        chatId,
        base64Data: base64Data,
        mime: mime,
        name: name,
        size: size,
      );
      await _load();
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
      rethrow;
    } finally {
      if (ref.mounted) state = state.copyWith(sending: false);
    }
  }

  Future<void> sendVideoNote(
    String base64Data,
    String mime,
    int size,
    int durationMs,
  ) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(sending: true, error: null);
    try {
      await client.messages.sendVideoNote(
        chatId,
        base64Data: base64Data,
        mime: mime,
        size: size,
        durationMs: durationMs,
      );
      await _load();
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
      rethrow;
    } finally {
      if (ref.mounted) state = state.copyWith(sending: false);
    }
  }

  Future<void> react(String messageId, String emoji) async {
    await ref.read(clientProvider).messages.sendReaction(chatId, messageId, emoji);
  }

  Future<void> deleteForEveryone(String messageId) async {
    await ref.read(clientProvider).messages.deleteForEveryone(chatId, messageId);
  }

  Future<void> deleteForMe(String messageId) async {
    await ref.read(clientProvider).messages.deleteForMe(messageId);
  }

  Future<void> retry(Message message) async {
    await ref.read(clientProvider).messages.retry(message);
    await _load();
  }

  void onTextChanged(String text) {
    final client = ref.read(clientProvider);
    final now = DateTime.now();
    _typingStop?.cancel();
    if (text.trim().isEmpty) {
      client.realtime.typing(chatId, false);
      _lastTypingSent = null;
      return;
    }
    if (_lastTypingSent == null ||
        now.difference(_lastTypingSent!) > const Duration(seconds: 1)) {
      client.realtime.typing(chatId, true);
      _lastTypingSent = now;
    }
    _typingStop = Timer(const Duration(seconds: 2), () {
      client.realtime.typing(chatId, false);
      _lastTypingSent = null;
    });
  }

  Future<void> reload() => _load();
}

final messagesProvider =
    NotifierProvider.family<MessagesController, MessagesState, String>(
  MessagesController.new,
);

class ContactsState {
  const ContactsState({
    this.loading = true,
    this.contacts = const [],
    this.error,
  });

  final bool loading;
  final List<Contact> contacts;
  final String? error;

  ContactsState copyWith({bool? loading, List<Contact>? contacts, String? error}) =>
      ContactsState(
        loading: loading ?? this.loading,
        contacts: contacts ?? this.contacts,
        error: error,
      );
}

class ContactsController extends Notifier<ContactsState> {
  final _subscriptions = <StreamSubscription>[];

  @override
  ContactsState build() {
    final client = ref.watch(clientProvider);
    // Contacts must follow what the messaging layer learns about people
    // (new peers, renamed profiles, presence) without a manual pull-to-refresh.
    _subscriptions
      ..add(client.messages.messageUpdates.listen((_) => _load()))
      ..add(client.messages.presenceEvents.listen((_) => _load()))
      ..add(client.messages.groupEvents.listen((_) => refresh()));
    ref.onDispose(() {
      for (final sub in _subscriptions) {
        sub.cancel();
      }
    });
    unawaited(_load());
    return const ContactsState();
  }

  Future<void> _load() async {
    final contacts = await ref.read(clientProvider).store.getContacts();
    if (!ref.mounted) return;
    state = state.copyWith(loading: false, contacts: contacts);
  }

  Future<void> refresh() async {
    final client = ref.read(clientProvider);
    try {
      final remote = await client.api.contacts();
      for (final user in remote) {
        await client.store.upsertContact(user);
      }
      await _load();
    } catch (_) {
      await _load();
    }
  }

  Future<List<User>> search(String query) async {
    final trimmed = query.trim();
    // Allow searching by @nickname as well as by display name.
    final normalized = trimmed.startsWith('@') ? trimmed.substring(1).trim() : trimmed;
    if (normalized.length < 2) return const [];
    final users = await ref.read(clientProvider).api.searchUsers(normalized);
    final me = ref.read(sessionProvider).user?.id;
    return users.where((user) => user.id != me).toList();
  }

  Future<User> add(User user) async {
    final client = ref.read(clientProvider);
    User result = user;
    try {
      result = await client.api.addContact(user.id);
    } catch (_) {}
    await client.store.upsertContact(result);
    await _load();
    return result;
  }

  Future<void> remove(String userId) async {
    final client = ref.read(clientProvider);
    try {
      await client.api.removeContact(userId);
    } catch (_) {}
    await client.store.deleteContact(userId);
    await _load();
  }
}

final contactsProvider =
    NotifierProvider<ContactsController, ContactsState>(ContactsController.new);
