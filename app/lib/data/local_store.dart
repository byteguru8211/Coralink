import '../domain/models.dart';
import '../domain/pet.dart';

class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.chatId,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
  });

  final String id;
  final String chatId;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int attempts;
}

class PetOutboxItem {
  const PetOutboxItem({
    required this.id,
    required this.petId,
    required this.action,
    required this.payload,
    required this.createdAt,
    this.attempts = 0,
  });

  final String id;
  final String petId;
  final String action;
  final String payload;
  final DateTime createdAt;
  final int attempts;
}

class PendingReadReceipt {
  const PendingReadReceipt({
    required this.messageId,
    required this.chatId,
    required this.createdAt,
  });

  final String messageId;
  final String chatId;
  final DateTime createdAt;
}

/// Persistence port. SQLite/SQLCipher on mobile and desktop, in-memory on web.
abstract class LocalStore {
  Future<void> close();
  Future<void> clearUserData();

  Future<void> upsertUser(User user);
  Future<User?> getUser(String id);

  Future<void> upsertChat(Chat chat);
  Future<Chat?> getChat(String id);
  Future<List<Chat>> getChats({bool includeArchived = true});
  Future<void> deleteChat(String id);
  Future<void> setChatFlags(
    String id, {
    bool? archived,
    bool? pinned,
    bool? muted,
  });
  Future<void> markChatRead(String id);
  Future<void> touchChat(
    String chatId, {
    required String preview,
    required DateTime at,
    bool incrementUnread = false,
  });
  Future<int> autoArchiveInactive(Duration age);

  Future<void> upsertMessage(Message message);
  Future<Message?> getMessage(String id);
  Future<void> deleteMessages(String chatId);
  Future<List<Message>> getMessages(
    String chatId, {
    int limit = 200,
    int offset = 0,
    bool includeArchived = false,
  });
  Future<List<Message>> getAllMessages({int limit = 4000});
  Future<void> updateMessageStatus(
    String id,
    MessageStatus status, {
    DateTime? at,
  });
  Future<void> markMessagesRead(List<String> ids, {DateTime? at});
  Future<void> markMessagesDelivered(List<String> ids, {DateTime? at});
  Future<void> enqueueReadReceipt(String messageId, String chatId);
  Future<List<PendingReadReceipt>> getPendingReadReceipts();
  Future<void> removeReadReceipts(List<String> ids);
  Future<void> softDeleteMessage(String id);
  Future<void> deleteMessage(String id);
  Future<void> setReactions(String id, Map<String, List<String>> reactions);
  Future<void> archiveMessagesOlderThan(Duration age);
  Future<int> countArchivedMessages(String chatId);
  Future<int> unreadTotal();

  Future<void> upsertContact(User user, {DateTime? addedAt});
  Future<List<Contact>> getContacts();
  Future<bool> hasContact(String id);
  Future<void> deleteContact(String id);

  Future<void> upsertCall(CallRecord record);
  Future<List<CallRecord>> getCalls(String peerId, {int limit = 60});

  Future<void> upsertPet(PetState pet);
  Future<PetState?> getPet(String chatId);
  Future<void> upsertPetRecord(PetRecord record);
  Future<PetRecord?> getPetRecord(String chatId);
  Future<List<PetRecord>> getPetRecords();
  Future<void> deletePet(String chatId);
  Future<void> deletePetRecord(String petId);

  Future<void> enqueuePetOperation(PetOutboxItem item);
  Future<List<PetOutboxItem>> getPetOperations();
  Future<void> removePetOperation(String id);
  Future<void> bumpPetOperationAttempts(String id);

  Future<void> enqueueOutbox(OutboxItem item);
  Future<List<OutboxItem>> getOutbox();
  Future<void> removeOutbox(String id);
  Future<void> bumpOutboxAttempts(String id);
}
