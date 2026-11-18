'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const { escapeLike } = require('./lib/validate');

const SCHEMA = `
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  phone TEXT UNIQUE,
  username TEXT UNIQUE,
  name TEXT NOT NULL,
  about TEXT DEFAULT '',
  avatar_color TEXT DEFAULT '#1A9C7A',
  avatar TEXT DEFAULT '',
  created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  identity_key TEXT,
  registration_id INTEGER,
  signed_prekey_id INTEGER,
  signed_prekey TEXT,
  signed_prekey_signature TEXT,
  presence_visibility TEXT NOT NULL DEFAULT 'contacts'
);

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

CREATE INDEX IF NOT EXISTS idx_messages_recipient_delivered
  ON messages(recipient_id, delivered_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_contacts_user ON contacts(user_id);
CREATE INDEX IF NOT EXISTS idx_users_phone ON users(phone);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
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

    this.stmts = {
      getUserById: this.db.prepare('SELECT * FROM users WHERE id = ?'),
      getUserByPhone: this.db.prepare('SELECT * FROM users WHERE phone = ?'),
      getUserByUsername: this.db.prepare(
        'SELECT * FROM users WHERE username = ?',
      ),
      insertUser: this.db.prepare(`
        INSERT INTO users
          (id, phone, username, name, about, avatar_color, avatar, created_at, last_seen)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
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
      upsertPreKey: this.db.prepare(`
        INSERT OR REPLACE INTO prekeys (user_id, key_id, public_key)
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
    this.cleanupTimer = setInterval(() => {
      try {
        this.cleanupExpiredMessages();
      } catch {
        // The next interval or startup cleanup will retry. Avoid crashing the
        // process because of a transient storage error.
      }
    }, 10 * 60 * 1000);
    this.cleanupTimer.unref();
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
        this.stmts.upsertPreKey.run(userId, preKey.id, preKey.publicKey);
      }
    });
  }

  replenishPreKeys(userId, preKeys) {
    this.transaction(() => {
      for (const preKey of preKeys) {
        this.stmts.upsertPreKey.run(userId, preKey.id, preKey.publicKey);
      }
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
      this.db.prepare('DELETE FROM auth_codes WHERE phone = ?').run(user.phone);
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
