import 'dart:async';

import 'package:uuid/uuid.dart';

import '../core/log.dart';
import '../data/api_client.dart';
import '../data/local_store.dart';
import '../domain/models.dart';
import '../network/p2p.dart';
import '../network/realtime.dart';
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
  final RealtimeService realtime;
  final P2PManager p2p;
  final String myId;

  final _messageUpdates = StreamController<Message>.broadcast();
  final _incoming = StreamController<IncomingEvent>.broadcast();
  final _presence = StreamController<PresenceEvent>.broadcast();
  final _typing = StreamController<TypingEvent>.broadcast();
  final _directChanges = StreamController<({String peerId, bool direct})>.broadcast();
  final _removed = StreamController<String>.broadcast();
  final directPeers = <String>{};

  late final StreamSubscription<RealtimeEvent> _eventSubscription;
  late final StreamSubscription<RealtimeStatus> _statusSubscription;
  Timer? _outboxTimer;
  String? activeChatId;
  final int _maxRawImageBytes = 340 * 1024;

  Stream<Message> get messageUpdates => _messageUpdates.stream;
  Stream<IncomingEvent> get incoming => _incoming.stream;
  Stream<PresenceEvent> get presenceEvents => _presence.stream;
  Stream<TypingEvent> get typingEvents => _typing.stream;
  Stream<({String peerId, bool direct})> get directChanges => _directChanges.stream;
  Stream<String> get removedMessages => _removed.stream;

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
      await flushOutbox();
    } catch (error) {
      Log.e('message.sync', error);
    }
  }

  Future<void> flushOutbox() async {
    if (!realtime.isConnected) return;
    final pending = await store.getOutbox();
    for (final item in pending) {
      realtime.sendMessage(
        id: item.payload['id'] as String,
        to: item.payload['to'] as String,
        ciphertext: item.payload['ciphertext'] as String,
        kind: item.payload['kind'] as String,
        meta: (item.payload['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: DateTime.fromMillisecondsSinceEpoch(
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
          peerPresence: peer.presence,
          peerLastSeen: peer.lastSeen,
        );
        await store.upsertChat(updated);
        return updated;
      }
      return existing;
    }
    var user = peer;
    if (user == null) {
      try {
        user = await api.getUser(peerId);
      } catch (_) {
        user = User(id: peerId, phone: '', name: 'Coralink');
      }
    }
    await store.upsertUser(user);
    final chat = Chat.fromUser(user);
    await store.upsertChat(chat);
    return chat;
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
    Message message;
    try {
      final ciphertext = await signal.encrypt(chatId, envelope);
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
      final payload = {
        'id': id,
        'to': chatId,
        'ciphertext': ciphertext,
        'kind': kind == MessageKind.image ? 'image' : kind == MessageKind.text ? 'text' : 'control',
        'meta': meta,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };
      if (realtime.isConnected) {
        realtime.sendMessage(
          id: id,
          to: chatId,
          ciphertext: ciphertext,
          kind: payload['kind'] as String,
          meta: meta,
          createdAt: createdAt,
        );
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
      _tryDirect(chatId, id, ciphertext);
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
      case 'message.ack':
        final id = event.data['id'] as String?;
        if (id == null) return;
        // "delivered" here means the recipient's socket is online; the explicit
        // delivered receipt arrives separately after client-side ack.
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
      await store.upsertUser(user.copyWith(presence: presence, lastSeen: lastSeen));
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
    if (await store.getMessage(id) != null) {
      if (viaRelay) {
        realtime.ackMessages([id]);
        if (activeChatId == senderId) realtime.markRead(senderId, [id]);
      }
      return;
    }
    Map<String, dynamic>? envelope;
    try {
      envelope = await signal.decrypt(senderId, payload);
    } on EncryptionException catch (error) {
      Log.d('message.decrypt', error.code);
    }
    final chat = await ensureChat(senderId);
    final isActive = activeChatId == senderId;
    if (envelope == null) {
      final broken = Message(
        id: id,
        chatId: senderId,
        senderId: senderId,
        text: 'Не удалось расшифровать сообщение',
        status: MessageStatus.delivered,
        createdAt: createdAt,
        meta: const {'undecryptable': true},
      );
      await store.upsertMessage(broken);
      await store.touchChat(senderId, preview: broken.text, at: createdAt, incrementUnread: !isActive);
      if (viaRelay) realtime.ackMessages([id]);
      _messageUpdates.add(broken);
      _incoming.add(IncomingEvent(broken, isActiveChat: isActive));
      return;
    }

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
      if (viaRelay) realtime.ackMessages([id]);
      return;
    }
    if (type == 'delete') {
      final targetId = envelope['targetId'] as String?;
      if (targetId != null) {
        final target = await store.getMessage(targetId);
        await store.softDeleteMessage(targetId);
        if (target != null) _messageUpdates.add(target.copyWith(deleted: true, text: ''));
      }
      if (viaRelay) realtime.ackMessages([id]);
      return;
    }

    final image = envelope['image'] as String?;
    final meta = (envelope['meta'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final text = (envelope['text'] as String?) ?? '';
    final message = Message(
      id: id,
      chatId: senderId,
      senderId: senderId,
      text: text,
      kind: type == 'image' ? MessageKind.image : MessageKind.text,
      status: isActive ? MessageStatus.read : MessageStatus.delivered,
      createdAt: createdAt,
      meta: meta,
      imageBase64: image,
    );
    await store.upsertMessage(message);
    final preview = type == 'image' ? 'Фото' : text;
    await store.touchChat(senderId, preview: preview, at: createdAt, incrementUnread: !isActive);
    if (isActive) {
      await store.markChatRead(senderId);
    }
    if (viaRelay) {
      realtime.ackMessages([id]);
      if (isActive) realtime.markRead(senderId, [id]);
    }
    _messageUpdates.add(message);
    _incoming.add(IncomingEvent(message, isActiveChat: isActive));
    if (chat.peerName == 'Coralink' && chat.peerPhone.isEmpty) {
      // Profile may have arrived since the placeholder chat was created.
      unawaited(ensureChat(senderId));
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
    final envelope = message.kind == MessageKind.image
        ? {
            'v': 1,
            'type': 'image',
            'image': message.imageBase64,
            'meta': message.meta,
            'text': '',
            'sentAt': DateTime.now().millisecondsSinceEpoch,
          }
        : {'v': 1, 'type': 'text', 'text': message.text, 'sentAt': DateTime.now().millisecondsSinceEpoch};
    final ciphertext = await signal.encrypt(message.chatId, envelope);
    await store.upsertMessage(message.copyWith(status: MessageStatus.sending));
    realtime.sendMessage(
      id: message.id,
      to: message.chatId,
      ciphertext: ciphertext,
      kind: message.kind == MessageKind.image ? 'image' : 'text',
      meta: message.meta,
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
  }
}
