'use strict';

const { requireAuth } = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const {
  isBase64String,
  isPlainObject,
  isUuidLike,
  toSafeInteger,
} = require('../lib/validate');

const KEY_MAX_BYTES = 16 * 1024;
const PREKEY_MAX_BYTES = 8 * 1024;
const MAX_PREKEYS = 100;

function requireBody(context) {
  if (!isPlainObject(context.body)) {
    throw new HttpError(400, 'invalid_request', 'A JSON object is required');
  }
  return context.body;
}

function validatePreKeys(preKeys) {
  if (
    !Array.isArray(preKeys) ||
    preKeys.length < 1 ||
    preKeys.length > MAX_PREKEYS
  ) {
    throw new HttpError(
      400,
      'invalid_prekeys',
      `preKeys must contain between 1 and ${MAX_PREKEYS} entries`,
    );
  }
  const seen = new Set();
  return preKeys.map((entry) => {
    if (!isPlainObject(entry)) {
      throw new HttpError(400, 'invalid_prekeys', 'Invalid prekey entry');
    }
    const id = toSafeInteger(entry.id, 0, 0x7fffffff);
    if (id === null || seen.has(id)) {
      throw new HttpError(
        400,
        'invalid_prekeys',
        'Prekey ids must be unique non-negative integers',
      );
    }
    if (!isBase64String(entry.publicKey, PREKEY_MAX_BYTES)) {
      throw new HttpError(400, 'invalid_prekeys', 'Invalid prekey public key');
    }
    seen.add(id);
    return { id, publicKey: entry.publicKey };
  });
}

function registerKeyRoutes(router) {
  router.add('POST', '/api/v1/keys', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);

    if (!isBase64String(body.identityKey, KEY_MAX_BYTES)) {
      throw new HttpError(400, 'invalid_identity_key', 'Invalid identityKey');
    }
    const registrationId = toSafeInteger(
      body.registrationId,
      0,
      0x7fffffff,
    );
    if (registrationId === null) {
      throw new HttpError(
        400,
        'invalid_registration_id',
        'registrationId must be a non-negative integer',
      );
    }
    if (!isPlainObject(body.signedPreKey)) {
      throw new HttpError(
        400,
        'invalid_signed_prekey',
        'signedPreKey is required',
      );
    }
    const signedPreKeyId = toSafeInteger(
      body.signedPreKey.id,
      0,
      0x7fffffff,
    );
    if (
      signedPreKeyId === null ||
      !isBase64String(body.signedPreKey.publicKey, KEY_MAX_BYTES) ||
      !isBase64String(body.signedPreKey.signature, KEY_MAX_BYTES)
    ) {
      throw new HttpError(
        400,
        'invalid_signed_prekey',
        'signedPreKey must contain id, publicKey, and signature',
      );
    }
    const preKeys = validatePreKeys(body.preKeys);

    context.db.saveKeys(user.id, {
      identityKey: body.identityKey,
      registrationId,
      signedPreKey: {
        id: signedPreKeyId,
        publicKey: body.signedPreKey.publicKey,
        signature: body.signedPreKey.signature,
      },
      preKeys,
    });
    sendJson(context.res, 200, { ok: true });
  });

  router.add('POST', '/api/v1/keys/prekeys', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const preKeys = validatePreKeys(body.preKeys);
    context.db.replenishPreKeys(user.id, preKeys);
    sendJson(context.res, 200, { ok: true, stored: preKeys.length });
  });

  router.add('GET', '/api/v1/keys/:userId', async (context) => {
    requireAuth(context);
    if (!isUuidLike(context.params.userId)) {
      throw new HttpError(400, 'invalid_user_id', 'Invalid user id');
    }
    const bundle = context.db.getKeyBundleAndConsume(context.params.userId);
    if (!bundle) {
      throw new HttpError(404, 'no_keys', 'No keys available for this user');
    }
    sendJson(context.res, 200, bundle);
  });
}

module.exports = {
  registerKeyRoutes,
};
