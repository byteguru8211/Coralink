'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { base64, randomUuid, startTestApp } = require('./helpers');

const TEST_TIMEOUT = 20_000;

async function createHarness(t, overrides = {}) {
  const harness = await startTestApp(overrides);
  t.after(async () => {
    await harness.close();
  });
  return harness;
}

function wrongCodeFor(code) {
  return code === '000000' ? '000001' : '000000';
}

test(
  'full auth flow: dev code, verify, JWT, and authenticated profile',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const codeResponse = await h.api('/api/v1/auth/request-code', {
      method: 'POST',
      body: { phone: '+7 (999) 000-00-01' },
    });

    assert.equal(codeResponse.status, 200);
    assert.equal(codeResponse.body.ok, true);
    assert.equal(codeResponse.body.retryAfter, 60);
    assert.match(codeResponse.body.devCode, /^\d{6}$/);

    const verifyResponse = await h.api('/api/v1/auth/verify', {
      method: 'POST',
      body: {
        phone: '+7 (999) 000-00-01',
        code: codeResponse.body.devCode,
        name: '  Алиса  ',
        about: 'E2EE enthusiast',
      },
    });

    assert.equal(verifyResponse.status, 200);
    assert.equal(verifyResponse.body.isNew, true);
    assert.match(verifyResponse.body.token, /^[^.]+\.[^.]+\.[^.]+$/);
    assert.equal(verifyResponse.body.user.name, 'Алиса');
    assert.equal(verifyResponse.body.user.phone, '79990000001');
    assert.equal(verifyResponse.body.user.online, false);
    assert.equal(verifyResponse.body.user.identityKey, undefined);

    const me = await h.api('/api/v1/me', {
      token: verifyResponse.body.token,
    });
    assert.equal(me.status, 200);
    assert.equal(me.body.user.id, verifyResponse.body.user.id);
    assert.equal(me.body.user.about, 'E2EE enthusiast');

    const badToken = await h.api('/api/v1/me', {
      token: `${verifyResponse.body.token}tampered`,
    });
    assert.equal(badToken.status, 401);
    assert.equal(badToken.body.error.code, 'unauthorized');
  },
);

test(
  'verify rejects wrong codes and locks after five attempts',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const phone = '79990000002';
    const requested = await h.api('/api/v1/auth/request-code', {
      method: 'POST',
      body: { phone },
    });
    assert.equal(requested.status, 200);
    const wrong = wrongCodeFor(requested.body.devCode);

    for (let attempt = 1; attempt <= 5; attempt += 1) {
      const response = await h.api('/api/v1/auth/verify', {
        method: 'POST',
        body: { phone, code: wrong },
      });
      assert.equal(response.status, 401);
      assert.equal(response.body.error.code, 'invalid_code');
    }

    const locked = await h.api('/api/v1/auth/verify', {
      method: 'POST',
      body: { phone, code: wrong },
    });
    assert.equal(locked.status, 429);
    assert.equal(locked.body.error.code, 'too_many_attempts');
    assert.ok(Number(locked.headers.get('retry-after')) >= 1);

    const correctAfterLock = await h.api('/api/v1/auth/verify', {
      method: 'POST',
      body: { phone, code: requested.body.devCode },
    });
    assert.equal(correctAfterLock.status, 429);
  },
);

test(
  'auth is required for protected API routes',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const response = await h.api('/api/v1/me');
    assert.equal(response.status, 401);
    assert.equal(response.body.error.code, 'unauthorized');

    const contacts = await h.api('/api/v1/contacts', {
      token: 'not-a-token',
    });
    assert.equal(contacts.status, 401);
  },
);

test(
  'profile update validates and persists name, about, and avatarColor',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const user = await h.login('79990000003', 'Original');

    const emptyName = await h.api('/api/v1/me', {
      method: 'PATCH',
      token: user.token,
      body: { name: '' },
    });
    assert.equal(emptyName.status, 400);
    assert.equal(emptyName.body.error.code, 'invalid_name');

    const longAbout = await h.api('/api/v1/me', {
      method: 'PATCH',
      token: user.token,
      body: { about: 'x'.repeat(281) },
    });
    assert.equal(longAbout.status, 400);
    assert.equal(longAbout.body.error.code, 'invalid_about');

    const badColor = await h.api('/api/v1/me', {
      method: 'PATCH',
      token: user.token,
      body: { avatarColor: 'green' },
    });
    assert.equal(badColor.status, 400);
    assert.equal(badColor.body.error.code, 'invalid_avatar_color');

    const update = await h.api('/api/v1/me', {
      method: 'PATCH',
      token: user.token,
      body: {
        name: 'Updated',
        about: 'New about',
        avatarColor: '#ABCDEF',
      },
    });
    assert.equal(update.status, 200);
    assert.equal(update.body.user.name, 'Updated');
    assert.equal(update.body.user.about, 'New about');
    assert.equal(update.body.user.avatarColor, '#ABCDEF');
  },
);

test(
  'user search matches name prefix and phone digits without exposing keys',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const alice = await h.login('79990000101', 'Alice');
    const bob = await h.login('79990000102', 'Bob');
    const alvaro = await h.login('79990000103', 'Álvaro');

    const prefixSearch = await h.api('/api/v1/users/search?q=ALI', {
      token: bob.token,
    });
    assert.equal(prefixSearch.status, 200);
    assert.deepEqual(
      prefixSearch.body.users.map((entry) => entry.id),
      [alice.user.id],
    );
    assert.equal(prefixSearch.body.users[0].phone, undefined);
    assert.equal(prefixSearch.body.users[0].identityKey, undefined);
    assert.equal(prefixSearch.body.users[0].online, false);

    const phoneSearch = await h.api('/api/v1/users/search?q=0000103', {
      token: alice.token,
    });
    assert.equal(phoneSearch.status, 200);
    assert.deepEqual(
      phoneSearch.body.users.map((entry) => entry.id),
      [alvaro.user.id],
    );

    const unicodeSearch = await h.api(
      '/api/v1/users/search?q=%C3%A1l',
      { token: alice.token },
    );
    assert.equal(unicodeSearch.status, 200);
    assert.deepEqual(
      unicodeSearch.body.users.map((entry) => entry.id),
      [alvaro.user.id],
    );

    const selfSearch = await h.api('/api/v1/users/search?q=0000101', {
      token: alice.token,
    });
    assert.equal(selfSearch.status, 200);
    assert.equal(
      selfSearch.body.users.some((entry) => entry.id === alice.user.id),
      false,
    );

    const profile = await h.api(`/api/v1/users/${bob.user.id}`, {
      token: alice.token,
    });
    assert.equal(profile.status, 200);
    assert.equal(profile.body.user.id, bob.user.id);
    assert.equal(profile.body.user.phone, undefined);
    assert.equal(profile.body.user.identityKey, undefined);
  },
);

test(
  'contacts can be added idempotently, listed, and deleted',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const alice = await h.login('79990000111', 'Alice');
    const bob = await h.login('79990000112', 'Bob');

    const self = await h.api('/api/v1/contacts', {
      method: 'POST',
      token: alice.token,
      body: { userId: alice.user.id },
    });
    assert.equal(self.status, 400);
    assert.equal(self.body.error.code, 'cannot_add_self');

    const missing = await h.api('/api/v1/contacts', {
      method: 'POST',
      token: alice.token,
      body: { userId: randomUuid() },
    });
    assert.equal(missing.status, 404);

    const added = await h.api('/api/v1/contacts', {
      method: 'POST',
      token: alice.token,
      body: { userId: bob.user.id },
    });
    assert.equal(added.status, 201);
    assert.equal(added.body.contact.id, bob.user.id);

    const addedAgain = await h.api('/api/v1/contacts', {
      method: 'POST',
      token: alice.token,
      body: { userId: bob.user.id },
    });
    assert.equal(addedAgain.status, 201);

    const list = await h.api('/api/v1/contacts', { token: alice.token });
    assert.equal(list.status, 200);
    assert.equal(list.body.contacts.length, 1);
    assert.equal(list.body.contacts[0].id, bob.user.id);
    assert.equal(list.body.contacts[0].phone, undefined);
    assert.equal(list.body.contacts[0].online, false);

    const deleted = await h.api(`/api/v1/contacts/${bob.user.id}`, {
      method: 'DELETE',
      token: alice.token,
    });
    assert.equal(deleted.status, 200);
    assert.equal(deleted.body.ok, true);

    const after = await h.api('/api/v1/contacts', { token: alice.token });
    assert.deepEqual(after.body.contacts, []);
  },
);

test(
  'key upload, bundle retrieval, one-time prekey consumption, and no_keys',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const alice = await h.login('79990000121', 'Alice');
    const bob = await h.login('79990000122', 'Bob');
    const identityKey = base64('alice-identity-key');
    const signedPreKey = {
      id: 7,
      publicKey: base64('alice-signed-prekey'),
      signature: base64('alice-signed-prekey-signature'),
    };
    const preKeys = [
      { id: 1, publicKey: base64('prekey-one') },
      { id: 2, publicKey: base64('prekey-two') },
    ];

    const upload = await h.api('/api/v1/keys', {
      method: 'POST',
      token: alice.token,
      body: {
        identityKey,
        registrationId: 1234,
        signedPreKey,
        preKeys,
      },
    });
    assert.equal(upload.status, 200);
    assert.equal(upload.body.ok, true);

    const stock = await h.api('/api/v1/keys/status', { token: alice.token });
    assert.equal(stock.body.count, 2);

    const info = await h.api(`/api/v1/keys/${alice.user.id}/info`, {
      token: bob.token,
    });
    assert.equal(info.status, 200);
    assert.equal(info.body.identityKey, identityKey);
    assert.equal(info.body.preKey, undefined);

    const conflict = await h.api('/api/v1/keys', {
      method: 'POST',
      token: alice.token,
      body: {
        identityKey: base64('different-identity-key'),
        registrationId: 1234,
        signedPreKey,
        preKeys,
      },
    });
    assert.equal(conflict.status, 409);
    assert.equal(conflict.body.error.code, 'identity_changed');

    const firstBundle = await h.api(`/api/v1/keys/${alice.user.id}`, {
      token: bob.token,
    });
    assert.equal(firstBundle.status, 200);
    assert.equal(firstBundle.body.identityKey, identityKey);
    assert.equal(firstBundle.body.registrationId, 1234);
    assert.deepEqual(firstBundle.body.signedPreKey, signedPreKey);
    assert.equal(firstBundle.body.preKey.id, 1);

    const secondBundle = await h.api(`/api/v1/keys/${alice.user.id}`, {
      token: bob.token,
    });
    assert.equal(secondBundle.status, 200);
    assert.equal(secondBundle.body.preKey.id, 2);

    const exhaustedBundle = await h.api(`/api/v1/keys/${alice.user.id}`, {
      token: bob.token,
    });
    assert.equal(exhaustedBundle.status, 200);
    assert.equal(exhaustedBundle.body.preKey, null);
    const emptyStock = await h.api('/api/v1/keys/status', { token: alice.token });
    assert.equal(emptyStock.body.count, 0);

    const noKeys = await h.api(`/api/v1/keys/${bob.user.id}`, {
      token: alice.token,
    });
    assert.equal(noKeys.status, 404);
    assert.equal(noKeys.body.error.code, 'no_keys');

    const replenish = await h.api('/api/v1/keys/prekeys', {
      method: 'POST',
      token: alice.token,
      body: {
        preKeys: [{ id: 3, publicKey: base64('prekey-three') }],
      },
    });
    assert.equal(replenish.status, 200);
    assert.equal(replenish.body.stored, 1);
    const refilledStock = await h.api('/api/v1/keys/status', { token: alice.token });
    assert.equal(refilledStock.body.count, 1);

    const replenishedBundle = await h.api(`/api/v1/keys/${alice.user.id}`, {
      token: bob.token,
    });
    assert.equal(replenishedBundle.body.preKey.id, 3);
  },
);

test(
  'offline messages are queued, fetched, acknowledged, and notify the sender',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const alice = await h.login('79990000131', 'Alice');
    const bob = await h.login('79990000132', 'Bob');
    const aliceWs = await h.openWs(alice.token);
    await aliceWs.waitFor('ready');

    const firstId = randomUuid();
    const secondId = randomUuid();
    aliceWs.send({
      type: 'message',
      id: firstId,
      to: bob.user.id,
      ciphertext: base64('cipher-one'),
      kind: 'text',
      meta: { n: 1 },
      createdAt: 1000,
    });
    aliceWs.send({
      type: 'message',
      id: secondId,
      to: bob.user.id,
      ciphertext: base64('cipher-two'),
      kind: 'text',
      meta: { n: 2 },
      createdAt: 2000,
    });

    const firstAck = await aliceWs.waitFor(
      (event) => event.type === 'message.ack' && event.id === firstId,
    );
    const secondAck = await aliceWs.waitFor(
      (event) => event.type === 'message.ack' && event.id === secondId,
    );
    assert.equal(firstAck.status, 'queued');
    assert.equal(secondAck.status, 'queued');

    const queued = await h.api('/api/v1/messages/queued', {
      token: bob.token,
    });
    assert.equal(queued.status, 200);
    assert.deepEqual(
      queued.body.messages.map((message) => message.id),
      [firstId, secondId],
    );
    assert.equal(queued.body.messages[0].senderId, alice.user.id);
    assert.equal(queued.body.messages[0].ciphertext, base64('cipher-one'));
    assert.deepEqual(queued.body.messages[0].meta, { n: 1 });

    const ack = await h.api('/api/v1/messages/ack', {
      method: 'POST',
      token: bob.token,
      body: { ids: [firstId, secondId] },
    });
    assert.equal(ack.status, 200);
    assert.equal(ack.body.acked, 2);

    const delivered = await aliceWs.waitFor('message.delivered');
    assert.deepEqual(
      [...delivered.messageIds].sort(),
      [firstId, secondId].sort(),
    );

    const afterAck = await h.api('/api/v1/messages/queued', {
      token: bob.token,
    });
    assert.deepEqual(afterAck.body.messages, []);
    await aliceWs.close();
  },
);

test(
  'push tokens can be registered and removed',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const alice = await h.login('79990000141', 'Alice');
    const token = 'fcm-token-example:APA91b-example';

    const registered = await h.api('/api/v1/push/register', {
      method: 'POST',
      token: alice.token,
      body: { token, platform: 'android' },
    });
    assert.equal(registered.status, 200);
    assert.equal(registered.body.ok, true);

    const removed = await h.api('/api/v1/push/register', {
      method: 'DELETE',
      token: alice.token,
      body: { token },
    });
    assert.equal(removed.status, 200);
    assert.equal(removed.body.ok, true);

    const missing = await h.api('/api/v1/push/register', {
      method: 'POST',
      token: alice.token,
      body: { platform: 'android' },
    });
    assert.equal(missing.status, 400);
  },
);

test(
  'health endpoint, security headers, and CORS preflight work',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t, {
      ALLOWED_ORIGINS: 'https://app.example',
    });

    const health = await h.api('/health');
    assert.equal(health.status, 200);
    assert.deepEqual(health.body, { ok: true, version: '1.1.0' });
    assert.equal(health.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(health.headers.get('x-frame-options'), 'DENY');
    assert.equal(health.headers.get('referrer-policy'), 'no-referrer');

    const preflight = await h.api('/api/v1/me', {
      method: 'OPTIONS',
      headers: {
        Origin: 'https://app.example',
        'Access-Control-Request-Method': 'GET',
      },
    });
    assert.equal(preflight.status, 204);
    assert.equal(
      preflight.headers.get('access-control-allow-origin'),
      'https://app.example',
    );
    assert.match(
      preflight.headers.get('access-control-allow-methods'),
      /GET/,
    );
    assert.match(
      preflight.headers.get('access-control-allow-headers'),
      /Authorization/i,
    );
  },
);

test(
  'request-code is rate limited to five requests per hour per IP',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    for (let index = 1; index <= 5; index += 1) {
      const response = await h.api('/api/v1/auth/request-code', {
        method: 'POST',
        body: { phone: `7999111000${index}` },
      });
      assert.equal(response.status, 200);
      assert.match(response.body.devCode, /^\d{6}$/);
    }

    const limited = await h.api('/api/v1/auth/request-code', {
      method: 'POST',
      body: { phone: '79991110006' },
    });
    assert.equal(limited.status, 429);
    assert.equal(limited.body.error.code, 'rate_limited');
    assert.ok(Number(limited.headers.get('retry-after')) >= 1);
  },
);

test(
  'request-code enforces the per-phone resend cooldown',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const phone = '79990000151';
    const first = await h.api('/api/v1/auth/request-code', {
      method: 'POST',
      body: { phone },
    });
    assert.equal(first.status, 200);

    const second = await h.api('/api/v1/auth/request-code', {
      method: 'POST',
      body: { phone },
    });
    assert.equal(second.status, 429);
    assert.equal(second.body.error.code, 'code_recently_sent');
    assert.ok(Number(second.headers.get('retry-after')) >= 1);
  },
);

test(
  'JSON parsing errors and oversized bodies are rejected',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);

    const invalidJson = await fetch(
      `${h.baseUrl}/api/v1/auth/request-code`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: '{',
      },
    );
    assert.equal(invalidJson.status, 400);
    assert.equal((await invalidJson.json()).error.code, 'invalid_json');

    const oversizedBody = JSON.stringify({
      phone: 'x'.repeat(1024 * 1024 + 10),
    });
    const oversized = await fetch(
      `${h.baseUrl}/api/v1/auth/request-code`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': String(Buffer.byteLength(oversizedBody)),
        },
        body: oversizedBody,
      },
    );
    assert.equal(oversized.status, 413);
    assert.equal((await oversized.json()).error.code, 'payload_too_large');
  },
);
