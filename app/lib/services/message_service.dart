import 'dart:async';

import 'package:uuid/uuid.dart';

import '../core/log.dart';
import '../data/api_client.dart';
import '../data/local_store.dart';
import '../domain/models.dart';
import '../network/p2p.dart';
import '../network/realtime.dart';
import '../security/group_crypto.dart';
import '../security/signal_service.dart';

class IncomingEvent {
  const IncomingEvent(this.message, {required this.isActiveChat});
  final Message message;
  final bool isActiveChat;
}

class PresenceEvent {
  const PresenceEvent(this.userId, this.presence, this.lastSeen);
  final String userId;
  final Presence presence;
  final DateTime? lastSeen;
}

class TypingEvent {
  const TypingEvent(this.userId, this.typing);
  final String userId;
  final bool typing;
}

class MessageService {
  MessageService({
    required this.store,
    required this.api,
    required this.signal,
    required this.groupCrypto,
    required this.realtime,
    required this.p2p,
    required this.myId,
  }) {
    p2p.identify(myId);
    p2p.onPayload = _handleP2PPayload;
    p2p.onLinkChanged = (peerId, connected) {
      directPeers.add(peerId);
      if (!connected) directPeers.remove(peerId);
      _directChanges.add((peerId: peerId, direct: connected));
    };
    _eventSubscription = realtime.events.listen(_onRealtimeEvent);
    _statusSubscription = realtime.statuses.listen((status) {
      if (status == RealtimeStatus.connected) {
        realtime.setPresence('active');
        flushOutbox();
      }
    });
    _outboxTimer = Timer.periodic(const Duration(seconds: 8), (_) => flushOutbox());
  }

  final LocalStore store;
  final ApiClient api;
  final SignalService signal;
  final GroupCrypto groupCrypto;
  final RealtimeService realtime;
  final P2PManager p2p;
  final String myId;

  final _messageUpdates = StreamController<Message>.broadcast();
  final _incoming = StreamController<IncomingEvent>.broadcast();
  final _presence = StreamController<PresenceEvent>.broadcast();
  final _typing = StreamController<TypingEvent>.broadcast();
  final _directChanges = StreamController<({String peerId, bool direct})>.broadcast();
  final _removed = StreamController<String>.broadcast();
  final _groups = StreamController<GroupAddedEvent>.broadcast();
  final directPeers = <String>{};

  late final StreamSubscription<RealtimeEvent> _eventSubscription;
  late final StreamSubscription<RealtimeStatus> _statusSubscription;
  Timer? _outboxTimer;
  String? activeChatId;
  final Set<String> _inFlight = {};
  final int _maxRawImageBytes = 340 * 1024;
  // Stays under the relay's decoded-ciphertext ceiling (9 MB) once the base64
  // envelope (~4/3 of raw) is accounted for, so an accepted send never fails
  // silently on the server.
  final int _maxRawFileBytes = 6 * 1024 * 1024;

  Stream<Message> get messageUpdates => _messageUpdates.stream;
  Stream<IncomingEvent> get incoming => _incoming.stream;
  Stream<PresenceEvent> get presenceEvents => _presence.stream;
  Stream<TypingEvent> get typingEvents => _typing.stream;
  Stream<({String peerId, bool direct})> get directChanges => _directChanges.stream;
  Stream<String> get removedMessages => _removed.stream;

  /// Fires when a group key arrives for a group this device did not know yet —
  /// i.e. somebody just added this account to a group.
  Stream<GroupAddedEvent> get groupEvents => _groups.stream;

  bool isDirect(String peerId) => directPeers.contains(peerId);

  Future<void> syncQueue() async {
    try {
      final queued = await api.queuedMessages();
      for (final dto in queued) {
        await _processIncoming(
          id: dto.id,
          senderId: dto.senderId,
          payload: dto.ciphertext,
          kind: dto.kind,
          createdAt: dto.createdAt,
          viaRelay: true,
        );
      }
      final groupQueued = await api.pendingGroupMessages();
      final ackIds = <String>[];
      for (final dto in groupQueued) {
        final groupId = dto.groupId;
        if (groupId == null) continue;
        final stored = await _processGroupIncoming(
          id: dto.id,
          groupId: groupId,
          senderId: dto.senderId,
          payload: dto.ciphertext,
          kind: dto.kind,
          createdAt: dto.createdAt,
        );
        if (stored) ackIds.add(dto.id);
      }
      if (ackIds.isNotEmpty) await api.ackGroupMessages(ackIds);
      await flushOutbox();
    } catch (error) {
      Log.e('message.sync', error);
    }
  }

  /// Decrypts and stores a group message. Returns true when it was decrypted
  /// (so the caller can acknowledge it); undecryptable messages are stored with
  /// a placeholder and left un-acked for a later retry.
  Future<bool> _processGroupIncoming({
    required String id,
    required String groupId,
    required String senderId,
    required String payload,
    required String kind,
    required DateTime createdAt,
  }) async {
    if (await store.getMessage(id) != null) return true;
    Map<String, dynamic>? envelope;
    String? error;
    try {
      envelope = await groupCrypto.decrypt(groupId, payload);
    } on GroupCryptoException catch (e) {
      error = e.code;
    }
    if (envelope == null) {
      final broken = Message(
        id: id,
        chatId: groupId,
        senderId: senderId,
        text: error == 'no_key'
            ? 'Нет ключа группы'
            : 'Не удалось расшифровать сообщение',
        status: MessageStatus.delivered,
        createdAt: createdAt,
        meta: const {'undecryptable': true},
      );
      await store.upsertMessage(broken);
      await store.touchChat(groupId,
          preview: broken.text, at: createdAt, incrementUnread: activeChatId != groupId);
      _messageUpdates.add(broken);
      _incoming.add(IncomingEvent(broken, isActiveChat: activeChatId == groupId));
      return false;
    }
    final type = envelope['type'] as String? ?? 'text';
    if (type == 'groupMeta') {
      final existing = await store.getChat(groupId);
      if (existing != null) {
        final title = envelope['title'] as String?;
        final avatar = envelope['avatar'] as String?;
        final memberCount = envelope['memberCount'];
        await store.upsertChat(existing.copyWith(
          peerName: title ?? existing.peerName,
          peerAvatar: avatar ?? existing.peerAvatar,
          memberCount: memberCount is int ? memberCount : existing.memberCount,
        ));
      }
      return true;
    }
    final image = envelope['image'] as String?;
    final fileData = envelope['data'] as String?;
    final meta = (envelope['meta'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final text = (envelope['text'] as String?) ?? '';
    final isActive = activeChatId == groupId;
    final MessageKind messageKind = type == 'image'
        ? MessageKind.image
        : type == 'file'
            ? MessageKind.file
            : type == 'audio'
                ? MessageKind.audio
                : type == 'video'
                    ? MessageKind.video
                    : type == 'video_note'
                        ? MessageKind.videoNote
                        : MessageKind.text;
    final hasData = type == 'file' ||
        type == 'audio' ||
        type == 'video' ||
        type == 'video_note';
    final message = Message(
      id: id,
      chatId: groupId,
      senderId: senderId,
      text: text,
      kind: messageKind,
      status: isActive ? MessageStatus.read : MessageStatus.delivered,
      createdAt: createdAt,
      meta: hasData ? {...meta, if (fileData != null) 'data': fileData} : meta,
      imageBase64: image,
    );
    await store.upsertMessage(message);
    final preview = messageKind == MessageKind.image
        ? 'Фото'
        : messageKind == MessageKind.file
            ? 'Файл'
            : messageKind == MessageKind.audio
                ? 'Голосовое'
                : messageKind == MessageKind.video
                    ? 'Видео'
                    : messageKind == MessageKind.videoNote
                        ? 'Видеокружок'
                        : text;
    await store.touchChat(groupId, preview: preview, at: createdAt, incrementUnread: !isActive);
    if (isActive) {
      await store.markChatRead(groupId);
      realtime.markGroupRead(groupId, [id]);
    }
    _messageUpdates.add(message);
    _incoming.add(IncomingEvent(message, isActiveChat: isActive));
    return true;
  }

  /// Create a group on the server, store it locally, and distribute the group
  /// key to every member over their existing 1-на-1 Signal session.
  Future<Group> createGroup({
    required String title,
    List<String> memberIds = const [],
    String avatar = '',
  }) async {
    final group = await api.createGroup(title: title, memberIds: memberIds, avatar: avatar);
    await _registerGroupChat(group);
    await _distributeKey(group.id, group.members.map((m) => m.id).toList());
    return group;
  }

  Future<void> inviteToGroup(String groupId, String userId) async {
    final members = await api.addGroupMember(groupId, userId);
    final existing = await store.getChat(groupId);
    if (existing != null) {
      await store.upsertChat(existing.copyWith(memberCount: members.length));
    }
    await _distributeKey(groupId, [userId]);
  }

  Future<void> leaveGroup(String groupId) async {
    await api.leaveGroup(groupId, myId);
    await groupCrypto.removeKey(groupId);
    await store.deleteChat(groupId);
  }

  Future<void> _registerGroupChat(Group group) async {
    final chat = Chat.group(
      id: group.id,
      title: group.title,
      avatar: group.avatar,
      memberCount: group.memberCount,
    );
    await store.upsertChat(chat);
  }

  Future<Group> updateGroup(
    String groupId, {
    String? title,
    String? avatar,
  }) async {
    final group = await api.updateGroup(groupId, title: title, avatar: avatar);
    final existing = await store.getChat(groupId);
    if (existing != null) {
      await store.upsertChat(existing.copyWith(
        peerName: group.title,
        peerAvatar: group.avatar,
        memberCount: group.memberCount,
      ));
    }
    // Mirror the change to every other member in real time: a symmetric group
    // control envelope carries the new title/avatar so their chat row updates
    // without re-opening or re-fetching the group.
    try {
      await _sendEnvelope(
        chatId: groupId,
        kind: MessageKind.text,
        preview: null,
        control: true,
        envelope: {
          'v': 1,
          'type': 'groupMeta',
          'title': group.title,
          'avatar': group.avatar,
          'memberCount': group.memberCount,
          'sentAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
    } catch (error) {
      Log.e('group.meta', error);
    }
    return group;
  }

  Future<void> _distributeKey(String groupId, List<String> memberIds) async {
    final key = await groupCrypto.keyFor(groupId);
    for (final memberId in memberIds) {
      if (memberId == myId) continue;
      try {
        await _sendEnvelope(
          chatId: memberId,
          kind: MessageKind.text,
          preview: null,
          control: true,
          envelope: {
            'v': 1,
            'type': 'groupKey',
            'groupId': groupId,
            'key': key,
            'sentAt': DateTime.now().millisecondsSinceEpoch,
          },
        );
      } catch (error) {
        Log.e('group.distribute', error);
      }
    }
  }

  Future<void> flushOutbox() async {
    if (!realtime.isConnected) return;
    final pending = await store.getOutbox();
    for (final item in pending) {
      final isGroup = item.payload['group'] == true;
      _dispatchSend(
        isGroup,
        item.payload['id'] as String,
        item.payload['to'] as String,
        item.payload['ciphertext'] as String,
        item.payload['kind'] as String,
        (item.payload['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
        DateTime.fromMillisecondsSinceEpoch(
          (item.payload['createdAt'] as num).toInt(),
        ),
      );
      await store.removeOutbox(item.id);
    }
  }

  Future<Chat> ensureChat(String peerId, {User? peer}) async {
    final existing = await store.getChat(peerId);
    if (existing != null) {
      if (peer != null) {
        final updated = existing.copyWith(
          peerName: peer.name,
          peerPhone: peer.phone,
          peerAbout: peer.about,
          peerAvatarColor: peer.avatarColor,
          peerAvatar: peer.avatar,
          peerPresence: peer.presence,
          peerLastSeen: peer.lastSeen,
        );
        await store.upsertChat(updated);
        return updated;
      }
      // A chat created from a bare id (or from an older session) can carry a
      // placeholder name: fill in the real profile once, in the background.
      if (existing.peerName.isEmpty || existing.peerName == 'Coralink') {
        unawaited(_syncPeerProfile(peerId));
      }
      return existing;
    }
    var user = peer;
    if (user == null) {
      user = await store.getUser(peerId) ?? await _fetchPeer(peerId);
    }
    await store.upsertUser(user);
    final chat = Chat.fromUser(user);
    await store.upsertChat(chat);
    // A brand-new conversation also becomes a contact, so the contacts tab and
    // the chat list always agree about who this person is.
    try {
      await store.upsertContact(user);
    } catch (error) {
      Log.e('contact.ensure', error);
    }
    return chat;
  }

  Future<User> _fetchPeer(String peerId) async {
    try {
      return await api.getUser(peerId);
    } catch (error) {
      Log.d('contact.profile', '$peerId: $error');
      return User(id: peerId, phone: '', name: 'Coralink');
    }
  }

  /// Refreshes the cached profile/chat row for a peer from the server. Used when
  /// a conversation starts with somebody this device only knew by id.
  Future<void> _syncPeerProfile(String peerId) async {
    try {
      final user = await api.getUser(peerId);
      await store.upsertUser(user);
      final chat = await store.getChat(peerId);
      if (chat == null) return;
      await store.upsertChat(chat.copyWith(
        peerName: user.name,
        peerPhone: user.phone,
        peerAbout: user.about,
        peerAvatarColor: user.avatarColor,
        peerAvatar: user.avatar,
        peerPresence: user.presence,
        peerLastSeen: user.lastSeen,
      ));
      if (await store.hasContact(peerId)) {
        await store.upsertContact(user);
      }
      _presence.add(PresenceEvent(peerId, user.presence, user.lastSeen));
    } catch (error) {
      Log.d('contact.sync', '$peerId: $error');
    }
  }

  Future<Message> sendText(String chatId, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) throw ArgumentError('Empty message');
    if (clean.length > 4000) {
      throw ArgumentError('Message is too long');
    }
    return _sendEnvelope(
      chatId: chatId,
      kind: MessageKind.text,
      preview: clean,
      envelope: {'v': 1, 'type': 'text', 'text': clean, 'sentAt': DateTime.now().millisecondsSinceEpoch},
    );
  }

  Future<Message> sendImage(
    String chatId, {
    required String base64Data,
    required String mime,
    required String name,
    String caption = '',
  }) async {
    final rawSize = base64Data.length * 3 ~/ 4;
    if (rawSize > _maxRawImageBytes) {
      throw ArgumentError('image_too_large');
    }
    return _sendEnvelope(
      chatId: chatId,
      kind: MessageKind.image,
      preview: 'Фото',
      imageBase64: base64Data,
      meta: {'mime': mime, 'name': name, 'size': rawSize},
      envelope: {
        'v': 1,
        'type': 'image',
        'image': base64Data,
        'meta': {'mime': mime, 'name': name},
        'text': caption,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<Message> sendFile(
    String chatId, {
    required String base64Data,
    required String mime,
    required String name,
    required int size,
    String caption = '',
  }) async {
    if (size > _maxRawFileBytes) {
      throw ArgumentError('file_too_large');
    }
    return _sendEnvelope(
      chatId: chatId,
      kind: MessageKind.file,
      preview: 'Файл',
      meta: {'mime': mime, 'name': name, 'size': size, 'data': base64Data},
      envelope: {
        'v': 1,
        'type': 'file',
        'data': base64Data,
        'meta': {'mime': mime, 'name': name, 'size': size},
        'text': caption,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<Message> sendAudio(
    String chatId, {
    required String base64Data,
    required String mime,
    required int size,
    required int durationMs,
  }) async {
    if (size > _maxRawFileBytes) {
      throw ArgumentError('file_too_large');
    }
    return _sendEnvelope(
      chatId: chatId,
      kind: MessageKind.audio,
      preview: 'Голосовое',
      meta: {
        'mime': mime,
        'name': 'voice',
        'size': size,
        'durationMs': durationMs,
        'data': base64Data,
      },
      envelope: {
        'v': 1,
        'type': 'audio',
        'data': base64Data,
        'meta': {'mime': mime, 'size': size, 'durationMs': durationMs},
        'text': '',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<Message> sendVideo(
    String chatId, {
    required String base64Data,
    required String mime,
    required String name,
    required int size,
    int durationMs = 0,
  }) async {
    if (size > _maxRawFileBytes) {
      throw ArgumentError('file_too_large');
    }
    return _sendEnvelope(
      chatId: chatId,
      kind: MessageKind.video,
      preview: 'Видео',
      meta: {
        'mime': mime,
        'name': name,
        'size': size,
        'durationMs': durationMs,
        'data': base64Data,
      },
      envelope: {
        'v': 1,
        'type': 'video',
        'data': base64Data,
        'meta': {'mime': mime, 'name': name, 'size': size, 'durationMs': durationMs},
        'text': '',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<Message> sendVideoNote(
    String chatId, {
    required String base64Data,
    required String mime,
    required int size,
    required int durationMs,
  }) async {
    if (size > _maxRawFileBytes) {
      throw ArgumentError('file_too_large');
    }
    return _sendEnvelope(
      chatId: chatId,
      kind: MessageKind.videoNote,
      preview: 'Видеокружок',
      meta: {
        'mime': mime,
        'name': 'note',
        'size': size,
        'durationMs': durationMs,
        'data': base64Data,
      },
      envelope: {
        'v': 1,
        'type': 'video_note',
        'data': base64Data,
        'meta': {'mime': mime, 'size': size, 'durationMs': durationMs},
        'text': '',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<void> sendReaction(String chatId, String messageId, String emoji) async {
    final target = await store.getMessage(messageId);
    if (target == null) return;
    final reactions = Map<String, List<String>>.from(target.reactions);
    final users = List<String>.from(reactions[emoji] ?? const []);
    if (users.contains(myId)) {
      users.remove(myId);
    } else {
      users.add(myId);
    }
    if (users.isEmpty) {
      reactions.remove(emoji);
    } else {
      reactions[emoji] = users;
    }
    await store.setReactions(messageId, reactions);
    final updated = target.copyWith(reactions: reactions);
    _messageUpdates.add(updated);

    await _sendEnvelope(
      chatId: chatId,
      kind: MessageKind.reaction,
      preview: null,
      control: true,
      envelope: {
        'v': 1,
        'type': 'reaction',
        'targetId': messageId,
        'reaction': emoji,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<void> deleteForEveryone(String chatId, String messageId) async {
    final target = await store.getMessage(messageId);
    if (target == null) return;
    await store.softDeleteMessage(messageId);
    _messageUpdates.add(target.copyWith(deleted: true, text: ''));
    await _sendEnvelope(
      chatId: chatId,
      kind: MessageKind.delete,
      preview: null,
      control: true,
      envelope: {
        'v': 1,
        'type': 'delete',
        'targetId': messageId,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<void> deleteForMe(String messageId) async {
    await store.deleteMessage(messageId);
    _removed.add(messageId);
  }

  Future<Message> _sendEnvelope({
    required String chatId,
    required MessageKind kind,
    required Map<String, dynamic> envelope,
    String? preview,
    String? imageBase64,
    Map<String, dynamic> meta = const {},
    bool control = false,
  }) async {
    final id = const Uuid().v4();
    final createdAt = DateTime.now();
    final isGroup = (await store.getChat(chatId))?.isGroup ?? false;
    Message message;
    try {
      final ciphertext = isGroup
          ? await groupCrypto.encrypt(chatId, envelope)
          : await signal.encrypt(chatId, envelope);
      message = Message(
        id: id,
        chatId: chatId,
        senderId: myId,
        text: envelope['text'] as String? ?? '',
        kind: kind,
        status: MessageStatus.sending,
        createdAt: createdAt,
        meta: meta,
        imageBase64: imageBase64,
      );
      await store.upsertMessage(message);
      if (!control) {
        await store.touchChat(
          chatId,
          preview: preview ?? '',
          at: createdAt,
          incrementUnread: false,
        );
      }
      // Attachment bytes ride inside the encrypted envelope, never the wire
      // meta: relay meta is size-capped server-side, so a base64 payload there
      // would reject the send and strand the recipient. The recipient rebuilds
      // meta['data'] from the decrypted envelope.
      final wireMeta = meta.containsKey('data')
          ? (<String, dynamic>{...meta}..remove('data'))
          : meta;
      final wireKind = control ? 'control' : messageKindToWire(kind);
      final payload = {
        'id': id,
        'to': chatId,
        'group': isGroup,
        'ciphertext': ciphertext,
        'kind': wireKind,
        'meta': wireMeta,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };
      if (realtime.isConnected) {
        _dispatchSend(isGroup, id, chatId, ciphertext, wireKind, wireMeta, createdAt);
        message = message.copyWith(status: MessageStatus.sent);
        await store.updateMessageStatus(id, MessageStatus.sent);
      } else {
        await store.enqueueOutbox(OutboxItem(
          id: id,
          chatId: chatId,
          payload: payload,
          createdAt: createdAt,
        ));
      }
      _messageUpdates.add(message);
      if (!isGroup) _tryDirect(chatId, id, ciphertext);
      return message;
    } catch (error, stack) {
      Log.e('message.send', error, stack);
      final failed = Message(
        id: id,
        chatId: chatId,
        senderId: myId,
        text: envelope['text'] as String? ?? '',
        kind: kind,
        status: MessageStatus.failed,
        createdAt: createdAt,
        meta: meta,
        imageBase64: imageBase64,
      );
      await store.upsertMessage(failed);
      _messageUpdates.add(failed);
      rethrow;
    }
  }

  void _dispatchSend(
    bool isGroup,
    String id,
    String chatId,
    String ciphertext,
    String wireKind,
    Map<String, dynamic> meta,
    DateTime createdAt,
  ) {
    if (isGroup) {
      realtime.sendGroupMessage(
        id: id,
        groupId: chatId,
        ciphertext: ciphertext,
        kind: wireKind,
        meta: meta,
        createdAt: createdAt,
      );
    } else {
      realtime.sendMessage(
        id: id,
        to: chatId,
        ciphertext: ciphertext,
        kind: wireKind,
        meta: meta,
        createdAt: createdAt,
      );
    }
  }

  Future<void> _tryDirect(String chatId, String id, String ciphertext) async {
    await p2p.ensureLink(chatId);
    if (p2p.isDirect(chatId)) {
      final ok = await p2p.sendAndWaitAck(chatId, id, ciphertext);
      if (ok) {
        await store.updateMessageStatus(id, MessageStatus.delivered, at: DateTime.now());
        final message = await store.getMessage(id);
        if (message != null) _messageUpdates.add(message);
      }
    }
  }

  Future<void> _handleP2PPayload(String peerId, String id, String payload) async {
    final existing = await store.getMessage(id);
    if (existing != null) return;
    await _processIncoming(
      id: id,
      senderId: peerId,
      payload: payload,
      kind: 'text',
      createdAt: DateTime.now(),
      viaRelay: false,
    );
  }

  Future<void> _onRealtimeEvent(RealtimeEvent event) async {
    switch (event.type) {
      case 'message':
        final raw = (event.data['message'] as Map?)?.cast<String, dynamic>() ?? event.data;
        final id = raw['id'] as String?;
        if (id == null) return;
        final existing = await store.getMessage(id);
        if (existing == null) {
          await _processIncoming(
            id: id,
            senderId: (raw['from'] ?? raw['senderId']) as String,
            payload: raw['ciphertext'] as String,
            kind: (raw['kind'] as String?) ?? 'text',
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              ((raw['createdAt'] as num?) ?? 0).toInt(),
            ),
            viaRelay: true,
          );
        } else {
          realtime.ackMessages([id]);
        }
      case 'group.message':
        final raw = (event.data['message'] as Map?)?.cast<String, dynamic>() ?? event.data;
        final id = raw['id'] as String?;
        final groupId = raw['groupId'] as String?;
        if (id == null || groupId == null) return;
        if (await store.getMessage(id) != null) return;
        await _processGroupIncoming(
          id: id,
          groupId: groupId,
          senderId: (raw['from'] ?? raw['senderId']) as String,
          payload: raw['ciphertext'] as String,
          kind: (raw['kind'] as String?) ?? 'text',
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            ((raw['createdAt'] as num?) ?? 0).toInt(),
          ),
        );
      case 'group.read':
        final ids = (event.data['messageIds'] as List?)
                ?.map((e) => e as String)
                .toList() ??
            const <String>[];
        if (ids.isEmpty) return;
        await store.markMessagesRead(ids, at: DateTime.now());
        for (final id in ids) {
          final message = await store.getMessage(id);
          if (message != null) _messageUpdates.add(message);
        }
      case 'message.ack':
        final id = event.data['id'] as String?;
        if (id == null) return;
        final current = await store.getMessage(id);
        if (current != null && current.status == MessageStatus.sending) {
          await store.updateMessageStatus(id, MessageStatus.sent);
          final updated = await store.getMessage(id);
          if (updated != null) _messageUpdates.add(updated);
        }
      case 'message.delivered':
        await store.markMessagesDelivered(event.ids);
        for (final id in event.ids) {
          final message = await store.getMessage(id);
          if (message != null) _messageUpdates.add(message);
        }
      case 'message.read':
        await store.markMessagesRead(event.ids, at: DateTime.now());
        for (final id in event.ids) {
          final message = await store.getMessage(id);
          if (message != null) _messageUpdates.add(message);
        }
      case 'presence':
        final userId = event.data['userId'] as String?;
        if (userId == null) return;
        final presence = presenceFromWire(event.data['status'] as String?);
        final lastSeen = event.data['lastSeen'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((event.data['lastSeen'] as num).toInt());
        await _applyPresence(userId, presence, lastSeen);
      case 'typing':
        final from = event.data['from'] as String?;
        if (from == null) return;
        _typing.add(TypingEvent(from, event.data['on'] == true));
      case 'error':
        Log.d('ws.error', '${event.data['code']}: ${event.data['message']}');
    }
  }

  Future<void> _applyPresence(String userId, Presence presence, DateTime? lastSeen) async {
    final chat = await store.getChat(userId);
    if (chat != null) {
      await store.upsertChat(chat.copyWith(peerPresence: presence, peerLastSeen: lastSeen));
    }
    final user = await store.getUser(userId);
    if (user != null) {
      final updated = user.copyWith(presence: presence, lastSeen: lastSeen);
      await store.upsertUser(updated);
      // Keep the contacts row in step with the chat tile: a contact shown as
      // "online" in chats must not look offline in the contacts tab.
      if (await store.hasContact(userId)) {
        await store.upsertContact(updated);
      }
    }
    _presence.add(PresenceEvent(userId, presence, lastSeen));
  }

  Future<void> _processIncoming({
    required String id,
    required String senderId,
    required String payload,
    required String kind,
    required DateTime createdAt,
    required bool viaRelay,
  }) async {
    // The same message can arrive over P2P and relay at once. Serialize by id so
    // only one copy is decrypted; the other is treated as already handled.
    if (_inFlight.contains(id)) {
      if (viaRelay) realtime.ackMessages([id]);
      return;
    }
    _inFlight.add(id);
    try {
      if (await store.getMessage(id) != null) {
        if (viaRelay) {
          realtime.ackMessages([id]);
          if (activeChatId == senderId) realtime.markRead(senderId, [id]);
        }
        return;
      }
      Map<String, dynamic>? envelope;
      String? decryptError;
      try {
        envelope = await signal.decrypt(senderId, payload);
      } on EncryptionException catch (error) {
        decryptError = error.code;
        Log.d('message.decrypt', error.code);
      }
      if (envelope != null) {
        await _applyDecrypted(
          envelope: envelope,
          id: id,
          senderId: senderId,
          createdAt: createdAt,
          viaRelay: viaRelay,
        );
        await _retryPending(senderId);
        return;
      }
      // The other transport already decrypted this exact message.
      if (decryptError == 'duplicate') {
        if (viaRelay) realtime.ackMessages([id]);
        return;
      }
      // Out-of-order: a regular message can land before the pre-key message that
      // opens the session. Keep the ciphertext and retry once it advances.
      final retryable = decryptError == 'no_session' ||
          decryptError == 'missing_prekey' ||
          decryptError == 'decrypt_failed';
      final isActive = activeChatId == senderId;
      final broken = Message(
        id: id,
        chatId: senderId,
        senderId: senderId,
        text: decryptError == 'identity_changed'
            ? 'Ключи собеседника изменились'
            : 'Не удалось расшифровать сообщение',
        status: MessageStatus.delivered,
        createdAt: createdAt,
        meta: {
          'undecryptable': true,
          'code': decryptError,
          if (retryable) 'enc': payload,
        },
      );
      await store.upsertMessage(broken);
      await store.touchChat(senderId,
          preview: broken.text, at: createdAt, incrementUnread: !isActive);
      if (viaRelay) realtime.ackMessages([id]);
      _messageUpdates.add(broken);
      _incoming.add(IncomingEvent(broken, isActiveChat: isActive));
    } finally {
      _inFlight.remove(id);
    }
  }

  /// Turns a successfully decrypted envelope into a stored message (or applies a
  /// control action). Shared by the live path and the out-of-order retry path.
  Future<void> _applyDecrypted({
    required Map<String, dynamic> envelope,
    required String id,
    required String senderId,
    required DateTime createdAt,
    required bool viaRelay,
    bool ack = true,
  }) async {
    final type = envelope['type'] as String? ?? 'text';
    if (type == 'reaction') {
      final targetId = envelope['targetId'] as String?;
      final emoji = envelope['reaction'] as String?;
      if (targetId != null && emoji != null) {
        final target = await store.getMessage(targetId);
        if (target != null) {
          final reactions = Map<String, List<String>>.from(target.reactions);
          final users = List<String>.from(reactions[emoji] ?? const []);
          if (!users.contains(senderId)) users.add(senderId);
          reactions[emoji] = users;
          await store.setReactions(targetId, reactions);
          _messageUpdates.add(target.copyWith(reactions: reactions));
        }
      }
      if (ack && viaRelay) realtime.ackMessages([id]);
      return;
    }
    if (type == 'delete') {
      final targetId = envelope['targetId'] as String?;
      if (targetId != null) {
        final target = await store.getMessage(targetId);
        await store.softDeleteMessage(targetId);
        if (target != null) _messageUpdates.add(target.copyWith(deleted: true, text: ''));
      }
      if (ack && viaRelay) realtime.ackMessages([id]);
      return;
    }
    if (type == 'groupKey') {
      final groupId = envelope['groupId'] as String?;
      final key = envelope['key'] as String?;
      if (groupId != null && key != null) {
        await groupCrypto.importKey(groupId, key);
        final knownBefore = await store.getChat(groupId) != null;
        var title = '';
        var avatar = '';
        try {
          final group = await api.groupDetail(groupId);
          title = group.title;
          avatar = group.avatar;
          final existing = await store.getChat(groupId);
          final base = existing ??
              Chat.group(
                id: group.id,
                title: group.title,
                avatar: group.avatar,
                memberCount: group.members.length,
              );
          await store.upsertChat(base.copyWith(
            peerName: group.title,
            peerAvatar: group.avatar,
            memberCount: group.members.length,
          ));
        } catch (error) {
          Log.e('group.key', error);
        }
        if (title.isEmpty) {
          title = envelope['title'] as String? ?? '';
        }
        // A key for an unknown group means this account was just added to it:
        // surface the group in the chat list immediately and tell the user.
        if (!knownBefore && title.isNotEmpty) {
          final now = DateTime.now();
          await store.touchChat(
            groupId,
            preview: title,
            at: now,
            incrementUnread: activeChatId != groupId,
          );
          _groups.add(GroupAddedEvent(
            groupId: groupId,
            title: title,
            avatar: avatar,
          ));
        }
      }
      if (ack && viaRelay) realtime.ackMessages([id]);
      return;
    }

    await ensureChat(senderId);
    final isActive = activeChatId == senderId;
    final image = envelope['image'] as String?;
    final fileData = envelope['data'] as String?;
    final meta = (envelope['meta'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final text = (envelope['text'] as String?) ?? '';
    final MessageKind kind = type == 'image'
        ? MessageKind.image
        : type == 'file'
            ? MessageKind.file
            : type == 'audio'
                ? MessageKind.audio
                : type == 'video'
                    ? MessageKind.video
                    : type == 'video_note'
                        ? MessageKind.videoNote
                        : MessageKind.text;
    final hasData = type == 'file' ||
        type == 'audio' ||
        type == 'video' ||
        type == 'video_note';
    final message = Message(
      id: id,
      chatId: senderId,
      senderId: senderId,
      text: text,
      kind: kind,
      status: isActive ? MessageStatus.read : MessageStatus.delivered,
      createdAt: createdAt,
      meta: hasData ? {...meta, if (fileData != null) 'data': fileData} : meta,
      imageBase64: image,
    );
    await store.upsertMessage(message);
    final preview = kind == MessageKind.image
        ? 'Фото'
        : kind == MessageKind.file
            ? 'Файл'
            : kind == MessageKind.audio
                ? 'Голосовое'
                : kind == MessageKind.video
                    ? 'Видео'
                    : kind == MessageKind.videoNote
                        ? 'Видеокружок'
                        : text;
    await store.touchChat(senderId, preview: preview, at: createdAt, incrementUnread: !isActive);
    if (isActive) await store.markChatRead(senderId);
    if (ack && viaRelay) {
      realtime.ackMessages([id]);
      if (isActive) realtime.markRead(senderId, [id]);
    }
    _messageUpdates.add(message);
    _incoming.add(IncomingEvent(message, isActiveChat: isActive));
  }

  /// Re-decrypts messages that arrived before their session existed, in
  /// chronological order, stopping at the first one still undecryptable so the
  /// ratchet is advanced strictly in sequence.
  Future<void> _retryPending(String senderId) async {
    final all = await store.getMessages(senderId, includeArchived: true, limit: 500);
    final pending = all
        .where((m) =>
            m.meta['undecryptable'] == true &&
            m.meta['enc'] is String &&
            (m.meta['code'] == 'no_session' ||
                m.meta['code'] == 'missing_prekey' ||
                m.meta['code'] == 'decrypt_failed'))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final m in pending) {
      try {
        final envelope = await signal.decrypt(senderId, m.meta['enc'] as String);
        await _applyDecrypted(
          envelope: envelope,
          id: m.id,
          senderId: senderId,
          createdAt: m.createdAt,
          viaRelay: false,
          ack: false,
        );
      } on EncryptionException {
        break;
      }
    }
  }

  Future<void> openChat(String chatId) async {
    activeChatId = chatId;
    final messages = await store.getMessages(chatId, limit: 200);
    final unreadFromPeer = messages
        .where((m) => m.senderId != myId && m.status != MessageStatus.read)
        .map((m) => m.id)
        .toList();
    if (unreadFromPeer.isNotEmpty) {
      await store.markMessagesRead(unreadFromPeer);
      realtime.markRead(chatId, unreadFromPeer);
      for (final id in unreadFromPeer) {
        final message = await store.getMessage(id);
        if (message != null) _messageUpdates.add(message);
      }
    }
    await store.markChatRead(chatId);
    await p2p.ensureLink(chatId);
  }

  void closeChat(String chatId) {
    if (activeChatId == chatId) activeChatId = null;
  }

  Future<void> retry(Message message) async {
    if (message.status != MessageStatus.failed) return;
    final Map<String, dynamic> envelope;
    final String wireKind;
    if (message.kind == MessageKind.image) {
      envelope = {
        'v': 1,
        'type': 'image',
        'image': message.imageBase64,
        'meta': message.meta,
        'text': '',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      };
      wireKind = 'image';
    } else if (message.isFile ||
        message.isAudio ||
        message.isVideo ||
        message.isVideoNote) {
      final type = messageKindToWire(message.kind);
      final data = message.meta['data'];
      final meta = <String, dynamic>{
        'mime': message.meta['mime'],
        'size': message.meta['size'],
        if (type == 'file' || type == 'video') 'name': message.meta['name'],
        if (type == 'audio' ||
            type == 'video' ||
            type == 'video_note') 'durationMs': message.meta['durationMs'],
      };
      envelope = {
        'v': 1,
        'type': type,
        'data': data,
        'meta': meta,
        'text': '',
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      };
      wireKind = type;
    } else {
      envelope = {
        'v': 1,
        'type': 'text',
        'text': message.text,
        'sentAt': DateTime.now().millisecondsSinceEpoch,
      };
      wireKind = 'text';
    }
    final ciphertext = await signal.encrypt(message.chatId, envelope);
    await store.upsertMessage(message.copyWith(status: MessageStatus.sending));
    final retryMeta = message.meta.containsKey('data')
        ? (<String, dynamic>{...message.meta}..remove('data'))
        : message.meta;
    realtime.sendMessage(
      id: message.id,
      to: message.chatId,
      ciphertext: ciphertext,
      kind: wireKind,
      meta: retryMeta,
      createdAt: message.createdAt,
    );
    await store.updateMessageStatus(message.id, MessageStatus.sent);
    final updated = await store.getMessage(message.id);
    if (updated != null) _messageUpdates.add(updated);
  }

  Future<void> dispose() async {
    _outboxTimer?.cancel();
    await _eventSubscription.cancel();
    await _statusSubscription.cancel();
    await _messageUpdates.close();
    await _incoming.close();
    await _presence.close();
    await _typing.close();
    await _directChanges.close();
    await _removed.close();
    await _groups.close();
  }
}
