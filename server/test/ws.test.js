'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { WebSocket } = require('ws');
const { base64, randomUuid, startTestApp } = require('./helpers');

const TEST_TIMEOUT = 20_000;

async function createHarness(t) {
  const harness = await startTestApp();
  t.after(async () => {
    await harness.close();
  });
  return harness;
}

async function connectPair(h, phoneA = '79992000001', phoneB = '79992000002') {
  const alice = await h.login(phoneA, 'Alice');
  const bob = await h.login(phoneB, 'Bob');
  const aliceWs = await h.openWs(alice.token);
  const bobWs = await h.openWs(bob.token);
  assert.equal((await aliceWs.waitFor('ready')).userId, alice.user.id);
  assert.equal((await bobWs.waitFor('ready')).userId, bob.user.id);
  return { alice, bob, aliceWs, bobWs };
}

function expectUpgradeStatus(url, expectedStatus) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { handshakeTimeout: 3000 });
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.terminate();
      reject(new Error('Timed out waiting for upgrade rejection'));
    }, 4000);

    socket.on('unexpected-response', (request, response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        body += chunk;
      });
      response.on('end', () => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        try {
          assert.equal(response.statusCode, expectedStatus);
          const parsed = JSON.parse(body);
          assert.equal(typeof parsed.error.code, 'string');
          resolve(response.statusCode);
        } catch (error) {
          reject(error);
        }
      });
      response.on('error', (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(error);
      });
    });
    socket.on('open', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.terminate();
      reject(new Error('Expected WebSocket upgrade to be rejected'));
    });
    socket.on('error', (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
  });
}

test(
  'WebSocket upgrade rejects missing and invalid tokens with 401',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    await expectUpgradeStatus(h.wsBaseUrl, 401);
    await expectUpgradeStatus(`${h.wsBaseUrl}?token=invalid.jwt.value`, 401);
  },
);

test(
  'WebSocket connection sends ready with user id and server time',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const user = await h.login('79992000011', 'Ready User');
    const ws = await h.openWs(user.token);
    const ready = await ws.waitFor('ready');
    assert.equal(ready.userId, user.user.id);
    assert.equal(typeof ready.serverTime, 'number');
    await ws.close();
  },
);

test(
  'client heartbeat ping is answered with pong instead of an error',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const user = await h.login('79992000012', 'Ping User');
    const ws = await h.openWs(user.token);
    await ws.waitFor('ready');

    ws.send({ type: 'ping' });
    const pong = await ws.waitFor(
      (event) => event.type === 'pong' || event.type === 'error',
    );
    assert.equal(pong.type, 'pong');
    await ws.close();
  },
);

test(
  'online message delivery returns a delivered ack and recipient ack notifies sender',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const { alice, bob, aliceWs, bobWs } = await connectPair(
      h,
      '79992000021',
      '79992000022',
    );
    const messageId = randomUuid();

    aliceWs.send({
      type: 'message',
      id: messageId,
      to: bob.user.id,
      ciphertext: base64('online-cipher'),
      kind: 'text',
      meta: { replyTo: null },
    });

    const delivery = await bobWs.waitFor('message');
    assert.equal(delivery.message.id, messageId);
    assert.equal(delivery.message.from, alice.user.id);
    assert.equal(delivery.message.ciphertext, base64('online-cipher'));
    assert.deepEqual(delivery.message.meta, { replyTo: null });

    const sendAck = await aliceWs.waitFor(
      (event) => event.type === 'message.ack' && event.id === messageId,
    );
    assert.equal(sendAck.status, 'delivered');

    bobWs.send({
      type: 'message.ack',
      ids: [messageId],
    });
    const ackOk = await bobWs.waitFor('message.ack.ok');
    assert.deepEqual(ackOk.ids, [messageId]);

    const receipt = await aliceWs.waitFor('message.delivered');
    assert.deepEqual(receipt.messageIds, [messageId]);

    await aliceWs.close();
    await bobWs.close();
  },
);

test(
  'offline message is queued and can be fetched after connecting',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const alice = await h.login('79992000031', 'Alice');
    const bob = await h.login('79992000032', 'Bob');
    const aliceWs = await h.openWs(alice.token);
    await aliceWs.waitFor('ready');

    const messageId = randomUuid();
    aliceWs.send({
      type: 'message',
      id: messageId,
      to: bob.user.id,
      ciphertext: base64('offline-cipher'),
      createdAt: 12345,
    });
    const ack = await aliceWs.waitFor(
      (event) => event.type === 'message.ack' && event.id === messageId,
    );
    assert.equal(ack.status, 'queued');
    await aliceWs.close();

    const bobWs = await h.openWs(bob.token);
    await bobWs.waitFor('ready');
    const queued = await h.api('/api/v1/messages/queued', {
      token: bob.token,
    });
    assert.equal(queued.status, 200);
    assert.equal(queued.body.messages.length, 1);
    assert.equal(queued.body.messages[0].id, messageId);
    assert.equal(queued.body.messages[0].senderId, alice.user.id);
    assert.equal(queued.body.messages[0].createdAt, 12345);
    await bobWs.close();
  },
);

test(
  'read receipt is relayed to the original sender',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const { alice, bob, aliceWs, bobWs } = await connectPair(
      h,
      '79992000041',
      '79992000042',
    );
    const messageId = randomUuid();

    aliceWs.send({
      type: 'message',
      id: messageId,
      to: bob.user.id,
      ciphertext: base64('read-cipher'),
    });
    await bobWs.waitFor(
      (event) => event.type === 'message' && event.message.id === messageId,
    );
    await aliceWs.waitFor(
      (event) => event.type === 'message.ack' && event.id === messageId,
    );
    bobWs.send({ type: 'message.ack', ids: [messageId] });
    await bobWs.waitFor('message.ack.ok');
    await aliceWs.waitFor('message.delivered');

    bobWs.send({
      type: 'message.read',
      chatWith: alice.user.id,
      ids: [messageId],
    });
    const read = await aliceWs.waitFor('message.read');
    assert.deepEqual(read.messageIds, [messageId]);
    assert.equal(read.by, bob.user.id);

    await aliceWs.close();
    await bobWs.close();
  },
);

test(
  'signaling routes offers, answers, and ICE candidates only to connected peers',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const { alice, bob, aliceWs, bobWs } = await connectPair(
      h,
      '79992000051',
      '79992000052',
    );

    aliceWs.send({
      type: 'signal',
      to: bob.user.id,
      data: { kind: 'offer', sdp: 'v=0\r\noffer' },
    });
    const offer = await bobWs.waitFor('signal');
    assert.equal(offer.from, alice.user.id);
    assert.deepEqual(offer.data, { kind: 'offer', sdp: 'v=0\r\noffer' });

    bobWs.send({
      type: 'signal',
      to: alice.user.id,
      data: { kind: 'answer', sdp: 'v=0\r\nanswer' },
    });
    const answer = await aliceWs.waitFor('signal');
    assert.equal(answer.from, bob.user.id);
    assert.equal(answer.data.kind, 'answer');

    aliceWs.send({
      type: 'signal',
      to: bob.user.id,
      data: {
        kind: 'ice',
        candidate: {
          candidate: 'candidate:1 1 udp 1 192.0.2.1 5000 typ host',
          sdpMid: '0',
        },
      },
    });
    const ice = await bobWs.waitFor('signal');
    assert.equal(ice.data.kind, 'ice');
    assert.equal(ice.data.candidate.sdpMid, '0');

    await aliceWs.close();
    await bobWs.close();
  },
);

test(
  'typing events are relayed to connected peers',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const { alice, bob, aliceWs, bobWs } = await connectPair(
      h,
      '79992000061',
      '79992000062',
    );

    aliceWs.send({
      type: 'typing',
      to: bob.user.id,
      on: true,
    });
    const typing = await bobWs.waitFor('typing');
    assert.equal(typing.from, alice.user.id);
    assert.equal(typing.on, true);

    aliceWs.send({
      type: 'typing',
      to: bob.user.id,
      on: false,
    });
    const stopped = await bobWs.waitFor('typing');
    assert.equal(stopped.on, false);

    await aliceWs.close();
    await bobWs.close();
  },
);

test(
  'presence changes broadcast to contacts and HTTP reports online',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const alice = await h.login('79992000071', 'Alice');
    const bob = await h.login('79992000072', 'Bob');
    const added = await h.api('/api/v1/contacts', {
      method: 'POST',
      token: bob.token,
      body: { userId: alice.user.id },
    });
    assert.equal(added.status, 201);

    const bobWs = await h.openWs(bob.token);
    await bobWs.waitFor('ready');
    const aliceWs = await h.openWs(alice.token);
    await aliceWs.waitFor('ready');

    const online = await bobWs.waitFor('presence');
    assert.equal(online.userId, alice.user.id);
    assert.equal(online.status, 'online');
    assert.equal(typeof online.lastSeen, 'number');

    const aliceMe = await h.api('/api/v1/me', { token: alice.token });
    assert.equal(aliceMe.body.user.online, true);

    aliceWs.send({ type: 'presence', status: 'away' });
    const away = await bobWs.waitFor(
      (event) => event.type === 'presence' && event.status === 'away',
    );
    assert.equal(away.userId, alice.user.id);

    const presence = await h.api(
      `/api/v1/presence?ids=${alice.user.id},${bob.user.id}`,
      { token: bob.token },
    );
    assert.equal(presence.status, 200);
    assert.equal(presence.body.presence[alice.user.id].online, true);
    assert.equal(presence.body.presence[bob.user.id].online, true);

    await aliceWs.close();
    const offline = await bobWs.waitFor(
      (event) => event.type === 'presence' && event.status === 'offline',
    );
    assert.equal(offline.userId, alice.user.id);
    assert.equal(typeof offline.lastSeen, 'number');

    await bobWs.close();
  },
);

test(
  'signaling an offline peer returns peer_offline',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const alice = await h.login('79992000081', 'Alice');
    const bob = await h.login('79992000082', 'Bob');
    const aliceWs = await h.openWs(alice.token);
    await aliceWs.waitFor('ready');

    aliceWs.send({
      type: 'signal',
      to: bob.user.id,
      data: { kind: 'offer', sdp: 'v=0' },
    });
    const error = await aliceWs.waitFor('error');
    assert.equal(error.code, 'peer_offline');
    await aliceWs.close();
  },
);

test(
  'duplicate message ids are idempotent and are not delivered twice',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const { alice, bob, aliceWs, bobWs } = await connectPair(
      h,
      '79992000091',
      '79992000092',
    );
    const messageId = randomUuid();
    const event = {
      type: 'message',
      id: messageId,
      to: bob.user.id,
      ciphertext: base64('idempotent-cipher'),
    };

    aliceWs.send(event);
    await bobWs.waitFor(
      (incoming) =>
        incoming.type === 'message' && incoming.message.id === messageId,
    );
    await aliceWs.waitFor(
      (incoming) =>
        incoming.type === 'message.ack' && incoming.id === messageId,
    );

    aliceWs.send(event);
    const secondAck = await aliceWs.waitFor(
      (incoming) =>
        incoming.type === 'message.ack' && incoming.id === messageId,
    );
    assert.ok(['delivered', 'queued'].includes(secondAck.status));

    const duplicateDelivery = bobWs.events.find(
      (incoming) =>
        incoming.type === 'message' && incoming.message.id === messageId,
    );
    assert.equal(duplicateDelivery, undefined);

    const queued = await h.api('/api/v1/messages/queued', {
      token: bob.token,
    });
    assert.equal(queued.body.messages.length, 1);
    assert.equal(queued.body.messages[0].id, messageId);

    await aliceWs.close();
    await bobWs.close();
  },
);

test(
  'unknown WebSocket event types return an error without closing the socket',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const user = await h.login('79992000101', 'Protocol User');
    const ws = await h.openWs(user.token);
    await ws.waitFor('ready');

    ws.send({ type: 'not.a.real.event' });
    const error = await ws.waitFor('error');
    assert.equal(error.code, 'unknown_type');

    ws.send({ type: 'presence', status: 'active' });
    // Still connected: a subsequent valid event should be processed without
    // waiting for a reply, so verify the socket remains usable by closing it.
    assert.equal(ws.closed, false);
    await ws.close();
  },
);

test(
  'oversized meta is rejected so attachment bytes never ride the wire meta',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const { alice, bob, aliceWs, bobWs } = await connectPair(
      h,
      '79992000111',
      '79992000112',
    );

    aliceWs.send({
      type: 'message',
      id: randomUuid(),
      to: bob.user.id,
      ciphertext: base64('file-cipher'),
      kind: 'file',
      meta: { data: 'A'.repeat(20 * 1024) },
    });
    const error = await aliceWs.waitFor('error');
    assert.equal(error.code, 'invalid_event');
    assert.equal(bobWs.events.find((e) => e.type === 'message'), undefined);

    await aliceWs.close();
    await bobWs.close();
  },
);

test(
  'file-kind message with small meta relays its ciphertext to the recipient',
  { timeout: TEST_TIMEOUT },
  async (t) => {
    const h = await createHarness(t);
    const { alice, bob, aliceWs, bobWs } = await connectPair(
      h,
      '79992000121',
      '79992000122',
    );
    // ~50 KB of ciphertext (the encrypted envelope carries the payload),
    // with only descriptor fields in the wire meta.
    const ciphertext = base64('x'.repeat(50 * 1024));
    const messageId = randomUuid();

    aliceWs.send({
      type: 'message',
      id: messageId,
      to: bob.user.id,
      ciphertext,
      kind: 'file',
      meta: { mime: 'application/pdf', name: 'doc.pdf', size: 50 * 1024 },
    });

    const delivery = await bobWs.waitFor(
      (e) => e.type === 'message' && e.message.id === messageId,
    );
    assert.equal(delivery.message.kind, 'file');
    assert.equal(delivery.message.ciphertext, ciphertext);
    assert.deepEqual(delivery.message.meta, {
      mime: 'application/pdf',
      name: 'doc.pdf',
      size: 50 * 1024,
    });

    await aliceWs.close();
    await bobWs.close();
  },
);
