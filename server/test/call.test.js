'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { startTestApp } = require('./helpers');

test('call signaling is relayed between two online peers', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await app.login('79000000030', 'Alice');
  const bob = await app.login('79000000031', 'Bob');

  const bobWs = await app.openWs(bob.token);
  await bobWs.waitFor('ready');
  const aliceWs = await app.openWs(alice.token);
  await aliceWs.waitFor('ready');

  aliceWs.send({
    type: 'call',
    to: bob.user.id,
    data: { action: 'call', mode: 'video', sdp: 'v=0 fake' },
  });
  const incoming = await bobWs.waitFor('call');
  assert.strictEqual(incoming.from, alice.user.id);
  assert.strictEqual(incoming.data.action, 'call');
  assert.strictEqual(incoming.data.mode, 'video');
});

test('call to an offline peer returns a busy notice', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await app.login('79000000032', 'Alice');
  const carol = await app.login('79000000033', 'Carol');

  const aliceWs = await app.openWs(alice.token);
  await aliceWs.waitFor('ready');

  aliceWs.send({
    type: 'call',
    to: carol.user.id,
    data: { action: 'call', mode: 'audio', sdp: 'v=0 fake' },
  });
  const busy = await aliceWs.waitFor((e) => e.type === 'call' && e.data?.action === 'busy');
  assert.ok(busy);
});
