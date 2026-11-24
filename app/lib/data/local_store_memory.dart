import 'local_store.dart';
import '../domain/models.dart';
import '../domain/pet.dart';

/// Ephemeral store used by the web build. Chats live in memory only, so the
/// web target is a demo/preview surface; mobile and desktop persist data.
class MemoryLocalStore implements LocalStore {
  final _users = <String, User>{};
  final _chats = <String, Chat>{};
  final _messages = <String, Message>{};
  final _contacts = <String, Contact>{};
  final _outbox = <String, OutboxItem>{};
  final _calls = <CallRecord>[];
  final _pets = <String, PetState>{};
  final _petRecords = <String, PetRecord>{};
  final _petOutbox = <String, PetOutboxItem>{};
  final _pendingReads = <String, PendingReadReceipt>{};

  @override
  Future<void> close() async {}

  @override
  Future<void> clearUserData() async {
    _users.clear();
    _chats.clear();
    _messages.clear();
    _contacts.clear();
    _outbox.clear();
    _calls.clear();
    _pets.clear();
    _petRecords.clear();
    _petOutbox.clear();
    _pendingReads.clear();
  }

  @override
  Future<void> upsertUser(User user) async => _users[user.id] = user;

  @override
  Future<User?> getUser(String id) async => _users[id];

  @override
  Future<void> upsertChat(Chat chat) async => _chats[chat.id] = chat;

  @override
  Future<Chat?> getChat(String id) async => _chats[id];

  @override
  Future<List<Chat>> getChats({bool includeArchived = true}) async {
    final list = _chats.values
        .where((c) => includeArchived || !c.archived)
        .toList();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.sortStamp.compareTo(a.sortStamp);
    });
    return list;
  }

  @override
  Future<void> deleteChat(String id) async {
    _chats.remove(id);
    _messages.removeWhere((_, m) => m.chatId == id);
    _outbox.removeWhere((_, o) => o.chatId == id);
  }

  @override
  Future<void> setChatFlags(
    String id, {
    bool? archived,
    bool? pinned,
    bool? muted,
  }) async {
    final chat = _chats[id];
    if (chat == null) return;
    _chats[id] = chat.copyWith(
      archived: archived,
      pinned: pinned,
      muted: muted,
    );
  }

  @override
  Future<void> markChatRead(String id) async {
    final chat = _chats[id];
    if (chat == null) return;
    _chats[id] = chat.copyWith(unreadCount: 0);
  }

  @override
  Future<void> touchChat(
    String chatId, {
    required String preview,
    required DateTime at,
    bool incrementUnread = false,
  }) async {
    final chat = _chats[chatId];
    if (chat == null) return;
    _chats[chatId] = chat.copyWith(
      lastMessageText: preview,
      lastMessageAt: at,
      updatedAt: at,
      archived: false,
      unreadCount: chat.unreadCount + (incrementUnread ? 1 : 0),
    );
  }

  @override
  Future<int> autoArchiveInactive(Duration age) async {
    final threshold = DateTime.now().subtract(age);
    var count = 0;
    for (final entry in _chats.entries.toList()) {
      final chat = entry.value;
      final stamp = chat.lastMessageAt ?? chat.updatedAt ?? DateTime(2000);
      if (!chat.archived && !chat.pinned && stamp.isBefore(threshold)) {
        _chats[entry.key] = chat.copyWith(archived: true);
        count++;
      }
    }
    return count;
  }

  @override
  Future<void> upsertMessage(Message message) async =>
      _messages[message.id] = message;

  @override
  Future<Message?> getMessage(String id) async => _messages[id];

  @override
  Future<void> deleteMessages(String chatId) async {
    _messages.removeWhere((_, message) => message.chatId == chatId);
    final chat = _chats[chatId];
    if (chat != null) {
      _chats[chatId] = chat.copyWith(lastMessageText: '', unreadCount: 0);
    }
  }

  @override
  Future<List<Message>> getMessages(
    String chatId, {
    int limit = 200,
    int offset = 0,
    bool includeArchived = false,
  }) async {
    final list =
        _messages.values
            .where(
              (m) => m.chatId == chatId && (includeArchived || !m.archived),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final page = list.skip(offset).take(limit).toList().reversed.toList();
    return page;
  }

  @override
  Future<List<Message>> getAllMessages({int limit = 4000}) async {
    final list =
        _messages.values.where((m) => !m.deleted && !m.isControl).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list.take(limit).toList();
  }

  @override
  Future<void> updateMessageStatus(
    String id,
    MessageStatus status, {
    DateTime? at,
  }) async {
    final message = _messages[id];
    if (message == null || status.index < message.status.index) return;
    _messages[id] = message.copyWith(
      status: status,
      deliveredAt: status == MessageStatus.delivered
          ? (at ?? DateTime.now())
          : status == MessageStatus.read
          ? (message.deliveredAt ?? at ?? DateTime.now())
          : message.deliveredAt,
      readAt: status == MessageStatus.read
          ? (at ?? DateTime.now())
          : message.readAt,
    );
  }

  @override
  Future<void> markMessagesRead(List<String> ids, {DateTime? at}) async {
    final stamp = at ?? DateTime.now();
    for (final id in ids) {
      final m = _messages[id];
      if (m != null) {
        _messages[id] = m.copyWith(
          status: MessageStatus.read,
          readAt: stamp,
          deliveredAt: m.deliveredAt ?? stamp,
        );
      }
    }
  }

  @override
  Future<void> markMessagesDelivered(List<String> ids, {DateTime? at}) async {
    final stamp = at ?? DateTime.now();
    for (final id in ids) {
      final m = _messages[id];
      if (m != null && m.status != MessageStatus.read) {
        _messages[id] = m.copyWith(
          status: MessageStatus.delivered,
          deliveredAt: m.deliveredAt ?? stamp,
        );
      }
    }
  }

  @override
  Future<void> softDeleteMessage(String id) async {
    final m = _messages[id];
    if (m != null) _messages[id] = m.copyWith(deleted: true, text: '');
  }

  @override
  Future<void> deleteMessage(String id) async => _messages.remove(id);

  @override
  Future<void> setReactions(
    String id,
    Map<String, List<String>> reactions,
  ) async {
    final m = _messages[id];
    if (m != null) _messages[id] = m.copyWith(reactions: reactions);
  }

  @override
  Future<void> archiveMessagesOlderThan(Duration age) async {
    final threshold = DateTime.now().subtract(age);
    for (final entry in _messages.entries.toList()) {
      if (!entry.value.archived && entry.value.createdAt.isBefore(threshold)) {
        _messages[entry.key] = entry.value.copyWith(archived: true);
      }
    }
  }

  @override
  Future<int> countArchivedMessages(String chatId) async =>
      _messages.values.where((m) => m.chatId == chatId && m.archived).length;

  @override
  Future<int> unreadTotal() async =>
      _chats.values.fold<int>(0, (sum, chat) => sum + chat.unreadCount);

  @override
  Future<void> upsertContact(User user, {DateTime? addedAt}) async =>
      _contacts[user.id] = Contact(
        user: user,
        addedAt: addedAt ?? DateTime.now(),
      );

  @override
  Future<List<Contact>> getContacts() async {
    final list = _contacts.values.toList()
      ..sort(
        (a, b) =>
            a.user.name.toLowerCase().compareTo(b.user.name.toLowerCase()),
      );
    return list;
  }

  @override
  Future<bool> hasContact(String id) async => _contacts.containsKey(id);

  @override
  Future<void> deleteContact(String id) async => _contacts.remove(id);

  @override
  Future<void> upsertCall(CallRecord record) async {
    _calls.removeWhere((call) => call.id == record.id);
    _calls.add(record);
  }

  @override
  Future<List<CallRecord>> getCalls(String peerId, {int limit = 60}) async {
    final list = _calls.where((call) => call.peerId == peerId).toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final tail = list.length > limit ? list.sublist(list.length - limit) : list;
    return tail;
  }

  @override
  Future<void> upsertPet(PetState pet) async => _pets[pet.chatId] = pet;

  @override
  Future<PetState?> getPet(String chatId) async =>
      _petRecords[chatId]?.state ?? _pets[chatId];

  @override
  Future<void> upsertPetRecord(PetRecord record) async {
    _petRecords[record.chatId] = record;
    _pets.remove(record.chatId);
  }

  @override
  Future<PetRecord?> getPetRecord(String chatId) async {
    final record = _petRecords[chatId];
    if (record != null) return record;
    final pet = _pets[chatId];
    if (pet == null) return null;
    return PetRecord(
      id: '',
      scope: pet.chatId.startsWith('personal:')
          ? PetScope.personal
          : pet.chatId.startsWith('direct:')
          ? PetScope.direct
          : PetScope.group,
      chatId: pet.chatId,
      ownerId: pet.adopterId,
      status: 'active',
      membershipState: 'active',
      role: 'owner',
      encryptedSnapshot: '',
      seq: 0,
      members: const [],
      state: pet,
    );
  }

  @override
  Future<List<PetRecord>> getPetRecords() async {
    final records = _petRecords.values.toList();
    for (final pet in _pets.values) {
      if (!_petRecords.containsKey(pet.chatId)) {
        records.add((await getPetRecord(pet.chatId))!);
      }
    }
    return records;
  }

  @override
  Future<void> deletePet(String chatId) async {
    _pets.remove(chatId);
    _petRecords.remove(chatId);
  }

  @override
  Future<void> deletePetRecord(String petId) async {
    _petRecords.removeWhere((_, record) => record.id == petId);
    _petOutbox.removeWhere((_, item) => item.petId == petId);
  }

  @override
  Future<void> enqueuePetOperation(PetOutboxItem item) async =>
      _petOutbox[item.id] = item;

  @override
  Future<List<PetOutboxItem>> getPetOperations() async =>
      _petOutbox.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> removePetOperation(String id) async => _petOutbox.remove(id);

  @override
  Future<void> bumpPetOperationAttempts(String id) async {
    final item = _petOutbox[id];
    if (item == null) return;
    _petOutbox[id] = PetOutboxItem(
      id: item.id,
      petId: item.petId,
      action: item.action,
      payload: item.payload,
      createdAt: item.createdAt,
      attempts: item.attempts + 1,
    );
  }

  @override
  Future<void> enqueueReadReceipt(String messageId, String chatId) async {
    _pendingReads[messageId] = PendingReadReceipt(
      messageId: messageId,
      chatId: chatId,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<List<PendingReadReceipt>> getPendingReadReceipts() async =>
      _pendingReads.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> removeReadReceipts(List<String> ids) async {
    for (final id in ids) {
      _pendingReads.remove(id);
    }
  }

  @override
  Future<void> enqueueOutbox(OutboxItem item) async => _outbox[item.id] = item;

  @override
  Future<List<OutboxItem>> getOutbox() async {
    final list = _outbox.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  @override
  Future<void> removeOutbox(String id) async => _outbox.remove(id);

  @override
  Future<void> bumpOutboxAttempts(String id) async {
    final item = _outbox[id];
    if (item == null) return;
    _outbox[id] = OutboxItem(
      id: item.id,
      chatId: item.chatId,
      payload: item.payload,
      createdAt: item.createdAt,
      attempts: item.attempts + 1,
    );
  }
}
