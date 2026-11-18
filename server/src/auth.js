'use strict';

const {
  createHmac,
  randomInt,
  randomBytes,
  scryptSync,
  timingSafeEqual,
} = require('node:crypto');
const { HttpError } = require('./lib/http');

const CODE_TTL_MS = 5 * 60 * 1000;
const CODE_RESEND_MS = 60 * 1000;
const CODE_MAX_ATTEMPTS = 5;
const JWT_TTL_SECONDS = 30 * 24 * 60 * 60;

// scrypt parameters for password hashing (memory-hard, per-password salt).
const SCRYPT_N = 16384;
const SCRYPT_R = 8;
const SCRYPT_P = 1;
const SCRYPT_KEYLEN = 32;
const SCRYPT_MAXMEM = 64 * 1024 * 1024;

function hashPassword(password) {
  const salt = randomBytes(16);
  const derived = scryptSync(password, salt, SCRYPT_KEYLEN, {
    N: SCRYPT_N,
    r: SCRYPT_R,
    p: SCRYPT_P,
    maxmem: SCRYPT_MAXMEM,
  });
  return [
    'scrypt',
    SCRYPT_N,
    SCRYPT_R,
    SCRYPT_P,
    salt.toString('base64'),
    derived.toString('base64'),
  ].join('$');
}

function verifyPassword(password, stored) {
  if (typeof stored !== 'string') return false;
  const parts = stored.split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const [, nStr, rStr, pStr, saltB64, hashB64] = parts;
  try {
    const salt = Buffer.from(saltB64, 'base64');
    const expected = Buffer.from(hashB64, 'base64');
    const derived = scryptSync(password, salt, expected.length, {
      N: Number(nStr),
      r: Number(rStr),
      p: Number(pStr),
      maxmem: SCRYPT_MAXMEM,
    });
    return derived.length === expected.length && timingSafeEqual(derived, expected);
  } catch {
    return false;
  }
}

function generateAuthCode() {
  return String(randomInt(0, 1_000_000)).padStart(6, '0');
}

function hashAuthCode(phone, code, pepper) {
  return createHmac('sha256', `${pepper}:${phone}`)
    .update(String(code))
    .digest('hex');
}

function constantTimeEqualHex(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  if (!/^[0-9a-f]+$/i.test(left) || !/^[0-9a-f]+$/i.test(right)) return false;
  const leftBuffer = Buffer.from(left, 'hex');
  const rightBuffer = Buffer.from(right, 'hex');
  if (leftBuffer.length !== rightBuffer.length || leftBuffer.length === 0) {
    return false;
  }
  return timingSafeEqual(leftBuffer, rightBuffer);
}

function base64urlJson(value) {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
}

function signJwt(user, secret, nowMs = Date.now()) {
  const issuedAt = Math.floor(nowMs / 1000);
  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = {
    sub: user.id,
    phone: user.phone,
    iat: issuedAt,
    exp: issuedAt + JWT_TTL_SECONDS,
  };
  const unsigned = `${base64urlJson(header)}.${base64urlJson(payload)}`;
  const signature = createHmac('sha256', secret)
    .update(unsigned)
    .digest('base64url');
  return `${unsigned}.${signature}`;
}

function decodeJsonSegment(segment) {
  if (!/^[A-Za-z0-9_-]+$/.test(segment)) throw new Error('invalid segment');
  const decoded = Buffer.from(segment, 'base64url').toString('utf8');
  const value = JSON.parse(decoded);
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('invalid segment');
  }
  return value;
}

/**
 * Verifies an HS256 JWT and returns its payload, or null for any malformed,
 * tampered, or expired token.
 */
function verifyJwt(token, secret, nowMs = Date.now()) {
  try {
    if (typeof token !== 'string' || token.length === 0 || token.length > 8192) {
      return null;
    }
    const parts = token.split('.');
    if (parts.length !== 3) return null;

    const header = decodeJsonSegment(parts[0]);
    if (header.alg !== 'HS256') return null;

    const expectedSignature = createHmac('sha256', secret)
      .update(`${parts[0]}.${parts[1]}`)
      .digest();
    if (!/^[A-Za-z0-9_-]+$/.test(parts[2])) return null;
    const receivedSignature = Buffer.from(parts[2], 'base64url');
    if (
      receivedSignature.length !== expectedSignature.length ||
      !timingSafeEqual(receivedSignature, expectedSignature)
    ) {
      return null;
    }

    const payload = decodeJsonSegment(parts[1]);
    if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
      return null;
    }
    if (!Number.isFinite(payload.exp) || !Number.isFinite(payload.iat)) {
      return null;
    }
    const nowSeconds = Math.floor(nowMs / 1000);
    if (payload.exp <= nowSeconds) return null;
    if (payload.iat > nowSeconds + 60) return null;
    return payload;
  } catch {
    return null;
  }
}

function authenticateRequest(req, { db, config }) {
  const header = req.headers.authorization;
  if (typeof header !== 'string') {
    throw new HttpError(401, 'unauthorized', 'Authentication required');
  }
  const match = /^Bearer\s+([^\s]+)$/i.exec(header.trim());
  if (!match) {
    throw new HttpError(401, 'unauthorized', 'Authentication required');
  }
  const payload = verifyJwt(match[1], config.jwtSecret);
  if (!payload) {
    throw new HttpError(401, 'unauthorized', 'Authentication required');
  }
  const user = db.getUserById(payload.sub);
  if (!user) {
    throw new HttpError(401, 'unauthorized', 'Authentication required');
  }
  return user;
}

function requireAuth(context) {
  const user = authenticateRequest(context.req, context);
  context.user = user;
  return user;
}

module.exports = {
  CODE_MAX_ATTEMPTS,
  CODE_RESEND_MS,
  CODE_TTL_MS,
  JWT_TTL_SECONDS,
  authenticateRequest,
  constantTimeEqualHex,
  generateAuthCode,
  hashAuthCode,
  hashPassword,
  requireAuth,
  signJwt,
  verifyJwt,
  verifyPassword,
};
