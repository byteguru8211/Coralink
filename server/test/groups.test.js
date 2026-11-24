'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { startTestApp } = require('./helpers');

async function makeUser(app, phone, name) {
  const session = await app.login(phone, name);
  return session;
}

test('create group returns the group with the creator as owner', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await makeUser(app, '79000000001', 'Alice');

  const res = await app.api('/api/v1/groups', {
    method: 'POST',
    token: alice.token,
    body: { title: 'Coral Crew', members: [] },
  });
  assert.strictEqual(res.status, 201);
  assert.strictEqual(res.body.group.title, 'Coral Crew');
  const owner = res.body.members.find((m) => m.id === alice.user.id);
  assert.strictEqual(owner.role, 'owner');
});

test('non-member cannot read a group', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await makeUser(app, '79000000002', 'Alice');
  const bob = await makeUser(app, '79000000003', 'Bob');

  const created = await app.api('/api/v1/groups', {
    method: 'POST',
    token: alice.token,
    body: { title: 'Private' },
  });
  const gid = created.body.group.id;
  const denied = await app.api(`/api/v1/groups/${gid}`, { token: bob.token });
  assert.strictEqual(denied.status, 403);
});

test('group message is delivered live to online members and queued for offline', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await makeUser(app, '79000000010', 'Alice');
  const bob = await makeUser(app, '79000000011', 'Bob');
  const carol = await makeUser(app, '79000000012', 'Carol');

  const created = await app.api('/api/v1/groups', {
    method: 'POST',
    token: alice.token,
    body: { title: 'Trio', members: [bob.user.id, carol.user.id] },
  });
  assert.strictEqual(created.status, 201);
  const gid = created.body.group.id;

  // Bob online, Carol offline.
  const bobWs = await app.openWs(bob.token);
  const aliceWs = await app.openWs(alice.token);
  await aliceWs.waitFor('ready');
  await bobWs.waitFor('ready');

  const msgId = require('node:crypto').randomUUID();
  aliceWs.send({
    type: 'group.send',
    id: msgId,
    groupId: gid,
    ciphertext: require('./helpers').base64('group-cipher'),
    kind: 'text',
    meta: {},
    createdAt: Date.now(),
  });

  const delivered = await bobWs.waitFor('group.message');
  assert.strictEqual(delivered.message.id, msgId);
  assert.strictEqual(delivered.message.groupId, gid);
  assert.strictEqual(delivered.message.from, alice.user.id);

  const ack = await aliceWs.waitFor('message.ack');
  assert.strictEqual(ack.id, msgId);

  // Carol offline: message is queued and fetched over HTTP.
  const queued = await app.api('/api/v1/groups/queued', { token: carol.token });
  assert.strictEqual(queued.status, 200);
  const mine = queued.body.messages.find((m) => m.id === msgId);
  assert.ok(mine, 'carol should have the group message queued');

  const ackRes = await app.api('/api/v1/groups/ack', {
    method: 'POST',
    token: carol.token,
    body: { ids: [msgId] },
  });
  assert.strictEqual(ackRes.body.acked, 1);
  const receipt = await aliceWs.waitFor('message.delivered');
  assert.deepStrictEqual(receipt.ids, [msgId]);
  const after = await app.api('/api/v1/groups/queued', { token: carol.token });
  assert.ok(!after.body.messages.some((m) => m.id === msgId));
});

test('groups list reports member counts and only admins can update', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await makeUser(app, '79000000040', 'Alice');
  const bob = await makeUser(app, '79000000041', 'Bob');

  const created = await app.api('/api/v1/groups', {
    method: 'POST',
    token: alice.token,
    body: { title: 'Trio', members: [bob.user.id] },
  });
  const gid = created.body.group.id;

  const list = await app.api('/api/v1/groups', { token: alice.token });
  const entry = list.body.groups.find((g) => g.id === gid);
  assert.strictEqual(entry.memberCount, 2);

  const denied = await app.api(`/api/v1/groups/${gid}`, {
    method: 'PATCH',
    token: bob.token,
    body: { title: 'Renamed by member' },
  });
  assert.strictEqual(denied.status, 403);

  const ok = await app.api(`/api/v1/groups/${gid}`, {
    method: 'PATCH',
    token: alice.token,
    body: { title: 'Renamed by owner' },
  });
  assert.strictEqual(ok.status, 200);
  assert.strictEqual(ok.body.group.title, 'Renamed by owner');
});

test('non-member cannot send to a group', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await makeUser(app, '79000000020', 'Alice');
  const outsider = await makeUser(app, '79000000021', 'Outsider');

  const created = await app.api('/api/v1/groups', {
    method: 'POST',
    token: alice.token,
    body: { title: 'Closed' },
  });
  const gid = created.body.group.id;

  const ws = await app.openWs(outsider.token);
  await ws.waitFor('ready');
  ws.send({
    type: 'group.send',
    id: require('node:crypto').randomUUID(),
    groupId: gid,
    ciphertext: require('./helpers').base64('x'),
    kind: 'text',
  });
  const err = await ws.waitFor('error');
  assert.strictEqual(err.code, 'not_a_member');
});
