'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { startTestApp } = require('./helpers');

async function register(app, username) {
  const r = await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username, name: username, password: 'secret123' },
  });
  return r.body.token;
}

test('backup round-trips an opaque encrypted blob', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const token = await register(app, 'carol');

  const before = await app.api('/api/v1/backup', { token });
  assert.strictEqual(before.status, 404);

  const put = await app.api('/api/v1/backup', {
    method: 'PUT',
    token,
    body: { blob: 'QUJDREVG', salt: 'c2FsdHNhbHQ=' },
  });
  assert.strictEqual(put.status, 200);

  const after = await app.api('/api/v1/backup', { token });
  assert.strictEqual(after.status, 200);
  assert.strictEqual(after.body.blob, 'QUJDREVG');
  assert.strictEqual(after.body.salt, 'c2FsdHNhbHQ=');
  assert.ok(Number.isInteger(after.body.updatedAt));
});

test('backup PUT overwrites the previous blob', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const token = await register(app, 'dave');

  await app.api('/api/v1/backup', {
    method: 'PUT',
    token,
    body: { blob: 'AAAA', salt: 'c2FsdA==' },
  });
  await app.api('/api/v1/backup', {
    method: 'PUT',
    token,
    body: { blob: 'BBBB', salt: 'c2FsdA==' },
  });
  const after = await app.api('/api/v1/backup', { token });
  assert.strictEqual(after.body.blob, 'BBBB');
});

test('backup endpoints require authentication and reject non-base64', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const token = await register(app, 'erin');

  const noAuth = await app.api('/api/v1/backup');
  assert.strictEqual(noAuth.status, 401);

  const bad = await app.api('/api/v1/backup', {
    method: 'PUT',
    token,
    body: { blob: 'not base64!!', salt: 'c2FsdA==' },
  });
  assert.strictEqual(bad.status, 400);
  assert.strictEqual(bad.body.error.code, 'invalid_backup');
});
