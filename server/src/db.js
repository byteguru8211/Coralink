'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const { escapeLike } = require('./lib/validate');

// Canonical users table definition. Shared by the initial schema and by the
// legacy-database rebuild: older databases declared phone as NOT NULL, which
// blocks nickname-only accounts (phone is optional in the current model).
function usersTableSql(tableName) {
  return `CREATE TABLE IF NOT EXISTS ${tableName} (
  id TEXT PRIMARY KEY,
  phone TEXT UNIQUE,
  username TEXT UNIQUE,
  name TEXT NOT NULL,
  about TEXT DEFAULT '',
  avatar_color TEXT DEFAULT '#1A9C7A',
  avatar TEXT DEFAULT '',
  password_hash TEXT,
  created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  identity_key TEXT,
  registration_id INTEGER,
  signed_prekey_id INTEGER,
  signed_prekey TEXT,
  signed_prekey_signature TEXT,
  presence_visibility TEXT NOT NULL DEFAULT 'contacts'
)`;
}

const SCHEMA = `
${usersTableSql('users')};

CREATE TABLE IF NOT EXISTS prekeys (
  user_id TEXT,
  key_id INTEGER,
  public_key TEXT,
  PRIMARY KEY(user_id, key_id)
);

CREATE TABLE IF NOT EXISTS auth_codes (
  phone TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts INTEGER DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS contacts (
  user_id TEXT,
  contact_id TEXT,
  created_at INTEGER,
  PRIMARY KEY(user_id, contact_id)
);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  sender_id TEXT NOT NULL,
  recipient_id TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'text',
  meta TEXT DEFAULT '{}',
  created_at INTEGER NOT NULL,
  delivered_at INTEGER,
  read_at INTEGER,
  expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS push_tokens (
  user_id TEXT,
  token TEXT,
  platform TEXT,
  created_at INTEGER,
  PRIMARY KEY(user_id, token)
);

CREATE TABLE IF NOT EXISTS groups (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  avatar TEXT DEFAULT '',
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS group_members (
  group_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at INTEGER NOT NULL,
  PRIMARY KEY(group_id, user_id)
);

CREATE TABLE IF NOT EXISTS group_messages (
  id TEXT PRIMARY KEY,
  group_id TEXT NOT NULL,
  sender_id TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'text',
  meta TEXT DEFAULT '{}',
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS group_message_receipts (
  message_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  delivered_at INTEGER,
  read_at INTEGER,
  PRIMARY KEY(message_id, user_id)
);

CREATE TABLE IF NOT EXISTS key_backup (
  user_id TEXT PRIMARY KEY,
  blob TEXT NOT NULL,
  salt TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS pets (
  id TEXT PRIMARY KEY,
  scope TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  owner_id TEXT NOT NULL,
  status TEXT NOT NULL,
  snapshot TEXT NOT NULL DEFAULT '',
  snapshot_seq INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS pet_members (
  pet_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  role TEXT NOT NULL,
  state TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY(pet_id, user_id)
);

CREATE TABLE IF NOT EXISTS pet_operations (
  id TEXT PRIMARY KEY,
  pet_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(pet_id, seq)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pets_personal
  ON pets(owner_id) WHERE scope = 'personal' AND status != 'archived';
CREATE UNIQUE INDEX IF NOT EXISTS idx_pets_scope_chat
  ON pets(scope, chat_id) WHERE status != 'archived';
CREATE INDEX IF NOT EXISTS idx_pet_members_user ON pet_members(user_id, state);
CREATE INDEX IF NOT EXISTS idx_pet_operations_pet ON pet_operations(pet_id, seq);

CREATE INDEX IF NOT EXISTS idx_messages_recipient_delivered
  ON messages(recipient_id, delivered_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_contacts_user ON contacts(user_id);
CREATE INDEX IF NOT EXISTS idx_users_phone ON users(phone);
CREATE INDEX IF NOT EXISTS idx_group_members_user ON group_members(user_id);
CREATE INDEX IF NOT EXISTS idx_group_messages_group
  ON group_messages(group_id, created_at);
CREATE INDEX IF NOT EXISTS idx_group_receipts_user
  ON group_message_receipts(user_id, delivered_at);
`;

function mapUser(row) {
  if (!row) return null;
  return {
    id: row.id,
    phone: row.phone ?? null,
    username: row.username ?? null,
    name: row.name,
    about: row.about || '',
    avatarColor: row.avatar_color || '#1A9C7A',
    avatar: row.avatar || '',
    passwordHash: row.password_hash || null,
    presenceVisibility: row.presence_visibility || 'contacts',
    createdAt: row.created_at,
    lastSeen: row.last_seen,
    identityKey: row.identity_key || null,
    registrationId:
      row.registration_id === null || row.registration_id === undefined
        ? null
        : Number(row.registration_id),
    signedPreKeyId:
      row.signed_prekey_id === null || row.signed_prekey_id === undefined
        ? null
        : Number(row.signed_prekey_id),
    signedPreKey: row.signed_prekey || null,
    signedPreKeySignature: row.signed_prekey_signature || null,
  };
}

function safeParseMeta(value) {
  if (!value) return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed
      : {};
  } catch {
    return {};
  }
}

function mapMessage(row) {
  if (!row) return null;
  return {
    id: row.id,
    senderId: row.sender_id,
    recipientId: row.recipient_id,
    ciphertext: row.ciphertext,
    kind: row.kind || 'text',
    meta: safeParseMeta(row.meta),
    createdAt: Number(row.created_at),
    deliveredAt:
      row.delivered_at === null || row.delivered_at === undefined
        ? null
        : Number(row.delivered_at),
    readAt:
      row.read_at === null || row.read_at === undefined
        ? null
        : Number(row.read_at),
    expiresAt: Number(row.expires_at),
  };
}

function mapGroupMessage(row) {
  if (!row) return null;
  return {
    id: row.id,
    groupId: row.group_id,
    senderId: row.sender_id,
    ciphertext: row.ciphertext,
    kind: row.kind || 'text',
    meta: safeParseMeta(row.meta),
    createdAt: Number(row.created_at),
    expiresAt: Number(row.expires_at),
  };
}

class CoralinkDatabase {
  constructor(filePath) {
    this.filePath = filePath;
    if (filePath !== ':memory:') {
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
    }
    this.db = new DatabaseSync(filePath);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      PRAGMA busy_timeout = 5000;
    `);
    this.db.function('unicode_lower', { deterministic: true }, (value) =>
      typeof value === 'string' ? value.toLowerCase() : value,
    );
    this.db.exec(SCHEMA);
    const userColumns = this.db.prepare('PRAGMA table_info(users)').all();
    if (!userColumns.some((column) => column.name === 'presence_visibility')) {
      this.db.exec(
        "ALTER TABLE users ADD COLUMN presence_visibility TEXT NOT NULL DEFAULT 'contacts'",
      );
    }
    if (!userColumns.some((column) => column.name === 'username')) {
      this.db.exec('ALTER TABLE users ADD COLUMN username TEXT');
      this.db.exec(
        'CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)',
      );
    }
    if (!userColumns.some((column) => column.name === 'avatar')) {
      this.db.exec("ALTER TABLE users ADD COLUMN avatar TEXT DEFAULT ''");
    }
    if (!userColumns.some((column) => column.name === 'password_hash')) {
      this.db.exec('ALTER TABLE users ADD COLUMN password_hash TEXT');
    }
    const backupColumns = this.db.prepare('PRAGMA table_info(key_backup)').all();
    if (!backupColumns.some((column) => column.name === 'revision')) {
      this.db.exec('ALTER TABLE key_backup ADD COLUMN revision INTEGER NOT NULL DEFAULT 0');
    }
    // Legacy databases declared phone as NOT NULL, which rejects nickname-only
    // accounts. SQLite cannot drop a constraint in place, so rebuild the table.
    const phoneColumn = this.db
      .prepare('PRAGMA table_info(users)')
      .all()
      .find((column) => column.name === 'phone');
    if (phoneColumn && Number(phoneColumn.notnull) === 1) {
      this.rebuildUsersTable();
    }
    // These indexes can only be created once the columns exist (and after a
    // rebuild, which drops the table's indexes), so they run here rather than
    // in SCHEMA: older databases predate username/avatar/password_hash.
    this.db.exec('CREATE INDEX IF NOT EXISTS idx_users_phone ON users(phone)');
    this.db.exec(
      'CREATE INDEX IF NOT EXISTS idx_users_username ON users(username)',
    );

    this.stmts = {
      getUserById: this.db.prepare('SELECT * FROM users WHERE id = ?'),
      getUserByPhone: this.db.prepare('SELECT * FROM users WHERE phone = ?'),
      getUserByUsername: this.db.prepare(
        'SELECT * FROM users WHERE username = ?',
      ),
      insertUser: this.db.prepare(`
        INSERT INTO users
          (id, phone, username, name, about, avatar_color, avatar, password_hash, created_at, last_seen)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `),
      updateUserProfile: this.db.prepare(`
        UPDATE users
        SET name = COALESCE(?, name),
            about = COALESCE(?, about),
            avatar_color = COALESCE(?, avatar_color),
            avatar = COALESCE(?, avatar),
            presence_visibility = COALESCE(?, presence_visibility)
        WHERE id = ?
      `),
      touchLastSeen: this.db.prepare(
        'UPDATE users SET last_seen = ? WHERE id = ?',
      ),
      searchBoth: this.db.prepare(`
        SELECT * FROM users
        WHERE id <> ?
          AND (
            phone LIKE ? ESCAPE '!'
            OR unicode_lower(name) LIKE unicode_lower(?) ESCAPE '!'
            OR unicode_lower(username) LIKE unicode_lower(?) ESCAPE '!'
          )
        ORDER BY unicode_lower(name), id
        LIMIT ?
      `),
      searchName: this.db.prepare(`
        SELECT * FROM users
        WHERE id <> ?
          AND (
            unicode_lower(name) LIKE unicode_lower(?) ESCAPE '!'
            OR unicode_lower(username) LIKE unicode_lower(?) ESCAPE '!'
          )
        ORDER BY unicode_lower(name), id
        LIMIT ?
      `),

      listContacts: this.db.prepare(`
        SELECT u.* FROM contacts c
        JOIN users u ON u.id = c.contact_id
        WHERE c.user_id = ?
        ORDER BY unicode_lower(u.name), u.id
      `),
      addContact: this.db.prepare(
        'INSERT OR IGNORE INTO contacts (user_id, contact_id, created_at) VALUES (?, ?, ?)',
      ),
      removeContact: this.db.prepare(
        'DELETE FROM contacts WHERE user_id = ? AND contact_id = ?',
      ),
      contactHolders: this.db.prepare(
        'SELECT user_id FROM contacts WHERE contact_id = ?',
      ),

      getAuthCode: this.db.prepare(
        'SELECT * FROM auth_codes WHERE phone = ?',
      ),
      upsertAuthCode: this.db.prepare(`
        INSERT INTO auth_codes
          (phone, code_hash, expires_at, attempts, created_at)
        VALUES (?, ?, ?, 0, ?)
        ON CONFLICT(phone) DO UPDATE SET
          code_hash = excluded.code_hash,
          expires_at = excluded.expires_at,
          attempts = 0,
          created_at = excluded.created_at
      `),
      incrementAuthCodeAttempts: this.db.prepare(
        'UPDATE auth_codes SET attempts = attempts + 1 WHERE phone = ?',
      ),
      deleteAuthCode: this.db.prepare(
        'DELETE FROM auth_codes WHERE phone = ?',
      ),

      updateUserKeys: this.db.prepare(`
        UPDATE users
        SET identity_key = ?,
            registration_id = ?,
            signed_prekey_id = ?,
            signed_prekey = ?,
            signed_prekey_signature = ?
        WHERE id = ?
      `),
      insertPreKey: this.db.prepare(`
        INSERT OR IGNORE INTO prekeys (user_id, key_id, public_key)
        VALUES (?, ?, ?)
      `),
      firstPreKey: this.db.prepare(`
        SELECT key_id, public_key FROM prekeys
        WHERE user_id = ?
        ORDER BY key_id ASC
        LIMIT 1
      `),
      deletePreKey: this.db.prepare(
        'DELETE FROM prekeys WHERE user_id = ? AND key_id = ?',
      ),

      insertMessage: this.db.prepare(`
        INSERT OR IGNORE INTO messages
          (id, sender_id, recipient_id, ciphertext, kind, meta, created_at, delivered_at, read_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
      `),
      getMessageById: this.db.prepare(
        'SELECT * FROM messages WHERE id = ?',
      ),
      getQueuedMessages: this.db.prepare(`
        SELECT * FROM messages
        WHERE recipient_id = ?
          AND delivered_at IS NULL
          AND expires_at > ?
        ORDER BY created_at ASC, id ASC
        LIMIT ?
      `),
      getUndeliveredForRecipient: this.db.prepare(`
        SELECT id, sender_id FROM messages
        WHERE id = ? AND recipient_id = ? AND delivered_at IS NULL
      `),
      markDelivered: this.db.prepare(`
        UPDATE messages
        SET delivered_at = ?
        WHERE id = ? AND recipient_id = ? AND delivered_at IS NULL
      `),
      getUnreadForChat: this.db.prepare(`
        SELECT id FROM messages
        WHERE id = ?
          AND recipient_id = ?
          AND sender_id = ?
          AND read_at IS NULL
      `),
      markRead: this.db.prepare(`
        UPDATE messages
        SET delivered_at = COALESCE(delivered_at, ?),
            read_at = ?
        WHERE id = ? AND recipient_id = ? AND sender_id = ?
      `),
      cleanupMessages: this.db.prepare(
        'DELETE FROM messages WHERE expires_at < ?',
      ),

      removeTokenForOthers: this.db.prepare(
        'DELETE FROM push_tokens WHERE token = ? AND user_id <> ?',
      ),
      upsertPushToken: this.db.prepare(`
        INSERT INTO push_tokens (user_id, token, platform, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(user_id, token) DO UPDATE SET
          platform = excluded.platform,
          created_at = excluded.created_at
      `),
      deletePushToken: this.db.prepare(
        'DELETE FROM push_tokens WHERE user_id = ? AND token = ?',
      ),
    };

    this.cleanupExpiredMessages();
    this.cleanupExpiredGroupMessages();
    this.cleanupTimer = setInterval(() => {
      try {
        this.cleanupExpiredMessages();
        this.cleanupExpiredGroupMessages();
      } catch {
        // The next interval or startup cleanup will retry. Avoid crashing the
        // process because of a transient storage error.
      }
    }, 10 * 60 * 1000);
    this.cleanupTimer.unref();
  }

  // Copy rows from a legacy users table (phone NOT NULL) into the canonical
  // definition and swap the tables. Indexes on users are recreated by the
  // caller after this runs.
  rebuildUsersTable() {
    const columns = [
      'id',
      'phone',
      'username',
      'name',
      'about',
      'avatar_color',
      'avatar',
      'password_hash',
      'created_at',
      'last_seen',
      'identity_key',
      'registration_id',
      'signed_prekey_id',
      'signed_prekey',
      'signed_prekey_signature',
      'presence_visibility',
    ].join(', ');
    this.transaction(() => {
      this.db.exec('DROP TABLE IF EXISTS users_rebuild');
      this.db.exec(usersTableSql('users_rebuild'));
      this.db.exec(
        `INSERT INTO users_rebuild (${columns}) SELECT ${columns} FROM users`,
      );
      this.db.exec('DROP TABLE users');
      this.db.exec('ALTER TABLE users_rebuild RENAME TO users');
    });
  }

  transaction(callback) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = callback();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      try {
        this.db.exec('ROLLBACK');
      } catch {
        // Preserve the original error.
      }
      throw error;
    }
  }

  getUserById(id) {
    return mapUser(this.stmts.getUserById.get(id));
  }

  getUserByPhone(phone) {
    return mapUser(this.stmts.getUserByPhone.get(phone));
  }

  getUserByUsername(username) {
    return mapUser(this.stmts.getUserByUsername.get(username));
  }

  createUser({
    id,
    phone = null,
    username = null,
    name,
    about = '',
    avatarColor = '#1A9C7A',
    avatar = '',
    passwordHash = null,
    createdAt = Date.now(),
    lastSeen = Date.now(),
  }) {
    this.stmts.insertUser.run(
      id,
      phone,
      username,
      name,
      about,
      avatarColor,
      avatar,
      passwordHash,
      createdAt,
      lastSeen,
    );
    return this.getUserById(id);
  }

  updateUserProfile(
    id,
    {
      name = null,
      about = null,
      avatarColor = null,
      avatar = null,
      presenceVisibility = null,
    } = {},
  ) {
    this.stmts.updateUserProfile.run(
      name,
      about,
      avatarColor,
      avatar,
      presenceVisibility,
      id,
    );
    return this.getUserById(id);
  }

  isContact(userId, contactId) {
    const row = this.db
      .prepare(
        'SELECT 1 AS ok FROM contacts WHERE user_id = ? AND contact_id = ? LIMIT 1',
      )
      .get(userId, contactId);
    return Boolean(row);
  }

  touchLastSeen(id, timestamp = Date.now()) {
    this.stmts.touchLastSeen.run(timestamp, id);
  }

  searchUsers(query, excludeId, limit = 20) {
    const trimmed = String(query).trim();
    const pattern = `${escapeLike(trimmed)}%`;
    if (/^\+?\d+$/.test(trimmed)) {
      const digits = trimmed.replace(/\D/g, '');
      return this.stmts.searchBoth
        .all(
          excludeId,
          `%${escapeLike(digits)}%`,
          pattern,
          pattern,
          limit,
        )
        .map(mapUser);
    }
    return this.stmts.searchName
      .all(excludeId, pattern, pattern, limit)
      .map(mapUser);
  }

  getContacts(userId) {
    return this.stmts.listContacts.all(userId).map(mapUser);
  }

  getUserIdsHavingContact(userId) {
    return this.stmts.contactHolders.all(userId).map((row) => row.user_id);
  }

  addContact(userId, contactId, createdAt = Date.now()) {
    this.stmts.addContact.run(userId, contactId, createdAt);
  }

  removeContact(userId, contactId) {
    return this.stmts.removeContact.run(userId, contactId).changes > 0;
  }

  getAuthCode(phone) {
    return this.stmts.getAuthCode.get(phone) || null;
  }

  upsertAuthCode(phone, codeHash, expiresAt, createdAt = Date.now()) {
    this.stmts.upsertAuthCode.run(phone, codeHash, expiresAt, createdAt);
  }

  incrementAuthCodeAttempts(phone) {
    this.stmts.incrementAuthCodeAttempts.run(phone);
    return this.getAuthCode(phone);
  }

  deleteAuthCode(phone) {
    this.stmts.deleteAuthCode.run(phone);
  }

  preKeyCount(userId) {
    return Number(
      this.db.prepare('SELECT COUNT(*) AS count FROM prekeys WHERE user_id = ?').get(userId).count,
    );
  }

  getPublicKeyInfo(userId) {
    const user = this.getUserById(userId);
    if (!user || !user.identityKey) return null;
    return {
      userId: user.id,
      identityKey: user.identityKey,
      registrationId: user.registrationId,
      signedPreKeyId: user.signedPreKeyId,
    };
  }

  saveKeys(
    userId,
    { identityKey, registrationId, signedPreKey, preKeys },
  ) {
    this.transaction(() => {
      this.stmts.updateUserKeys.run(
        identityKey,
        registrationId,
        signedPreKey.id,
        signedPreKey.publicKey,
        signedPreKey.signature,
        userId,
      );
      for (const preKey of preKeys) {
        this.stmts.insertPreKey.run(userId, preKey.id, preKey.publicKey);
      }
    });
  }

  // Encrypted Signal-state backup: the server stores only an opaque ciphertext
  // blob + KDF salt. It cannot read the keys; a new device decrypts them with a
  // key derived from the account password.
  saveBackup(userId, blob, salt, updatedAt, revision = 0) {
    return this.transaction(() => {
      const current = this.db
        .prepare('SELECT revision FROM key_backup WHERE user_id = ?')
        .get(userId);
      if (current && Number(current.revision) > revision) {
        return { saved: false, revision: Number(current.revision) };
      }
      this.db
        .prepare(
          `INSERT INTO key_backup (user_id, blob, salt, updated_at, revision)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(user_id) DO UPDATE SET
             blob = excluded.blob, salt = excluded.salt,
             updated_at = excluded.updated_at, revision = excluded.revision`,
        )
        .run(userId, blob, salt, updatedAt, revision);
      return { saved: true, revision };
    });
  }

  getBackup(userId) {
    const row = this.db
      .prepare('SELECT blob, salt, updated_at, revision FROM key_backup WHERE user_id = ?')
      .get(userId);
    if (!row) return null;
    return {
      blob: row.blob,
      salt: row.salt,
      updatedAt: Number(row.updated_at),
      revision: Number(row.revision || 0),
    };
  }

  deleteBackup(userId) {
    this.db.prepare('DELETE FROM key_backup WHERE user_id = ?').run(userId);
  }

  replenishPreKeys(userId, preKeys) {
    this.transaction(() => {
      for (const preKey of preKeys) {
        this.stmts.insertPreKey.run(userId, preKey.id, preKey.publicKey);      }
    });
  }

  getKeyBundleAndConsume(userId) {
    return this.transaction(() => {
      const user = this.getUserById(userId);
      if (!user || !user.identityKey) return null;
      const row = this.stmts.firstPreKey.get(userId);
      let preKey = null;
      if (row) {
        preKey = {
          id: Number(row.key_id),
          publicKey: row.public_key,
        };
        this.stmts.deletePreKey.run(userId, row.key_id);
      }
      return {
        userId: user.id,
        identityKey: user.identityKey,
        registrationId: user.registrationId,
        signedPreKey: {
          id: user.signedPreKeyId,
          publicKey: user.signedPreKey,
          signature: user.signedPreKeySignature,
        },
        preKey,
      };
    });
  }

  insertMessage({
    id,
    senderId,
    recipientId,
    ciphertext,
    kind = 'text',
    meta = {},
    createdAt = Date.now(),
    expiresAt,
  }) {
    const serializedMeta =
      typeof meta === 'string' ? meta : JSON.stringify(meta || {});
    const result = this.stmts.insertMessage.run(
      id,
      senderId,
      recipientId,
      ciphertext,
      kind,
      serializedMeta,
      createdAt,
      expiresAt,
    );
    if (result.changes > 0) return { inserted: true, message: null };
    return {
      inserted: false,
      message: this.getMessageById(id),
    };
  }

  getMessageById(id) {
    return mapMessage(this.stmts.getMessageById.get(id));
  }

  getQueuedMessages(userId, now = Date.now(), limit = 500) {
    return this.stmts.getQueuedMessages
      .all(userId, now, limit)
      .map(mapMessage);
  }

  ackMessages(userId, ids, now = Date.now()) {
    const groups = new Map();
    let acked = 0;
    this.transaction(() => {
      for (const id of ids) {
        const row = this.stmts.getUndeliveredForRecipient.get(id, userId);
        if (!row) continue;
        const result = this.stmts.markDelivered.run(now, id, userId);
        if (result.changes === 0) continue;
        acked += 1;
        if (!groups.has(row.sender_id)) groups.set(row.sender_id, []);
        groups.get(row.sender_id).push(id);
      }
    });
    return {
      acked,
      bySender: Array.from(groups, ([senderId, messageIds]) => ({
        senderId,
        messageIds,
      })),
    };
  }

  getMessageStatusesForSender(userId, ids) {
    const statuses = [];
    const direct = this.db.prepare(
      'SELECT id, delivered_at, read_at FROM messages WHERE id = ? AND sender_id = ?',
    );
    const group = this.db.prepare(
      `SELECT m.id,
              EXISTS(SELECT 1 FROM group_message_receipts r
                     WHERE r.message_id = m.id AND r.delivered_at IS NOT NULL) AS is_delivered,
              EXISTS(SELECT 1 FROM group_message_receipts r
                     WHERE r.message_id = m.id AND r.read_at IS NOT NULL) AS is_read
       FROM group_messages m
       JOIN group_members membership ON membership.group_id = m.group_id
         AND membership.user_id = ?
       WHERE m.id = ? AND m.sender_id = ?`,
    );
    for (const id of ids) {
      const message = direct.get(id, userId);
      if (message) {
        statuses.push({
          id,
          status: message.read_at != null
            ? 'read'
            : message.delivered_at != null
              ? 'delivered'
              : 'sent',
        });
        continue;
      }
      const groupMessage = group.get(userId, id, userId);
      if (groupMessage) {
        statuses.push({
          id,
          status: groupMessage.is_read
            ? 'read'
            : groupMessage.is_delivered
              ? 'delivered'
              : 'sent',
        });
      }
    }
    return statuses;
  }

  markMessagesRead(userId, chatWith, ids, now = Date.now()) {
    const readIds = [];
    this.transaction(() => {
      for (const id of ids) {
        const row = this.stmts.getUnreadForChat.get(id, userId, chatWith);
        if (!row) continue;
        const result = this.stmts.markRead.run(
          now,
          now,
          id,
          userId,
          chatWith,
        );
        if (result.changes > 0) readIds.push(id);
      }
    });
    return readIds;
  }

  cleanupExpiredMessages(now = Date.now()) {
    return this.stmts.cleanupMessages.run(now).changes;
  }

  registerPushToken(userId, token, platform, createdAt = Date.now()) {
    this.transaction(() => {
      this.stmts.removeTokenForOthers.run(token, userId);
      this.stmts.upsertPushToken.run(userId, token, platform, createdAt);
    });
  }

  deletePushToken(userId, token) {
    return this.stmts.deletePushToken.run(userId, token).changes > 0;
  }

  createGroup({
    id,
    title,
    avatar = '',
    createdBy,
    memberIds = [],
    createdAt = Date.now(),
  }) {
    this.transaction(() => {
      this.db
        .prepare(
          'INSERT INTO groups (id, title, avatar, created_by, created_at) VALUES (?, ?, ?, ?, ?)',
        )
        .run(id, title, avatar, createdBy, createdAt);
      const add = this.db.prepare(
        'INSERT OR IGNORE INTO group_members (group_id, user_id, role, joined_at) VALUES (?, ?, ?, ?)',
      );
      add.run(id, createdBy, 'owner', createdAt);
      for (const userId of memberIds) {
        if (userId === createdBy) continue;
        add.run(id, userId, 'member', createdAt);
      }
    });
    return this.getGroup(id);
  }

  getGroup(id) {
    const row = this.db.prepare('SELECT * FROM groups WHERE id = ?').get(id);
    if (!row) return null;
    return {
      id: row.id,
      title: row.title,
      avatar: row.avatar || '',
      createdBy: row.created_by,
      createdAt: row.created_at,
    };
  }

  listGroupsForUser(userId) {
    return this.db
      .prepare(
        `SELECT g.*, (SELECT COUNT(*) FROM group_members m WHERE m.group_id = g.id) AS member_count
         FROM groups g
         JOIN group_members gm ON gm.group_id = g.id
         WHERE gm.user_id = ?
         ORDER BY g.created_at DESC`,
      )
      .all(userId)
      .map((row) => ({
        id: row.id,
        title: row.title,
        avatar: row.avatar || '',
        createdBy: row.created_by,
        memberCount: Number(row.member_count || 0),
        createdAt: row.created_at,
      }));
  }

  updateGroup(id, { title = null, avatar = null }) {
    this.db
      .prepare(
        `UPDATE groups
         SET title = COALESCE(?, title),
             avatar = COALESCE(?, avatar)
         WHERE id = ?`,
      )
      .run(title, avatar, id);
    return this.getGroup(id);
  }

  listGroupMembers(groupId) {
    return this.db
      .prepare(
        `SELECT u.id, u.name, u.username, u.avatar, u.avatar_color, m.role, m.joined_at
         FROM group_members m JOIN users u ON u.id = m.user_id
         WHERE m.group_id = ?
         ORDER BY m.role = 'owner' DESC, m.joined_at ASC`,
      )
      .all(groupId)
      .map((row) => ({
        id: row.id,
        name: row.name,
        username: row.username || null,
        avatar: row.avatar || '',
        avatarColor: row.avatar_color || '#1A9C7A',
        role: row.role,
        joinedAt: row.joined_at,
      }));
  }

  isGroupMember(groupId, userId) {
    return Boolean(
      this.db
        .prepare(
          'SELECT 1 AS ok FROM group_members WHERE group_id = ? AND user_id = ? LIMIT 1',
        )
        .get(groupId, userId),
    );
  }

  addGroupMember(groupId, userId, role = 'member', joinedAt = Date.now()) {
    this.db
      .prepare(
        'INSERT OR IGNORE INTO group_members (group_id, user_id, role, joined_at) VALUES (?, ?, ?, ?)',
      )
      .run(groupId, userId, role, joinedAt);
  }

  removeGroupMember(groupId, userId) {
    return this.transaction(() => {
      const removed = this.db
        .prepare('DELETE FROM group_members WHERE group_id = ? AND user_id = ?')
        .run(groupId, userId).changes > 0;
      if (removed) {
        this.db
          .prepare(
            `DELETE FROM group_message_receipts
             WHERE user_id = ? AND message_id IN (
               SELECT id FROM group_messages WHERE group_id = ?
             )`,
          )
          .run(userId, groupId);
        this.db
          .prepare(
            `DELETE FROM pet_members WHERE user_id = ? AND pet_id IN (
               SELECT id FROM pets WHERE scope = 'group' AND chat_id = ?
             )`,
          )
          .run(userId, groupId);
      }
      return removed;
    });
  }

  insertGroupMessage({
    id,
    groupId,
    senderId,
    ciphertext,
    kind = 'text',
    meta = {},
    createdAt = Date.now(),
    expiresAt,
    memberIds = [],
  }) {
    const serializedMeta =
      typeof meta === 'string' ? meta : JSON.stringify(meta || {});
    let inserted = false;
    let message = null;
    this.transaction(() => {
      const result = this.db
        .prepare(
          `INSERT OR IGNORE INTO group_messages
            (id, group_id, sender_id, ciphertext, kind, meta, created_at, expires_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          id,
          groupId,
          senderId,
          ciphertext,
          kind,
          serializedMeta,
          createdAt,
          expiresAt,
        );
      inserted = result.changes > 0;
      message = mapGroupMessage(
        this.db.prepare('SELECT * FROM group_messages WHERE id = ?').get(id),
      );
      if (!inserted) return;
      const receipt = this.db.prepare(
        'INSERT OR IGNORE INTO group_message_receipts (message_id, user_id, delivered_at, read_at) VALUES (?, ?, NULL, NULL)',
      );
      for (const userId of memberIds) {
        if (userId === senderId) continue;
        receipt.run(id, userId);
      }
    });
    return { inserted, message };
  }

  getPendingGroupMessages(userId, now = Date.now(), limit = 500) {
    return this.db
      .prepare(
        `SELECT m.* FROM group_messages m
         JOIN group_message_receipts r ON r.message_id = m.id
         JOIN group_members membership ON membership.group_id = m.group_id
           AND membership.user_id = r.user_id
         WHERE r.user_id = ? AND r.delivered_at IS NULL AND m.expires_at > ?
         ORDER BY m.created_at ASC, m.id ASC
         LIMIT ?`,
      )
      .all(userId, now, limit)
      .map(mapGroupMessage);
  }

  ackGroupMessages(userId, ids, now = Date.now()) {
    const bySender = new Map();
    let acked = 0;
    this.transaction(() => {
      for (const id of ids) {
        const res = this.db
          .prepare(
            'UPDATE group_message_receipts SET delivered_at = ? WHERE message_id = ? AND user_id = ? AND delivered_at IS NULL',
          )
          .run(now, id, userId);
        if (res.changes === 0) continue;
        acked += 1;
        const msg = this.db
          .prepare('SELECT sender_id FROM group_messages WHERE id = ?')
          .get(id);
        if (msg) {
          if (!bySender.has(msg.sender_id)) bySender.set(msg.sender_id, []);
          bySender.get(msg.sender_id).push(id);
        }
      }
    });
    return {
      acked,
      bySender: Array.from(bySender, ([senderId, messageIds]) => ({
        senderId,
        messageIds,
      })),
    };
  }

  markGroupMessagesRead(userId, ids, now = Date.now(), groupId = null) {
    const readIds = [];
    this.transaction(() => {
      for (const id of ids) {
        const res = this.db
          .prepare(
            `UPDATE group_message_receipts
             SET read_at = ?, delivered_at = COALESCE(delivered_at, ?)
             WHERE message_id = ? AND user_id = ? AND read_at IS NULL
               AND (? IS NULL OR message_id IN (
                 SELECT id FROM group_messages WHERE group_id = ?
               ))`,
          )
          .run(now, now, id, userId, groupId, groupId);
        if (res.changes > 0) readIds.push(id);
      }
    });
    return readIds;
  }

  getGroupMessageSender(messageId) {
    const row = this.db
      .prepare('SELECT sender_id FROM group_messages WHERE id = ?')
      .get(messageId);
    return row ? row.sender_id : null;
  }

  cleanupExpiredGroupMessages(now = Date.now()) {
    const ids = this.db
      .prepare('SELECT id FROM group_messages WHERE expires_at < ?')
      .all(now)
      .map((row) => row.id);
    if (ids.length === 0) return 0;
    this.transaction(() => {
      for (const id of ids) {
        this.db
          .prepare('DELETE FROM group_message_receipts WHERE message_id = ?')
          .run(id);
      }
      const placeholders = ids.map(() => '?').join(',');
      this.db
        .prepare(`DELETE FROM group_messages WHERE id IN (${placeholders})`)
        .run(...ids);
    });
    return ids.length;
  }

  deleteUser(id) {
    const user = this.getUserById(id);
    if (!user) return false;
    this.transaction(() => {
      this.db
        .prepare('DELETE FROM messages WHERE sender_id = ? OR recipient_id = ?')
        .run(id, id);
      this.db
        .prepare('DELETE FROM contacts WHERE user_id = ? OR contact_id = ?')
        .run(id, id);
      this.db.prepare('DELETE FROM prekeys WHERE user_id = ?').run(id);
      this.db.prepare('DELETE FROM push_tokens WHERE user_id = ?').run(id);
      this.db.prepare('DELETE FROM key_backup WHERE user_id = ?').run(id);
      this.db.prepare('DELETE FROM auth_codes WHERE phone = ?').run(user.phone);
      this.db
        .prepare(
          `DELETE FROM pet_operations WHERE pet_id IN (
             SELECT id FROM pets WHERE owner_id = ? OR id IN (
               SELECT pet_id FROM pet_members WHERE user_id = ?
             )
           )`,
        )
        .run(id, id);
      this.db
        .prepare(
          `DELETE FROM pets WHERE owner_id = ? OR id IN (
             SELECT pet_id FROM pet_members WHERE user_id = ?
           )`,
        )
        .run(id, id);
      this.db
        .prepare(
          'DELETE FROM pet_members WHERE user_id = ? OR pet_id NOT IN (SELECT id FROM pets)',
        )
        .run(id);
      // Group membership: drop the user's receipts and membership rows.
      this.db
        .prepare('DELETE FROM group_message_receipts WHERE user_id = ?')
        .run(id);
      this.db.prepare('DELETE FROM group_members WHERE user_id = ?').run(id);
      this.db.prepare('DELETE FROM users WHERE id = ?').run(id);
    });
    return true;
  }

  close() {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
    this.db.close();
  }
}

function createDatabase(filePath) {
  return new CoralinkDatabase(filePath);
}

module.exports = {
  CoralinkDatabase,
  createDatabase,
  mapMessage,
  mapUser,
  safeParseMeta,
};
