'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const { test } = require('node:test');
const { createDatabase } = require('../src/db');

// The schema shipped before nickname accounts existed: no username/avatar/
// password_hash columns, no username index, and phone NOT NULL.
const LEGACY_SCHEMA = `
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  phone TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  about TEXT DEFAULT '',
  avatar_color TEXT DEFAULT '#1A9C7A',
  created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  identity_key TEXT,
  registration_id INTEGER,
  signed_prekey_id INTEGER,
  signed_prekey TEXT,
  signed_prekey_signature TEXT,
  presence_visibility TEXT NOT NULL DEFAULT 'contacts'
);
`;

test('a legacy database migrates on startup and accepts nickname-only users', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'coralink-legacy-'));
  const file = path.join(dir, 'legacy.db');
  const legacy = new DatabaseSync(file);
  legacy.exec(LEGACY_SCHEMA);
  legacy
    .prepare(
      'INSERT INTO users (id, phone, name, created_at, last_seen) VALUES (?, ?, ?, ?, ?)',
    )
    .run('legacy-user', '79990000000', 'Legacy', 1, 1);
  legacy.close();

  let db;
  try {
    // Previously failed with "no such column: username" on the username index.
    db = createDatabase(file);

    const columns = db.db.prepare('PRAGMA table_info(users)').all();
    const phone = columns.find((column) => column.name === 'phone');
    assert.equal(Number(phone.notnull), 0);
    for (const name of ['username', 'avatar', 'password_hash']) {
      assert.ok(columns.some((column) => column.name === name), name);
    }
    assert.ok(
      db.db
        .prepare("SELECT name FROM sqlite_master WHERE name = 'idx_users_username'")
        .get(),
    );

    const preserved = db.getUserById('legacy-user');
    assert.equal(preserved.phone, '79990000000');
    assert.equal(preserved.name, 'Legacy');

    // Registration by nickname stores no phone, which the legacy constraint
    // rejected with "NOT NULL constraint failed: users.phone".
    const created = db.createUser({
      id: 'new-user',
      username: 'coral_ann',
      name: 'Ann',
      passwordHash: 'hash',
    });
    assert.equal(created.phone, null);
    assert.equal(created.username, 'coral_ann');
    assert.equal(db.getUserByUsername('coral_ann').id, 'new-user');
  } finally {
    if (db) db.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
