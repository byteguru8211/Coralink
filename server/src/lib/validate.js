'use strict';

const PHONE_MIN_DIGITS = 10;
const PHONE_MAX_DIGITS = 15;
const MAX_NAME_LENGTH = 64;
const MAX_ABOUT_LENGTH = 280;
const USERNAME_MIN_LENGTH = 3;
const USERNAME_MAX_LENGTH = 32;
const PASSWORD_MIN_LENGTH = 6;
const PASSWORD_MAX_LENGTH = 256;
const MAX_AVATAR_BYTES = 500 * 1024;

/**
 * Validates a login password. Returns the password unchanged when it meets the
 * length policy, or null when invalid. Whitespace is preserved (not trimmed) so
 * a password is exactly what the user typed.
 */
function normalizePassword(input) {
  if (typeof input !== 'string') return null;
  if (input.length < PASSWORD_MIN_LENGTH || input.length > PASSWORD_MAX_LENGTH) {
    return null;
  }
  return input;
}

/**
 * Normalizes a profile photo supplied as a base64 data URL. Returns '' to clear
 * the avatar, the trimmed data URL when valid, or null when malformed/too large.
 */
function normalizeAvatar(input) {
  if (input === null || input === undefined) return '';
  if (typeof input !== 'string') return null;
  const value = input.trim();
  if (value === '') return '';
  if (!/^data:image\/(png|jpe?g|webp);base64,[A-Za-z0-9+/=]+$/.test(value)) {
    return null;
  }
  if (value.length > MAX_AVATAR_BYTES) return null;
  return value;
}

/**
 * Normalizes a nickname/handle used for open (code-free) registration.
 * Accepts lowercase latin letters, digits, dot and underscore. Returns null
 * when the input cannot form a valid handle.
 */
function normalizeUsername(input) {
  if (typeof input !== 'string') return null;
  const value = input.trim().toLowerCase();
  if (
    value.length < USERNAME_MIN_LENGTH ||
    value.length > USERNAME_MAX_LENGTH
  ) {
    return null;
  }
  if (!/^[a-z0-9._]+$/.test(value)) return null;
  if (!/^[a-z0-9]/.test(value) || !/[a-z0-9]$/.test(value)) return null;
  return value;
}

/**
 * Normalizes a user-supplied phone number to a string of 10-15 digits.
 * A leading "+" and common formatting characters are accepted but discarded
 * so that "+1 (555) 010-2000" and "15550102000" identify the same account.
 */
function normalizePhone(input) {
  if (typeof input !== 'string') return null;
  const raw = input.trim();
  if (!raw || raw.length > 40) return null;
  if (!/^\+?[0-9\s().-]+$/.test(raw)) return null;
  const digits = raw.replace(/\D/g, '');
  if (
    digits.length < PHONE_MIN_DIGITS ||
    digits.length > PHONE_MAX_DIGITS
  ) {
    return null;
  }
  return digits;
}

function normalizeName(input) {
  if (typeof input !== 'string') return null;
  const value = input.trim();
  if (value.length < 1 || value.length > MAX_NAME_LENGTH) return null;
  return value;
}

function normalizeAbout(input) {
  if (typeof input !== 'string') return null;
  const value = input.trim();
  const length = Array.from(value).length;
  if (length > MAX_ABOUT_LENGTH) return null;
  return value;
}

function isValidAvatarColor(input) {
  return typeof input === 'string' && /^#[0-9A-Fa-f]{6}$/.test(input);
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function isUuidLike(value) {
  return (
    typeof value === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      value,
    )
  );
}

function isBase64String(value, maxBytes = 16 * 1024) {
  if (typeof value !== 'string' || value.length === 0) return false;
  const maxEncodedLength = Math.ceil((maxBytes * 4) / 3) + 4;
  if (value.length > maxEncodedLength) return false;
  if (/\s/.test(value)) return false;
  if (!/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) return false;

  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const withoutPadding = normalized.replace(/=+$/, '');
  if (withoutPadding.length % 4 === 1) return false;

  try {
    const decoded = Buffer.from(normalized, 'base64');
    if (decoded.length === 0 || decoded.length > maxBytes) return false;
    const canonical = decoded.toString('base64').replace(/=+$/, '');
    return canonical === withoutPadding;
  } catch {
    return false;
  }
}

function decodeBase64Length(value) {
  try {
    return Buffer.from(
      value.replace(/-/g, '+').replace(/_/g, '/'),
      'base64',
    ).length;
  } catch {
    return 0;
  }
}

function isSafeTokenString(value, min = 1, max = 4096) {
  if (typeof value !== 'string') return false;
  if (value.length < min || value.length > max) return false;
  return !/[\u0000-\u001f\u007f]/.test(value);
}

function isKind(value) {
  return typeof value === 'string' && /^[A-Za-z0-9._-]{1,32}$/.test(value);
}

function isPlatform(value) {
  return (
    typeof value === 'string' && /^[A-Za-z][A-Za-z0-9._-]{0,31}$/.test(value)
  );
}

function toSafeInteger(value, min, max) {
  if (!Number.isSafeInteger(value)) return null;
  if (value < min || value > max) return null;
  return value;
}

function escapeLike(value) {
  return String(value).replace(/[!%_]/g, (character) => `!${character}`);
}

function isNonEmptyString(value, max = 128) {
  return (
    typeof value === 'string' &&
    value.trim().length > 0 &&
    value.length <= max
  );
}

module.exports = {
  MAX_ABOUT_LENGTH,
  MAX_NAME_LENGTH,
  MAX_AVATAR_BYTES,
  USERNAME_MAX_LENGTH,
  USERNAME_MIN_LENGTH,
  decodeBase64Length,
  escapeLike,
  isBase64String,
  isKind,
  isNonEmptyString,
  isPlainObject,
  isPlatform,
  isSafeTokenString,
  isUuidLike,
  isValidAvatarColor,
  normalizeAbout,
  normalizeAvatar,
  normalizeName,
  normalizePassword,
  normalizePhone,
  normalizeUsername,
  toSafeInteger,
};
