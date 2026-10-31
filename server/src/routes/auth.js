'use strict';

const { randomUUID } = require('node:crypto');
const {
  CODE_MAX_ATTEMPTS,
  CODE_RESEND_MS,
  CODE_TTL_MS,
  constantTimeEqualHex,
  generateAuthCode,
  hashAuthCode,
  signJwt,
} = require('../auth');
const { HttpError, sendJson } = require('../lib/http');
const { maskPhone } = require('../lib/log');
const {
  isPlainObject,
  normalizeAbout,
  normalizeName,
  normalizePhone,
} = require('../lib/validate');
const { toPrivateUser } = require('./users');

const DEFAULT_NAME = 'Гость';

function requireBody(context) {
  if (!isPlainObject(context.body)) {
    throw new HttpError(400, 'invalid_request', 'A JSON object is required');
  }
  return context.body;
}

function retryAfterUntil(timestamp, now) {
  return Math.max(1, Math.ceil((timestamp - now) / 1000));
}

function registerAuthRoutes(router) {
  router.add(
    'POST',
    '/api/v1/auth/request-code',
    async (context) => {
      const body = requireBody(context);
      const phone = normalizePhone(body.phone);
      if (!phone) {
        throw new HttpError(
          400,
          'invalid_phone',
          'Phone must contain between 10 and 15 digits',
        );
      }

      const now = Date.now();
      const existing = context.db.getAuthCode(phone);
      if (existing && now < Number(existing.created_at) + CODE_RESEND_MS) {
        const retryAfter = retryAfterUntil(
          Number(existing.created_at) + CODE_RESEND_MS,
          now,
        );
        throw new HttpError(
          429,
          'code_recently_sent',
          'Wait before requesting another code',
          { retryAfter },
        );
      }

      const code = generateAuthCode();
      const codeHash = hashAuthCode(phone, code, context.config.authPepper);
      context.db.upsertAuthCode(phone, codeHash, now + CODE_TTL_MS, now);

      if (context.config.devMode) {
        context.logger.info('auth_code_issued', {
          phone: maskPhone(phone),
          devCode: code,
        });
      }

      const response = { ok: true, retryAfter: CODE_RESEND_MS / 1000 };
      if (context.config.devMode) response.devCode = code;
      sendJson(context.res, 200, response);
    },
    { rateLimit: 'requestCode' },
  );

  router.add(
    'POST',
    '/api/v1/auth/verify',
    async (context) => {
      const body = requireBody(context);
      const phone = normalizePhone(body.phone);
      if (!phone) {
        throw new HttpError(401, 'invalid_code', 'Invalid or expired code');
      }

      const now = Date.now();
      const record = context.db.getAuthCode(phone);
      if (!record || Number(record.expires_at) <= now) {
        if (record) context.db.deleteAuthCode(phone);
        throw new HttpError(401, 'invalid_code', 'Invalid or expired code');
      }

      if (Number(record.attempts) >= CODE_MAX_ATTEMPTS) {
        throw new HttpError(429, 'too_many_attempts', 'Too many attempts', {
          retryAfter: retryAfterUntil(Number(record.expires_at), now),
        });
      }

      const submittedCode =
        typeof body.code === 'string' && /^\d{6}$/.test(body.code)
          ? body.code
          : null;
      const submittedHash = submittedCode
        ? hashAuthCode(phone, submittedCode, context.config.authPepper)
        : '';
      if (!submittedHash || !constantTimeEqualHex(record.code_hash, submittedHash)) {
        context.db.incrementAuthCodeAttempts(phone);
        // All five permitted attempts get the same generic response. The next
        // attempt is rejected before the hash comparison with a 429.
        throw new HttpError(401, 'invalid_code', 'Invalid or expired code');
      }

      let requestedName;
      if (body.name !== undefined) {
        requestedName = normalizeName(body.name);
        if (requestedName === null) {
          throw new HttpError(
            400,
            'invalid_name',
            'Name must be between 1 and 64 characters',
          );
        }
      }

      let requestedAbout;
      if (body.about !== undefined) {
        requestedAbout = normalizeAbout(body.about);
        if (requestedAbout === null) {
          throw new HttpError(
            400,
            'invalid_about',
            'About must be at most 280 characters',
          );
        }
      }

      let user;
      let isNew = false;
      context.db.transaction(() => {
        user = context.db.getUserByPhone(phone);
        if (!user) {
          isNew = true;
          const createdAt = Date.now();
          user = context.db.createUser({
            id: randomUUID(),
            phone,
            name: requestedName === undefined ? DEFAULT_NAME : requestedName,
            about: requestedAbout === undefined ? '' : requestedAbout,
            avatarColor: '#1A9C7A',
            createdAt,
            lastSeen: createdAt,
          });
        } else if (requestedName !== undefined || requestedAbout !== undefined) {
          user = context.db.updateUserProfile(user.id, {
            name: requestedName === undefined ? null : requestedName,
            about: requestedAbout === undefined ? null : requestedAbout,
          });
        }
        context.db.deleteAuthCode(phone);
      });

      const token = signJwt(user, context.config.jwtSecret);
      sendJson(context.res, 200, {
        token,
        user: toPrivateUser(user, context.hub),
        isNew,
      });
    },
    { rateLimit: 'verify' },
  );
}

module.exports = {
  DEFAULT_NAME,
  registerAuthRoutes,
};
