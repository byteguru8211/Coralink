'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { base64, randomUuid, startTestApp } = require('./helpers');

const TEST_TIMEOUT = 20_000;

async function harness(t) {
  const h = await startTestApp();
  t.after(async () => {
    await h.close();
  });
  return h;
}

async function pair(h) {
  const alice = await h.login('79993000001', 'Alice');
  const bob = await h.login('79993000002', 'Bob');
  const aliceWs = await h.openWs(alice.token);
  const bobWs = await h.openWs(bob.token);
  await aliceWs.waitFor('ready');
  await bobWs.waitFor('ready');
  return { alice, bob, aliceWs, bobWs };
}

test(
  'control envelopes are relayed like regular messages',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await harness(t);
    const { bob, aliceWs, bobWs } = await pair(h);
    const id = randomUuid();
    aliceWs.send({
      type: 'message',
      id,
      to: bob.user.id,
      ciphertext: base64('opaque-control-envelope'),
      kind: 'control',
      meta: {},
      createdAt: Date.now(),
    });
    const event = await bobWs.waitFor('message');
    assert.equal(event.message.id, id);
    assert.equal(event.message.kind, 'control');
  },
);

test(
  'ICE candidates keep sdpMid and sdpMLineIndex metadata',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await harness(t);
    const { bob, aliceWs, bobWs } = await pair(h);
    aliceWs.send({
      type: 'signal',
      to: bob.user.id,
      data: {
        kind: 'ice',
        candidate: 'candidate:1 1 udp 1 127.0.0.1 5000 typ host',
        sdpMid: '0',
        sdpMLineIndex: 0,
      },
    });
    const event = await bobWs.waitFor('signal');
    assert.equal(event.data.kind, 'ice');
    assert.equal(event.data.sdpMid, '0');
    assert.equal(event.data.sdpMLineIndex, 0);
  },
);

test(
  'DELETE /me removes the account and closes its sockets',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await harness(t);
    const user = await h.login('79993000003', 'To Delete');
    const ws = await h.openWs(user.token);
    await ws.waitFor('ready');

    const removed = await h.api('/api/v1/me', {
      method: 'DELETE',
      token: user.token,
    });
    assert.equal(removed.status, 200);
    assert.equal(removed.body.ok, true);

    const me = await h.api('/api/v1/me', { token: user.token });
    assert.equal(me.status, 401);

    await ws.closePromise;

    const again = await h.login('79993000003', 'Reborn');
    assert.equal(again.isNew, true);
  },
);
