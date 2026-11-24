'use strict';

const MAX_PET_PAYLOAD = 16 * 1024;
const MAX_OPERATIONS = 500;

function canonicalDirectChat(firstId, secondId) {
  return `direct:${[firstId, secondId].sort().join(':')}`;
}

function mapPet(row) {
  if (!row) return null;
  return {
    id: row.id,
    scope: row.scope,
    chatId: row.chat_id,
    ownerId: row.owner_id,
    status: row.status,
    createdAt: Number(row.created_at),
    updatedAt: Number(row.updated_at),
    seq: Number(row.snapshot_seq || 0),
    snapshot: row.snapshot || '',
  };
}

class PetStore {
  constructor(db) {
    this.db = db.db;
    this.operationWindows = new Map();
  }

  _transaction(operation) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = operation();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }

  _members(petId) {
    return this.db
      .prepare(
        `SELECT m.user_id, m.role, m.state, m.joined_at,
                u.name, u.username, u.avatar, u.avatar_color
         FROM pet_members m JOIN users u ON u.id = m.user_id
         WHERE m.pet_id = ? ORDER BY m.joined_at ASC, m.user_id ASC`,
      )
      .all(petId)
      .map((row) => ({
        userId: row.user_id,
        role: row.role,
        state: row.state,
        joinedAt: Number(row.joined_at),
        name: row.name,
        username: row.username || null,
        avatar: row.avatar || '',
        avatarColor: row.avatar_color || '#1A9C7A',
      }));
  }

  _accessible(petId, userId) {
    const row = this.db
      .prepare(
        `SELECT p.*, m.role AS my_role, m.state AS my_state
         FROM pets p JOIN pet_members m ON m.pet_id = p.id AND m.user_id = ?
         LEFT JOIN group_members gm ON gm.group_id = p.chat_id AND gm.user_id = m.user_id
         WHERE p.id = ? AND m.state IN ('active', 'pending')
           AND (p.scope != 'group' OR gm.user_id IS NOT NULL)`,
      )
      .get(userId, petId);
    if (!row) return null;
    return { ...mapPet(row), role: row.my_role, membershipState: row.my_state };
  }

  _withMembers(pet) {
    return pet ? { ...pet, members: this._members(pet.id) } : null;
  }

  create({ id, userId, scope, chatId, snapshot }) {
    return this._transaction(() => {
      const now = Date.now();
      const formattedId = id;
      const status = scope === 'direct' ? 'pending' : 'active';
      this.db
        .prepare(
          `INSERT INTO pets
            (id, scope, chat_id, owner_id, status, snapshot, snapshot_seq, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)`,
        )
        .run(formattedId, scope, chatId, userId, status, snapshot, now, now);
      const addMember = this.db.prepare(
        `INSERT INTO pet_members (pet_id, user_id, role, state, joined_at)
         VALUES (?, ?, ?, ?, ?)`,
      );
      addMember.run(formattedId, userId, 'owner', 'active', now);
      if (scope === 'direct') {
        const peerId = chatId.slice('direct:'.length).split(':').find((value) => value !== userId);
        addMember.run(formattedId, peerId, 'member', 'pending', now);
      } else if (scope === 'group') {
        const members = this.db
          .prepare('SELECT user_id FROM group_members WHERE group_id = ?')
          .all(chatId);
        for (const member of members) {
          if (member.user_id !== userId) {
            addMember.run(formattedId, member.user_id, 'member', 'active', now);
          }
        }
      }
      return this._withMembers(this._accessible(formattedId, userId));
    });
  }

  list(userId) {
    const rows = this.db
      .prepare(
        `SELECT p.id FROM pets p
         JOIN pet_members m ON m.pet_id = p.id AND m.user_id = ?
         LEFT JOIN group_members gm ON gm.group_id = p.chat_id AND gm.user_id = m.user_id
         WHERE m.state IN ('active', 'pending') AND p.status != 'archived'
           AND (p.scope != 'group' OR gm.user_id IS NOT NULL)
         ORDER BY p.updated_at DESC`,
      )
      .all(userId);
    return rows
      .map((row) => this._accessible(row.id, userId))
      .filter(Boolean)
      .map((pet) => this._withMembers(pet));
  }

  get(petId, userId) {
    return this._withMembers(this._accessible(petId, userId));
  }

  findActive(scope, chatId, userId) {
    const row = this.db
      .prepare(
        `SELECT p.id FROM pets p
         JOIN pet_members m ON m.pet_id = p.id AND m.user_id = ?
         WHERE p.scope = ? AND p.chat_id = ? AND p.status != 'archived'
           AND m.state IN ('active', 'pending') LIMIT 1`,
      )
      .get(userId, scope, chatId);
    return row ? this.get(row.id, userId) : null;
  }

  _operations(petId, afterSeq) {
    return this.db
      .prepare(
        `SELECT id, pet_id, seq, actor_id, action, payload, created_at
         FROM pet_operations WHERE pet_id = ? AND seq > ?
         ORDER BY seq ASC LIMIT ?`,
      )
      .all(petId, afterSeq, MAX_OPERATIONS)
      .map((row) => ({
        id: row.id,
        seq: Number(row.seq),
        actorId: row.actor_id,
        action: row.action,
        payload: row.payload,
        createdAt: Number(row.created_at),
      }));
  }

  detail(petId, userId, afterSeq = 0) {
    const pet = this.get(petId, userId);
    if (!pet) return null;
    const operations = this._operations(petId, afterSeq);
    return {
      ...pet,
      operations,
      hasMoreOperations: operations.length === MAX_OPERATIONS,
    };
  }

  _allowOperation(userId) {
    const now = Date.now();
    const windowStart = now - 60_000;
    const recent = (this.operationWindows.get(userId) || []).filter(
      (stamp) => stamp >= windowStart,
    );
    if (recent.length >= 60) return false;
    recent.push(now);
    this.operationWindows.set(userId, recent);
    return true;
  }

  addOperation({ petId, userId, operationId, action, payload }) {
    if (!this._allowOperation(userId)) {
      const error = new Error('Too many pet actions');
      error.code = 'rate_limited';
      throw error;
    }
    return this._transaction(() => {
      const pet = this._accessible(petId, userId);
      if (!pet || pet.status !== 'active' || pet.membershipState !== 'active') {
        const error = new Error('Pet is not active for this user');
        error.code = 'not_allowed';
        throw error;
      }
      const existing = this.db
        .prepare('SELECT * FROM pet_operations WHERE id = ?')
        .get(operationId);
      if (existing) {
        if (existing.pet_id !== petId || existing.actor_id !== userId) {
          const error = new Error('Operation id is already in use');
          error.code = 'duplicate_id';
          throw error;
        }
        return {
          operation: {
            id: existing.id,
            seq: Number(existing.seq),
            actorId: existing.actor_id,
            action: existing.action,
            payload: existing.payload,
            createdAt: Number(existing.created_at),
          },
          duplicate: true,
        };
      }
      const now = Date.now();
      const next = this.db
        .prepare('SELECT COALESCE(MAX(seq), 0) + 1 AS seq FROM pet_operations WHERE pet_id = ?')
        .get(petId).seq;
      this.db
        .prepare(
          `INSERT INTO pet_operations
            (id, pet_id, seq, actor_id, action, payload, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(operationId, petId, next, userId, action, payload, now);
      this.db.prepare('UPDATE pets SET updated_at = ? WHERE id = ?').run(now, petId);
      return {
        operation: {
          id: operationId,
          seq: Number(next),
          actorId: userId,
          action,
          payload,
          createdAt: now,
        },
        duplicate: false,
      };
    });
  }

  saveSnapshot({ petId, userId, seq, snapshot }) {
    return this._transaction(() => {
      const pet = this._accessible(petId, userId);
      if (!pet || pet.status !== 'active' || pet.membershipState !== 'active') {
        const error = new Error('Pet is not active for this user');
        error.code = 'not_allowed';
        throw error;
      }
      const current = this.db.prepare('SELECT snapshot_seq FROM pets WHERE id = ?').get(petId);
      if (seq < Number(current.snapshot_seq || 0)) {
        return { saved: false, seq: Number(current.snapshot_seq || 0) };
      }
      const now = Date.now();
      this.db
        .prepare('UPDATE pets SET snapshot = ?, snapshot_seq = ?, updated_at = ? WHERE id = ?')
        .run(snapshot, seq, now, petId);
      return { saved: true, seq };
    });
  }

  setMembership({ petId, userId, state }) {
    return this._transaction(() => {
      const pet = this._accessible(petId, userId);
      if (!pet) return null;
      this.db
        .prepare('UPDATE pet_members SET state = ? WHERE pet_id = ? AND user_id = ?')
        .run(state, petId, userId);
      return this.get(petId, userId);
    });
  }

  accept(petId, userId) {
    return this._transaction(() => {
      const pet = this._accessible(petId, userId);
      if (!pet || pet.scope !== 'direct' || pet.membershipState !== 'pending') {
        const error = new Error('No pending invitation');
        error.code = 'not_allowed';
        throw error;
      }
      const now = Date.now();
      this.db
        .prepare("UPDATE pet_members SET state = 'active' WHERE pet_id = ? AND user_id = ?")
        .run(petId, userId);
      this.db
        .prepare("UPDATE pets SET status = 'active', updated_at = ? WHERE id = ?")
        .run(now, petId);
      return this.get(petId, userId);
    });
  }

  decline(petId, userId) {
    return this._transaction(() => {
      const pet = this._accessible(petId, userId);
      if (!pet || pet.scope !== 'direct' || pet.membershipState !== 'pending') {
        const error = new Error('No pending invitation');
        error.code = 'not_allowed';
        throw error;
      }
      const now = Date.now();
      this.db
        .prepare("UPDATE pet_members SET state = 'declined' WHERE pet_id = ? AND user_id = ?")
        .run(petId, userId);
      this.db
        .prepare("UPDATE pets SET status = 'archived', updated_at = ? WHERE id = ?")
        .run(now, petId);
      return this._withMembers(pet);
    });
  }

  release(petId, userId) {
    return this._transaction(() => {
      const pet = this._accessible(petId, userId);
      if (!pet) return null;
      const now = Date.now();
      this.db
        .prepare("UPDATE pet_members SET state = 'left' WHERE pet_id = ? AND user_id = ?")
        .run(petId, userId);
      if (pet.role === 'owner' || pet.scope === 'personal') {
        this.db
          .prepare("UPDATE pets SET status = 'archived', updated_at = ? WHERE id = ?")
          .run(now, petId);
      }
      return this._withMembers(pet);
    });
  }
}

module.exports = {
  MAX_PET_PAYLOAD,
  canonicalDirectChat,
  PetStore,
};
