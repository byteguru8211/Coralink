import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../domain/models.dart';
import '../domain/pet.dart';
import 'local_store.dart';

/// SQLite implementation shared by Android/iOS (SQLCipher) and desktop (FFI).
/// The encryption key is supplied only by the mobile opener; the desktop build
/// is a development/preview target and stores its database unencrypted.
class SqliteLocalStore implements LocalStore {
  SqliteLocalStore(this._db);

  final Database _db;

  static const schemaVersion = 7;

  static Future<void> createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users(
        id TEXT PRIMARY KEY,
        phone TEXT NOT NULL,
        name TEXT NOT NULL,
        about TEXT NOT NULL DEFAULT '',
        avatar_color TEXT NOT NULL DEFAULT '#1A9C7A',
        avatar TEXT NOT NULL DEFAULT '',
        last_seen INTEGER,
        presence TEXT NOT NULL DEFAULT 'offline'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chats(
        id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL,
        peer_name TEXT NOT NULL,
        peer_phone TEXT NOT NULL DEFAULT '',
        peer_about TEXT NOT NULL DEFAULT '',
        peer_avatar_color TEXT NOT NULL DEFAULT '#1A9C7A',
        peer_avatar TEXT NOT NULL DEFAULT '',
        is_group INTEGER NOT NULL DEFAULT 0,
        member_count INTEGER NOT NULL DEFAULT 0,
        peer_last_seen INTEGER,
        peer_presence TEXT NOT NULL DEFAULT 'offline',
        last_message_text TEXT NOT NULL DEFAULT '',
        last_message_at INTEGER,
        unread_count INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages(
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        kind TEXT NOT NULL DEFAULT 'text',
        status TEXT NOT NULL DEFAULT 'sending',
        created_at INTEGER NOT NULL,
        delivered_at INTEGER,
        read_at INTEGER,
        meta TEXT NOT NULL DEFAULT '{}',
        image_b64 TEXT,
        reactions TEXT NOT NULL DEFAULT '{}',
        archived INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_search ON messages(created_at)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contacts(
        id TEXT PRIMARY KEY,
        phone TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL,
        about TEXT NOT NULL DEFAULT '',
        avatar_color TEXT NOT NULL DEFAULT '#1A9C7A',
        avatar TEXT NOT NULL DEFAULT '',
        last_seen INTEGER,
        presence TEXT NOT NULL DEFAULT 'offline',
        added_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS outbox(
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(_callsTable);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_calls_peer ON calls(peer_id, started_at)',
    );
    await db.execute(_petsTable);
    await db.execute(_pendingReadsTable);
    await db.execute(_petOutboxTable);
  }

  static const _pendingReadsTable = '''
      CREATE TABLE IF NOT EXISTS pending_reads(
        message_id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''';

  static const _petsTable = '''
      CREATE TABLE IF NOT EXISTS pets(
        chat_id TEXT PRIMARY KEY,
        state TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        server_id TEXT UNIQUE,
        scope TEXT NOT NULL DEFAULT 'direct',
        status TEXT NOT NULL DEFAULT 'active',
        membership_state TEXT NOT NULL DEFAULT 'active',
        role TEXT NOT NULL DEFAULT 'owner',
        seq INTEGER NOT NULL DEFAULT 0,
        members TEXT NOT NULL DEFAULT '[]',
        snapshot TEXT NOT NULL DEFAULT ''
      )
    ''';

  static const _petOutboxTable = '''
      CREATE TABLE IF NOT EXISTS pet_outbox(
        id TEXT PRIMARY KEY,
        pet_id TEXT NOT NULL,
        action TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0
      )
    ''';

  static const _callsTable = '''
      CREATE TABLE IF NOT EXISTS calls(
        id TEXT PRIMARY KEY,
        peer_id TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        video INTEGER NOT NULL DEFAULT 0,
        outgoing INTEGER NOT NULL DEFAULT 1,
        answered INTEGER NOT NULL DEFAULT 0,
        duration_seconds INTEGER NOT NULL DEFAULT 0
      )
    ''';

  /// Adds the avatar columns introduced in schema v2 for databases created
  /// before profile photos existed.
  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE users ADD COLUMN avatar TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        "ALTER TABLE chats ADD COLUMN peer_avatar TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(
        "ALTER TABLE contacts ADD COLUMN avatar TEXT NOT NULL DEFAULT ''",
      );
    }
    if (oldVersion < 3) {
      await db.execute(
        'ALTER TABLE chats ADD COLUMN is_group INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE chats ADD COLUMN member_count INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 4) {
      await db.execute(_callsTable);
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_calls_peer ON calls(peer_id, started_at)',
      );
    }
    if (oldVersion < 5) {
      await db.execute(_petsTable);
    }
    if (oldVersion < 6) {
      await db.execute(_pendingReadsTable);
    }
    if (oldVersion < 7) {
      await db.execute("ALTER TABLE pets ADD COLUMN server_id TEXT");
      await db.execute(
        "ALTER TABLE pets ADD COLUMN scope TEXT NOT NULL DEFAULT 'direct'",
      );
      await db.execute(
        "ALTER TABLE pets ADD COLUMN status TEXT NOT NULL DEFAULT 'active'",
      );
      await db.execute(
        "ALTER TABLE pets ADD COLUMN membership_state TEXT NOT NULL DEFAULT 'active'",
      );
      await db.execute(
        "ALTER TABLE pets ADD COLUMN role TEXT NOT NULL DEFAULT 'owner'",
      );
      await db.execute(
        "ALTER TABLE pets ADD COLUMN seq INTEGER NOT NULL DEFAULT 0",
      );
      await db.execute(
        "ALTER TABLE pets ADD COLUMN members TEXT NOT NULL DEFAULT '[]'",
      );
      await db.execute(
        "ALTER TABLE pets ADD COLUMN snapshot TEXT NOT NULL DEFAULT ''",
      );
      await db.execute(_petOutboxTable);
    }
  }

  @override
  Future<void> close() => _db.close();

  @override
  Future<void> clearUserData() async {
    await _db.delete('messages');
    await _db.delete('chats');
    await _db.delete('contacts');
    await _db.delete('outbox');
    await _db.delete('calls');
    await _db.delete('users');
    await _db.delete('pets');
    await _db.delete('pet_outbox');
    await _db.delete('pending_reads');
  }

  @override
  Future<void> upsertUser(User user) => _db.insert(
    'users',
    user.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<User?> getUser(String id) async {
    final rows = await _db.query(
      'users',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : User.fromRow(rows.first);
  }

  @override
  Future<void> upsertChat(Chat chat) => _db.insert(
    'chats',
    chat.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<Chat?> getChat(String id) async {
    final rows = await _db.query(
      'chats',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Chat.fromRow(rows.first);
  }

  @override
  Future<List<Chat>> getChats({bool includeArchived = true}) async {
    final rows = await _db.query(
      'chats',
      where: includeArchived ? null : 'archived = 0',
      orderBy: 'pinned DESC, COALESCE(last_message_at, updated_at, 0) DESC',
    );
    return rows.map(Chat.fromRow).toList();
  }

  @override
  Future<void> deleteChat(String id) async {
    await _db.delete('messages', where: 'chat_id = ?', whereArgs: [id]);
    await _db.delete('outbox', where: 'chat_id = ?', whereArgs: [id]);
    await _db.delete('chats', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> setChatFlags(
    String id, {
    bool? archived,
    bool? pinned,
    bool? muted,
  }) async {
    final values = <String, Object?>{};
    if (archived != null) values['archived'] = archived ? 1 : 0;
    if (pinned != null) values['pinned'] = pinned ? 1 : 0;
    if (muted != null) values['muted'] = muted ? 1 : 0;
    if (values.isEmpty) return;
    await _db.update('chats', values, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> markChatRead(String id) async {
    await _db.update(
      'chats',
      {'unread_count': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> touchChat(
    String chatId, {
    required String preview,
    required DateTime at,
    bool incrementUnread = false,
  }) async {
    await _db.rawUpdate(
      '''UPDATE chats SET last_message_text = ?, last_message_at = ?, updated_at = ?,
         unread_count = unread_count + ?, archived = 0 WHERE id = ?''',
      [
        preview,
        at.millisecondsSinceEpoch,
        at.millisecondsSinceEpoch,
        incrementUnread ? 1 : 0,
        chatId,
      ],
    );
  }

  @override
  Future<int> autoArchiveInactive(Duration age) async {
    final threshold = DateTime.now().subtract(age).millisecondsSinceEpoch;
    return _db.rawUpdate(
      '''UPDATE chats SET archived = 1
         WHERE archived = 0 AND pinned = 0
         AND COALESCE(last_message_at, updated_at, 0) < ?''',
      [threshold],
    );
  }

  @override
  Future<void> upsertMessage(Message message) => _db.insert(
    'messages',
    message.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<Message?> getMessage(String id) async {
    final rows = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Message.fromRow(rows.first);
  }

  @override
  Future<void> deleteMessages(String chatId) async {
    await _db.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);
    await _db.update(
      'chats',
      {'last_message_text': '', 'last_message_at': null, 'unread_count': 0},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  @override
  Future<List<Message>> getMessages(
    String chatId, {
    int limit = 200,
    int offset = 0,
    bool includeArchived = false,
  }) async {
    final rows = await _db.query(
      'messages',
      where: includeArchived ? 'chat_id = ?' : 'chat_id = ? AND archived = 0',
      whereArgs: [chatId],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.reversed.map(Message.fromRow).toList();
  }

  @override
  Future<List<Message>> getAllMessages({int limit = 4000}) async {
    final rows = await _db.query(
      'messages',
      where: 'deleted = 0 AND kind IN (?, ?)',
      whereArgs: ['text', 'image'],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(Message.fromRow).toList();
  }

  @override
  Future<void> updateMessageStatus(
    String id,
    MessageStatus status, {
    DateTime? at,
  }) async {
    final current = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (current.isNotEmpty) {
      final existing = messageStatusFromWire(
        current.first['status'] as String?,
      );
      if (status.index < existing.index) return;
    }
    final values = <String, Object?>{'status': messageStatusToWire(status)};
    if (at != null && status == MessageStatus.delivered) {
      values['delivered_at'] = at.millisecondsSinceEpoch;
    }
    if (at != null && status == MessageStatus.read) {
      values['read_at'] = at.millisecondsSinceEpoch;
      values['delivered_at'] = at.millisecondsSinceEpoch;
    }
    await _db.update('messages', values, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> markMessagesRead(List<String> ids, {DateTime? at}) async {
    if (ids.isEmpty) return;
    final stamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE messages SET status = ?, read_at = ?, delivered_at = COALESCE(delivered_at, ?) WHERE id IN ($placeholders) AND status != ?',
      [
        messageStatusToWire(MessageStatus.read),
        stamp,
        stamp,
        ...ids,
        messageStatusToWire(MessageStatus.read),
      ],
    );
  }

  @override
  Future<void> markMessagesDelivered(List<String> ids, {DateTime? at}) async {
    if (ids.isEmpty) return;
    final stamp = (at ?? DateTime.now()).millisecondsSinceEpoch;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.rawUpdate(
      '''UPDATE messages SET status = CASE WHEN status = ? THEN status ELSE ? END,
         delivered_at = COALESCE(delivered_at, ?) WHERE id IN ($placeholders)''',
      [
        messageStatusToWire(MessageStatus.read),
        messageStatusToWire(MessageStatus.delivered),
        stamp,
        ...ids,
      ],
    );
  }

  @override
  Future<void> enqueueReadReceipt(String messageId, String chatId) async {
    await _db.insert('pending_reads', {
      'message_id': messageId,
      'chat_id': chatId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<List<PendingReadReceipt>> getPendingReadReceipts() async {
    final rows = await _db.query('pending_reads', orderBy: 'created_at ASC');
    return rows
        .map(
          (row) => PendingReadReceipt(
            messageId: row['message_id'] as String,
            chatId: row['chat_id'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              row['created_at'] as int,
            ),
          ),
        )
        .toList();
  }

  @override
  Future<void> removeReadReceipts(List<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.delete(
      'pending_reads',
      where: 'message_id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  @override
  Future<void> softDeleteMessage(String id) => _db.update(
    'messages',
    {'deleted': 1, 'text': '', 'image_b64': null},
    where: 'id = ?',
    whereArgs: [id],
  );

  @override
  Future<void> deleteMessage(String id) =>
      _db.delete('messages', where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> setReactions(String id, Map<String, List<String>> reactions) =>
      _db.update(
        'messages',
        {'reactions': jsonEncode(reactions)},
        where: 'id = ?',
        whereArgs: [id],
      );

  @override
  Future<void> archiveMessagesOlderThan(Duration age) async {
    final threshold = DateTime.now().subtract(age).millisecondsSinceEpoch;
    await _db.rawUpdate(
      'UPDATE messages SET archived = 1 WHERE archived = 0 AND created_at < ?',
      [threshold],
    );
  }

  @override
  Future<int> countArchivedMessages(String chatId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM messages WHERE chat_id = ? AND archived = 1',
      [chatId],
    );
    return (rows.first['c'] as num).toInt();
  }

  @override
  Future<int> unreadTotal() async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(unread_count),0) AS c FROM chats',
    );
    return (rows.first['c'] as num).toInt();
  }

  @override
  Future<void> upsertContact(User user, {DateTime? addedAt}) async {
    final row = user.toRow()
      ..['added_at'] = (addedAt ?? DateTime.now()).millisecondsSinceEpoch;
    row.remove('id');
    await _db.insert('contacts', {
      'id': user.id,
      ...row,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<Contact>> getContacts() async {
    final rows = await _db.query(
      'contacts',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows
        .map(
          (row) => Contact(
            user: User.fromRow(row),
            addedAt: DateTime.fromMillisecondsSinceEpoch(
              (row['added_at'] as num).toInt(),
            ),
          ),
        )
        .toList();
  }

  @override
  Future<bool> hasContact(String id) async {
    final rows = await _db.query(
      'contacts',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> deleteContact(String id) =>
      _db.delete('contacts', where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> upsertCall(CallRecord record) => _db.insert(
    'calls',
    record.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<List<CallRecord>> getCalls(String peerId, {int limit = 60}) async {
    final rows = await _db.query(
      'calls',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.reversed.map(CallRecord.fromRow).toList();
  }

  @override
  Future<void> upsertPet(PetState pet) => _db.insert('pets', {
    'chat_id': pet.chatId,
    'state': jsonEncode(pet.toJson()),
    'updated_at': pet.revision,
    'scope': pet.chatId.startsWith('personal:')
        ? 'personal'
        : pet.chatId.startsWith('direct:')
        ? 'direct'
        : 'group',
    'status': 'active',
    'membership_state': 'active',
    'role': 'owner',
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<PetState?> getPet(String chatId) async {
    final record = await getPetRecord(chatId);
    return record?.state;
  }

  @override
  Future<void> upsertPetRecord(PetRecord record) => _db.insert('pets', {
    'chat_id': record.chatId,
    'state': jsonEncode(record.state?.toJson()),
    'updated_at': DateTime.now().millisecondsSinceEpoch,
    'server_id': record.id,
    'scope': record.scope.name,
    'status': record.status,
    'membership_state': record.membershipState,
    'role': record.role,
    'seq': record.seq,
    'members': jsonEncode(
      record.members
          .map(
            (member) => {
              'userId': member.userId,
              'role': member.role,
              'state': member.state,
              'name': member.name,
            },
          )
          .toList(),
    ),
    'snapshot': record.encryptedSnapshot,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<PetRecord?> getPetRecord(String chatId) async {
    final rows = await _db.query(
      'pets',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final rawState = jsonDecode(row['state'] as String);
    return PetRecord(
      id: row['server_id'] as String? ?? '',
      scope: PetScope.values.firstWhere(
        (scope) => scope.name == row['scope'],
        orElse: () => PetScope.direct,
      ),
      chatId: row['chat_id'] as String,
      ownerId: '',
      status: row['status'] as String? ?? 'active',
      membershipState: row['membership_state'] as String? ?? 'active',
      role: row['role'] as String? ?? 'owner',
      encryptedSnapshot: row['snapshot'] as String? ?? '',
      seq: (row['seq'] as num?)?.toInt() ?? 0,
      members:
          ((jsonDecode(row['members'] as String? ?? '[]') as List?) ?? const [])
              .whereType<Map>()
              .map(
                (member) => PetMember.fromJson(member.cast<String, dynamic>()),
              )
              .toList(),
      state: rawState is Map
          ? PetState.fromJson(rawState.cast<String, dynamic>())
          : null,
    );
  }

  @override
  Future<List<PetRecord>> getPetRecords() async {
    final rows = await _db.query('pets', orderBy: 'updated_at DESC');
    final records = <PetRecord>[];
    for (final row in rows) {
      final record = await getPetRecord(row['chat_id'] as String);
      if (record != null) records.add(record);
    }
    return records;
  }

  @override
  Future<void> deletePet(String chatId) =>
      _db.delete('pets', where: 'chat_id = ?', whereArgs: [chatId]);

  @override
  Future<void> deletePetRecord(String petId) async {
    await _db.delete('pets', where: 'server_id = ?', whereArgs: [petId]);
    await _db.delete('pet_outbox', where: 'pet_id = ?', whereArgs: [petId]);
  }

  @override
  Future<void> enqueuePetOperation(PetOutboxItem item) =>
      _db.insert('pet_outbox', {
        'id': item.id,
        'pet_id': item.petId,
        'action': item.action,
        'payload': item.payload,
        'created_at': item.createdAt.millisecondsSinceEpoch,
        'attempts': item.attempts,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<List<PetOutboxItem>> getPetOperations() async {
    final rows = await _db.query('pet_outbox', orderBy: 'created_at ASC');
    return rows
        .map(
          (row) => PetOutboxItem(
            id: row['id'] as String,
            petId: row['pet_id'] as String,
            action: row['action'] as String,
            payload: row['payload'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              row['created_at'] as int,
            ),
            attempts: (row['attempts'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
  }

  @override
  Future<void> removePetOperation(String id) =>
      _db.delete('pet_outbox', where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> bumpPetOperationAttempts(String id) async {
    await _db.rawUpdate(
      'UPDATE pet_outbox SET attempts = attempts + 1 WHERE id = ?',
      [id],
    );
  }

  @override
  Future<void> enqueueOutbox(OutboxItem item) => _db.insert('outbox', {
    'id': item.id,
    'chat_id': item.chatId,
    'payload': jsonEncode(item.payload),
    'created_at': item.createdAt.millisecondsSinceEpoch,
    'attempts': item.attempts,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<List<OutboxItem>> getOutbox() async {
    final rows = await _db.query('outbox', orderBy: 'created_at ASC');
    return rows
        .map(
          (row) => OutboxItem(
            id: row['id'] as String,
            chatId: row['chat_id'] as String,
            payload:
                jsonDecode(row['payload'] as String) as Map<String, dynamic>,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              (row['created_at'] as num).toInt(),
            ),
            attempts: (row['attempts'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
  }

  @override
  Future<void> removeOutbox(String id) =>
      _db.delete('outbox', where: 'id = ?', whereArgs: [id]);

  @override
  Future<void> bumpOutboxAttempts(String id) => _db.rawUpdate(
    'UPDATE outbox SET attempts = attempts + 1 WHERE id = ?',
    [id],
  );
}
