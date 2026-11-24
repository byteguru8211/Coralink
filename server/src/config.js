'use strict';

const path = require('node:path');

const VERSION = '1.1.0';

// Development-only defaults. Both are intentionally long enough for HS256 but
// must never be used in production.
const DEV_JWT_SECRET =
  'coralink-local-development-jwt-secret-do-not-use-in-production';
const DEV_AUTH_PEPPER =
  'coralink-local-development-auth-pepper-do-not-use-in-production';

function parseBoolean(value, fallback) {
  if (value === undefined || value === null || value === '') return fallback;
  const normalized = String(value).trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  return fallback;
}

function parseInteger(value, name, { min, max, defaultValue }) {
  if (value === undefined || value === null || value === '') {
    return defaultValue;
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}`);
  }
  return parsed;
}

function parseOrigins(value, defaultValue) {
  if (value === undefined || value === null) return defaultValue;
  const origins = String(value)
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);
  return origins;
}

/**
 * Reads and validates configuration. In production, JWT_SECRET and
 * AUTH_PEPPER are mandatory and must each be at least 32 characters.
 */
function loadConfig(env = process.env) {
  const nodeEnv = String(env.NODE_ENV || 'development').toLowerCase();
  const isProduction = nodeEnv === 'production';
  const devMode = !isProduction && parseBoolean(env.DEV_MODE, true);

  const jwtSecret = env.JWT_SECRET || (devMode ? DEV_JWT_SECRET : '');
  const authPepper = env.AUTH_PEPPER || (devMode ? DEV_AUTH_PEPPER : '');

  if (isProduction) {
    if (!jwtSecret || jwtSecret.length < 32) {
      throw new Error(
        'JWT_SECRET must be configured with at least 32 characters in production',
      );
    }
    if (!authPepper || authPepper.length < 32) {
      throw new Error(
        'AUTH_PEPPER must be configured with at least 32 characters in production',
      );
    }
  } else if (!devMode) {
    if (!jwtSecret || jwtSecret.length < 32) {
      throw new Error(
        'JWT_SECRET must be configured with at least 32 characters when DEV_MODE is false',
      );
    }
    if (!authPepper || authPepper.length < 32) {
      throw new Error(
        'AUTH_PEPPER must be configured with at least 32 characters when DEV_MODE is false',
      );
    }
  }

  const port = parseInteger(env.PORT, 'PORT', {
    min: 0,
    max: 65535,
    defaultValue: 8080,
  });
  const messageTtlDays = parseInteger(env.MESSAGE_TTL_DAYS, 'MESSAGE_TTL_DAYS', {
    min: 1,
    max: 365,
    defaultValue: 30,
  });
  const wsMaxConnections = parseInteger(
    env.WS_MAX_CONNECTIONS,
    'WS_MAX_CONNECTIONS',
    { min: 1, max: 100, defaultValue: 3 },
  );

  const configuredDbPath =
    env.DB_PATH || path.join(process.cwd(), 'data', 'coralink.db');
  const dbPath =
    configuredDbPath === ':memory:'
      ? ':memory:'
      : path.resolve(configuredDbPath);
  const defaultOrigins = devMode ? ['*'] : [];
  const allowedOrigins = parseOrigins(env.ALLOWED_ORIGINS, defaultOrigins);

  const logLevel = String(env.LOG_LEVEL || 'info').toLowerCase();
  if (!['debug', 'info', 'warn', 'error', 'silent'].includes(logLevel)) {
    throw new Error('LOG_LEVEL must be one of debug, info, warn, error, silent');
  }

  return Object.freeze({
    version: VERSION,
    nodeEnv,
    isProduction,
    devMode,
    jwtSecret,
    authPepper,
    port,
    host: env.HOST || '0.0.0.0',
    dbPath,
    allowedOrigins,
    corsWildcard: allowedOrigins.includes('*'),
    messageTtlMs: messageTtlDays * 24 * 60 * 60 * 1000,
    wsMaxConnections,
    logLevel,
  });
}

module.exports = {
  VERSION,
  loadConfig,
};
