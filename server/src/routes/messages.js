'use strict';

const { requireAuth } = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const { isPlainObject, isUuidLike } = require('../lib/validate');

const MAX_BATCH = 500;

function requireBody(context) {
  if (!isPlainObject(context.body)) {
    throw new HttpError(400, 'invalid_request', 'A JSON object is required');
  }
  return context.body;
}

function validateIds(ids) {
  if (!Array.isArray(ids) || ids.length > MAX_BATCH) {
    throw new HttpError(
      400,
      'invalid_ids',
      `ids must be an array of at most ${MAX_BATCH} message ids`,
    );
  }
  for (const id of ids) {
    if (!isUuidLike(id)) {
      throw new HttpError(400, 'invalid_ids', 'Invalid message id');
    }
  }
  return ids;
}

function registerMessageRoutes(router) {
  router.add('GET', '/api/v1/messages/queued', async (context) => {
    const user = requireAuth(context);
    const messages = context.db.getQueuedMessages(user.id, Date.now(), MAX_BATCH);
    sendJson(context.res, 200, {
      messages: messages.map((message) => ({
        id: message.id,
        senderId: message.senderId,
        ciphertext: message.ciphertext,
        kind: message.kind,
        meta: message.meta,
        createdAt: message.createdAt,
      })),
    });
  });

  router.add('POST', '/api/v1/messages/read', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const ids = validateIds(body.ids);
    const chatWith = typeof body.chatWith === 'string' ? body.chatWith : '';
    if (!chatWith || !context.db.getUserById(chatWith)) {
      throw new HttpError(400, 'invalid_chat', 'A valid chat recipient is required');
    }
    const readIds = context.db.markMessagesRead(user.id, chatWith, ids, Date.now());
    for (const id of readIds) {
      context.hub.sendToUser(chatWith, {
        type: 'message.read',
        messageIds: [id],
        ids: [id],
        by: user.id,
      });
    }
    sendJson(context.res, 200, { ok: true, read: readIds });
  });

  router.add('POST', '/api/v1/messages/status', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const ids = validateIds(body.ids);
    sendJson(context.res, 200, {
      statuses: context.db.getMessageStatusesForSender(user.id, ids),
    });
  });

  router.add('POST', '/api/v1/messages/ack', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    const ids = validateIds(body.ids);
    const result = context.db.ackMessages(user.id, ids, Date.now());
    for (const group of result.bySender) {
      context.hub.sendToUser(group.senderId, {
        type: 'message.delivered',
        messageIds: group.messageIds,
        ids: group.messageIds,
      });
    }
    sendJson(context.res, 200, { ok: true, acked: result.acked });
  });
}

module.exports = {
  MAX_BATCH,
  registerMessageRoutes,
  validateIds,
};
