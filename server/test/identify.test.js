'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { startTestApp } = require('./helpers');

test('identify registers a new account by nickname without a code', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  const response = await app.api('/api/v1/auth/identify', {
    method: 'POST',
    body: { username: 'alice', name: 'Alice Doe' },
  });
  assert.strictEqual(response.status, 200);
  assert.strictEqual(response.body.isNew, true);
  assert.strictEqual(response.body.user.username, 'alice');
  assert.strictEqual(response.body.user.name, 'Alice Doe');
  assert.ok(response.body.token);

  const me = await app.api('/api/v1/me', { token: response.body.token });
  assert.strictEqual(me.status, 200);
  assert.strictEqual(me.body.user.username, 'alice');
});

test('identify returns the same account on a repeat nickname', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  const first = await app.api('/api/v1/auth/identify', {
    method: 'POST',
    body: { username: 'bob', name: 'Bob' },
  });
  const second = await app.api('/api/v1/auth/identify', {
    method: 'POST',
    body: { username: 'bob' },
  });
  assert.strictEqual(first.body.isNew, true);
  assert.strictEqual(second.body.isNew, false);
  assert.strictEqual(second.body.user.id, first.body.user.id);
});

test('identify rejects malformed usernames', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  for (const username of ['ab', 'has space', '_leading']) {
    const response = await app.api('/api/v1/auth/identify', {
      method: 'POST',
      body: { username },
    });
    assert.strictEqual(response.status, 400, username);
    assert.strictEqual(response.body.error.code, 'invalid_username');
  }
});

test('user search matches on username', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  await app.api('/api/v1/auth/identify', {
    method: 'POST',
    body: { username: 'carol', name: 'Carol' },
  });
  const finder = await app.api('/api/v1/auth/identify', {
    method: 'POST',
    body: { username: 'dave', name: 'Dave' },
  });

  const search = await app.api('/api/v1/users/search?q=carol', {
    token: finder.body.token,
  });
  assert.strictEqual(search.status, 200);
  const match = search.body.users.find((entry) => entry.username === 'carol');
  assert.ok(match, 'carol should be found by nickname');
});
