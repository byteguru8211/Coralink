'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { startTestApp, base64, randomUuid } = require('./helpers');

async function createPet(app, session, body) {
  return app.api('/api/v1/pets', {
    method: 'POST',
    token: session.token,
    body: { id: randomUuid(), snapshot: base64('encrypted-pet-state'), ...body },
  });
}

test('personal pet persists encrypted state and ordered operations', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await app.login('79000001001', 'Alice');

  const created = await createPet(app, alice, { scope: 'personal' });
  assert.equal(created.status, 201);
  assert.equal(created.body.pet.scope, 'personal');
  assert.equal(created.body.pet.status, 'active');
  const petId = created.body.pet.id;

  const operationId = randomUuid();
  const operation = await app.api(`/api/v1/pets/${petId}/operations`, {
    method: 'POST',
    token: alice.token,
    body: { id: operationId, action: 'feed', payload: base64('encrypted-feed') },
  });
  assert.equal(operation.status, 201);
  assert.equal(operation.body.operation.seq, 1);

  const duplicate = await app.api(`/api/v1/pets/${petId}/operations`, {
    method: 'POST',
    token: alice.token,
    body: { id: operationId, action: 'feed', payload: base64('encrypted-feed') },
  });
  assert.equal(duplicate.status, 200);
  assert.equal(duplicate.body.operation.seq, 1);
  assert.equal(duplicate.body.duplicate, true);

  const detail = await app.api(`/api/v1/pets/${petId}`, { token: alice.token });
  assert.equal(detail.body.pet.operations.length, 1);
  assert.equal(detail.body.pet.operations[0].payload, base64('encrypted-feed'));

  const snapshot = await app.api(`/api/v1/pets/${petId}/snapshot`, {
    method: 'PUT',
    token: alice.token,
    body: { seq: 1, snapshot: base64('new-encrypted-state') },
  });
  assert.equal(snapshot.body.saved, true);
  const stale = await app.api(`/api/v1/pets/${petId}/snapshot`, {
    method: 'PUT',
    token: alice.token,
    body: { seq: 0, snapshot: base64('stale-state') },
  });
  assert.equal(stale.body.saved, false);
});

test('direct pet requires mutual acceptance and rejects outsiders', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await app.login('79000001002', 'Alice');
  const bob = await app.login('79000001003', 'Bob');
  const carol = await app.login('79000001004', 'Carol');

  const created = await createPet(app, alice, { scope: 'direct', peerId: bob.user.id });
  assert.equal(created.status, 201);
  assert.equal(created.body.pet.status, 'pending');
  const petId = created.body.pet.id;
  const bobPets = await app.api('/api/v1/pets', { token: bob.token });
  assert.equal(bobPets.body.pets[0].membershipState, 'pending');

  const early = await app.api(`/api/v1/pets/${petId}/operations`, {
    method: 'POST',
    token: alice.token,
    body: { id: randomUuid(), action: 'care', payload: base64('care') },
  });
  assert.equal(early.status, 403);

  const accepted = await app.api(`/api/v1/pets/${petId}/accept`, {
    method: 'POST',
    token: bob.token,
  });
  assert.equal(accepted.status, 200);
  assert.equal(accepted.body.pet.status, 'active');

  const operation = await app.api(`/api/v1/pets/${petId}/operations`, {
    method: 'POST',
    token: alice.token,
    body: { id: randomUuid(), action: 'care', payload: base64('care') },
  });
  assert.equal(operation.status, 201);

  const outsider = await app.api(`/api/v1/pets/${petId}`, { token: carol.token });
  assert.equal(outsider.status, 404);
});

test('group pet access follows current membership', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await app.login('79000001005', 'Alice');
  const bob = await app.login('79000001006', 'Bob');
  const group = await app.api('/api/v1/groups', {
    method: 'POST',
    token: alice.token,
    body: { title: 'Reef', members: [bob.user.id] },
  });
  const created = await createPet(app, bob, {
    scope: 'group',
    groupId: group.body.group.id,
  });
  assert.equal(created.status, 201);
  assert.equal(created.body.pet.members.length, 2);
  const petId = created.body.pet.id;

  await app.api(`/api/v1/groups/${group.body.group.id}/members/${bob.user.id}`, {
    method: 'DELETE',
    token: alice.token,
  });
  const removedRead = await app.api(`/api/v1/pets/${petId}`, { token: bob.token });
  assert.equal(removedRead.status, 404);
  const removedWrite = await app.api(`/api/v1/pets/${petId}/operations`, {
    method: 'POST',
    token: bob.token,
    body: { id: randomUuid(), action: 'feed', payload: base64('feed') },
  });
  assert.equal(removedWrite.status, 403);
});

test('declined direct invitation archives the pet', async (t) => {
  const app = await startTestApp();
  t.after(() => app.close());
  const alice = await app.login('79000001007', 'Alice');
  const bob = await app.login('79000001008', 'Bob');
  const created = await createPet(app, alice, { scope: 'direct', peerId: bob.user.id });
  const declined = await app.api(`/api/v1/pets/${created.body.pet.id}/decline`, {
    method: 'POST',
    token: bob.token,
  });
  assert.equal(declined.status, 200);
  const alicePets = await app.api('/api/v1/pets', { token: alice.token });
  assert.equal(alicePets.body.pets.length, 0);
});
