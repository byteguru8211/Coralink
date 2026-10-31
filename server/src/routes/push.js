'use strict';

const { requireAuth } = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const {
  isPlainObject,
  isPlatform,
  isSafeTokenString,
} = require('../lib/validate');

function requireBody(context) {
  if (!isPlainObject(context.body)) {
    throw new HttpError(400, 'invalid_request', 'A JSON object is required');
  }
  return context.body;
}

function readToken(body) {
  if (typeof body.token !== 'string') {
    throw new HttpError(400, 'invalid_token', 'A push token is required');
  }
  const token = body.token.trim();
  if (!isSafeTokenString(token, 1, 4096)) {
    throw new HttpError(400, 'invalid_token', 'Invalid push token');
  }
  return token;
}

function registerPushRoutes(router) {
  router.add('POST', '/api/v1/push/register', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const token = readToken(body);
    if (!isPlatform(body.platform)) {
      throw new HttpError(400, 'invalid_platform', 'Invalid platform');
    }
    context.db.registerPushToken(
      user.id,
      token,
      body.platform,
      Date.now(),
    );
    sendJson(context.res, 200, { ok: true });
  });

  router.add('DELETE', '/api/v1/push/register', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const token = readToken(body);
    context.db.deletePushToken(user.id, token);
    sendJson(context.res, 200, { ok: true });
  });
}

module.exports = {
  registerPushRoutes,
};
