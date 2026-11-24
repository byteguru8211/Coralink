'use strict';

const { randomUUID } = require('node:crypto');
const { requireAuth } = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const { isBase64String, isPlainObject, isUuidLike } = require('../lib/validate');
const { MAX_PET_PAYLOAD, canonicalDirectChat } = require('../pet_store');

const ACTIONS = new Set(['feed', 'play', 'care', 'sleep', 'rename', 'reset']);

function requireBody(context) {
  if (!isPlainObject(context.body)) {
    throw new HttpError(400, 'invalid_request', 'A JSON object is required');
  }
  return context.body;
}

function requireSnapshot(value) {
  if (!isBase64String(value, MAX_PET_PAYLOAD)) {
    throw new HttpError(400, 'invalid_snapshot', 'Invalid encrypted pet snapshot');
  }
  return value;
}

function notifyMembers(context, pet, type, extra = {}) {
  for (const member of pet?.members || []) {
    if (member.state === 'active' || member.state === 'pending') {
      context.hub.sendToUser(member.userId, {
        type,
        petId: pet.id,
        ...extra,
      });
    }
  }
}

function registerPetRoutes(router) {
  router.add('GET', '/api/v1/pets', async (context) => {
    const user = requireAuth(context);
    sendJson(context.res, 200, { pets: context.petStore.list(user.id) });
  });

  router.add('POST', '/api/v1/pets', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const scope = body.scope;
    if (!['personal', 'direct', 'group'].includes(scope)) {
      throw new HttpError(400, 'invalid_scope', 'Unknown pet scope');
    }
    const snapshot = requireSnapshot(body.snapshot);
    if (!isUuidLike(body.id)) {
      throw new HttpError(400, 'invalid_pet', 'A valid pet id is required');
    }
    let chatId;
    if (scope === 'personal') {
      chatId = `personal:${user.id}`;
    } else if (scope === 'direct') {
      if (!isUuidLike(body.peerId) || body.peerId === user.id) {
        throw new HttpError(400, 'invalid_peer', 'A different peer is required');
      }
      if (!context.db.getUserById(body.peerId)) {
        throw new HttpError(404, 'user_not_found', 'Peer not found');
      }
      chatId = canonicalDirectChat(user.id, body.peerId);
    } else {
      if (!isUuidLike(body.groupId) || !context.db.isGroupMember(body.groupId, user.id)) {
        throw new HttpError(403, 'not_a_member', 'You are not a member of this group');
      }
      chatId = body.groupId;
    }
    const existing = context.petStore.findActive(scope, chatId, user.id);
    if (existing) {
      sendJson(context.res, 200, { pet: existing });
      return;
    }
    let pet;
    try {
      pet = context.petStore.create({
        id: body.id,
        userId: user.id,
        scope,
        chatId,
        snapshot,
      });
    } catch (error) {
      if (error.code === 'ERR_SQLITE_ERROR' && /UNIQUE/i.test(error.message)) {
        throw new HttpError(409, 'pet_exists', 'Pet id or scope is already in use');
      }
      throw error;
    }
    notifyMembers(context, pet, scope === 'direct' ? 'pet.invited' : 'pet.updated');
    sendJson(context.res, 201, { pet });
  });

  router.add('GET', '/api/v1/pets/:id', async (context) => {
    const user = requireAuth(context);
    if (!isUuidLike(context.params.id)) {
      throw new HttpError(400, 'invalid_pet', 'Invalid pet id');
    }
    const afterSeq = Math.max(
      0,
      Number.parseInt(context.url.searchParams.get('afterSeq') || '0', 10) || 0,
    );
    const pet = context.petStore.detail(context.params.id, user.id, afterSeq);
    if (!pet) throw new HttpError(404, 'pet_not_found', 'Pet not found');
    sendJson(context.res, 200, { pet });
  });

  router.add('POST', '/api/v1/pets/:id/operations', async (context) => {
    const user = requireAuth(context);
    if (!isUuidLike(context.params.id)) {
      throw new HttpError(400, 'invalid_pet', 'Invalid pet id');
    }
    const body = requireBody(context);
    if (!isUuidLike(body.id) || !ACTIONS.has(body.action)) {
      throw new HttpError(400, 'invalid_operation', 'Invalid pet operation');
    }
    if (!isBase64String(body.payload, MAX_PET_PAYLOAD)) {
      throw new HttpError(400, 'invalid_payload', 'Invalid encrypted pet operation');
    }
    try {
      const result = context.petStore.addOperation({
        petId: context.params.id,
        userId: user.id,
        operationId: body.id,
        action: body.action,
        payload: body.payload,
      });
      if (!result.duplicate) {
        notifyMembers(context, context.petStore.get(context.params.id, user.id), 'pet.operation', {
          operationId: result.operation.id,
          seq: result.operation.seq,
        });
      }
      sendJson(context.res, result.duplicate ? 200 : 201, result);
    } catch (error) {
      if (error.code === 'rate_limited') {
        throw new HttpError(429, 'rate_limited', 'Too many pet actions');
      }
      if (error.code === 'not_allowed') {
        throw new HttpError(403, 'not_allowed', 'Pet is not active for this user');
      }
      if (error.code === 'duplicate_id') {
        throw new HttpError(409, 'duplicate_id', 'Operation id is already in use');
      }
      throw error;
    }
  });

  router.add('PUT', '/api/v1/pets/:id/snapshot', async (context) => {
    const user = requireAuth(context);
    if (!isUuidLike(context.params.id)) {
      throw new HttpError(400, 'invalid_pet', 'Invalid pet id');
    }
    const body = requireBody(context);
    const seq = Number(body.seq);
    if (!Number.isSafeInteger(seq) || seq < 0) {
      throw new HttpError(400, 'invalid_seq', 'Invalid pet sequence');
    }
    const snapshot = requireSnapshot(body.snapshot);
    try {
      const result = context.petStore.saveSnapshot({
        petId: context.params.id,
        userId: user.id,
        seq,
        snapshot,
      });
      sendJson(context.res, 200, result);
    } catch (error) {
      if (error.code === 'not_allowed') {
        throw new HttpError(403, 'not_allowed', 'Pet is not active for this user');
      }
      throw error;
    }
  });

  router.add('POST', '/api/v1/pets/:id/accept', async (context) => {
    const user = requireAuth(context);
    try {
      const pet = context.petStore.accept(context.params.id, user.id);
      notifyMembers(context, pet, 'pet.updated');
      sendJson(context.res, 200, { pet });
    } catch (error) {
      if (error.code === 'not_allowed') {
        throw new HttpError(403, 'not_allowed', 'No pending invitation');
      }
      throw error;
    }
  });

  router.add('POST', '/api/v1/pets/:id/decline', async (context) => {
    const user = requireAuth(context);
    try {
      const pet = context.petStore.decline(context.params.id, user.id);
      notifyMembers(context, pet, 'pet.updated');
      sendJson(context.res, 200, { ok: true });
    } catch (error) {
      if (error.code === 'not_allowed') {
        throw new HttpError(403, 'not_allowed', 'No pending invitation');
      }
      throw error;
    }
  });

  router.add('POST', '/api/v1/pets/:id/release', async (context) => {
    const user = requireAuth(context);
    const pet = context.petStore.release(context.params.id, user.id);
    if (!pet) throw new HttpError(404, 'pet_not_found', 'Pet not found');
    notifyMembers(context, pet, 'pet.updated');
    sendJson(context.res, 200, { ok: true });
  });
}

module.exports = { registerPetRoutes };
