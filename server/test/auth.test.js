'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { startTestApp } = require('./helpers');

test('register creates an account with a password and issues a token', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  const response = await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username: 'alice', name: 'Alice Doe', password: 'secret123' },
  });
  assert.strictEqual(response.status, 200);
  assert.strictEqual(response.body.isNew, true);
  assert.strictEqual(response.body.user.username, 'alice');
  assert.ok(response.body.token);

  const me = await app.api('/api/v1/me', { token: response.body.token });
  assert.strictEqual(me.status, 200);
  assert.strictEqual(me.body.user.username, 'alice');
});

test('register rejects a duplicate nickname', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username: 'bob', password: 'secret123' },
  });
  const dup = await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username: 'bob', password: 'other123' },
  });
  assert.strictEqual(dup.status, 409);
  assert.strictEqual(dup.body.error.code, 'username_taken');
});

test('register rejects a short password', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  const response = await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username: 'carol', password: '123' },
  });
  assert.strictEqual(response.status, 400);
  assert.strictEqual(response.body.error.code, 'invalid_password');
});

test('login succeeds with the correct password', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  const reg = await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username: 'dave', name: 'Dave', password: 'secret123' },
  });
  const login = await app.api('/api/v1/auth/login', {
    method: 'POST',
    body: { username: 'dave', password: 'secret123' },
  });
  assert.strictEqual(login.status, 200);
  assert.strictEqual(login.body.isNew, false);
  assert.strictEqual(login.body.user.id, reg.body.user.id);
});

test('login rejects a wrong password and an unknown nickname', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username: 'erin', password: 'secret123' },
  });
  const wrong = await app.api('/api/v1/auth/login', {
    method: 'POST',
    body: { username: 'erin', password: 'nope123' },
  });
  assert.strictEqual(wrong.status, 401);
  assert.strictEqual(wrong.body.error.code, 'invalid_credentials');

  const unknown = await app.api('/api/v1/auth/login', {
    method: 'POST',
    body: { username: 'ghost', password: 'secret123' },
  });
  assert.strictEqual(unknown.status, 401);
});

test('user search matches on username', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());

  await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username: 'carol', name: 'Carol', password: 'secret123' },
  });
  const finder = await app.api('/api/v1/auth/register', {
    method: 'POST',
    body: { username: 'dave2', name: 'Dave', password: 'secret123' },
  });

  const search = await app.api('/api/v1/users/search?q=carol', {
    token: finder.body.token,
  });
  assert.strictEqual(search.status, 200);
  const match = search.body.users.find((entry) => entry.username === 'carol');
  assert.ok(match, 'carol should be found by nickname');
});
