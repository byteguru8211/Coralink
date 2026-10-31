'use strict';

const LEVELS = Object.freeze({
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
  silent: 100,
});

const REDACTED_KEYS = new Set([
  'authorization',
  'cookie',
  'password',
  'secret',
  'jwt',
  'jwtsecret',
  'authpepper',
  'token',
  'accesstoken',
  'refreshtoken',
  'pushtoken',
  'code',
  'authcode',
]);

function redact(value, key = '', seen = new WeakSet(), depth = 0) {
  const normalizedKey = String(key).toLowerCase();
  // A development verification code is deliberately logged only by the
  // dev-mode request-code path. All other code/token fields are redacted.
  if (REDACTED_KEYS.has(normalizedKey) && normalizedKey !== 'devcode') {
    return '[REDACTED]';
  }
  if (depth > 6) return '[Truncated]';
  if (value === null || value === undefined) return value;
  if (typeof value === 'string') {
    return value.length > 2048 ? `${value.slice(0, 2048)}...` : value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (typeof value === 'bigint') return value.toString();
  if (value instanceof Error) {
    return {
      name: value.name,
      message: value.message,
      stack: value.stack,
    };
  }
  if (Array.isArray(value)) {
    return value.slice(0, 50).map((item) => redact(item, '', seen, depth + 1));
  }
  if (typeof value === 'object') {
    if (seen.has(value)) return '[Circular]';
    seen.add(value);
    const output = {};
    for (const [entryKey, entryValue] of Object.entries(value)) {
      output[entryKey] = redact(entryValue, entryKey, seen, depth + 1);
    }
    return output;
  }
  return String(value);
}

function maskPhone(phone) {
  if (typeof phone !== 'string') return undefined;
  if (phone.length <= 6) return '*'.repeat(phone.length);
  return `${phone.slice(0, 3)}${'*'.repeat(
    Math.max(0, phone.length - 7),
  )}${phone.slice(-4)}`;
}

function serializeError(error) {
  if (!(error instanceof Error)) return redact(error);
  return {
    name: error.name,
    message: error.message,
    stack: error.stack,
  };
}

function createLogger({ level = 'info', base = {} } = {}) {
  const threshold = LEVELS[level] ?? LEVELS.info;

  function emit(entryLevel, message, fields = {}) {
    if (LEVELS[entryLevel] < threshold) return;
    const record = {
      ts: new Date().toISOString(),
      level: entryLevel,
      msg: String(message),
      ...redact(base),
      ...redact(fields || {}),
    };
    let line;
    try {
      line = JSON.stringify(record);
    } catch {
      line = JSON.stringify({
        ts: record.ts,
        level: entryLevel,
        msg: String(message),
        logError: 'serialization_failed',
      });
    }
    if (entryLevel === 'error') {
      console.error(line);
    } else {
      console.log(line);
    }
  }

  return {
    level,
    debug: (message, fields) => emit('debug', message, fields),
    info: (message, fields) => emit('info', message, fields),
    warn: (message, fields) => emit('warn', message, fields),
    error: (message, fields) => emit('error', message, fields),
    child(extra = {}) {
      return createLogger({ level, base: { ...base, ...extra } });
    },
  };
}

module.exports = {
  createLogger,
  maskPhone,
  redact,
  serializeError,
};
