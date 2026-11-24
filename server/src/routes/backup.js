'use strict';

const { requireAuth } = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const { isBase64String, isPlainObject } = require('../lib/validate');

// The backup is an opaque AES-GCM ciphertext blob produced client-side from a
// password-derived key. The server never sees plaintext keys, only this blob and
// the KDF salt. Cap it generously (the Signal state with prekeys/sessions is
// well under this) to bound storage.
const BACKUP_MAX_BYTES = 1024 * 1024;

function requireBody(context) {
  if (!isPlainObject(context.body)) {
    throw new HttpError(400, 'invalid_request', 'A JSON object is required');
  }
  return context.body;
}

function registerBackupRoutes(router) {
  router.add('PUT', '/api/v1/backup', async (context) => {
    const user = requireAuth(context);
    const body = requireBody(context);
    if (typeof body.blob !== 'string' || !isBase64String(body.blob, BACKUP_MAX_BYTES)) {
      throw new HttpError(400, 'invalid_backup', 'blob must be base64 within size limit');
    }
    if (typeof body.salt !== 'string' || !isBase64String(body.salt, 256)) {
      throw new HttpError(400, 'invalid_backup', 'salt must be base64');
    }
    const revision = Number.isSafeInteger(body.revision) && body.revision >= 0
      ? body.revision
      : 0;
    const result = context.db.saveBackup(
      user.id,
      body.blob,
      body.salt,
      Date.now(),
      revision,
    );
    sendJson(context.res, 200, { ok: true, ...result });
  });

  router.add('GET', '/api/v1/backup', async (context) => {
    const user = requireAuth(context);
    const backup = context.db.getBackup(user.id);
    if (!backup) {
      throw new HttpError(404, 'no_backup', 'No key backup stored for this account');
    }
    sendJson(context.res, 200, {
      blob: backup.blob,
      salt: backup.salt,
      updatedAt: backup.updatedAt,
      revision: backup.revision,
    });
  });
}

module.exports = { registerBackupRoutes };
