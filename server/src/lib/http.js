'use strict';

const { performance } = require('node:perf_hooks');
const { createLogger } = require('./log');

const MAX_BODY_BYTES = 1024 * 1024;
const API_PREFIX = '/api/v1';

const RATE_LIMITS = Object.freeze({
  global: { limit: 300, windowMs: 60 * 1000 },
  requestCode: { limit: 5, windowMs: 60 * 60 * 1000 },
  verify: { limit: 10, windowMs: 15 * 60 * 1000 },
});

class HttpError extends Error {
  constructor(status, code, message, options = {}) {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
    this.retryAfter = options.retryAfter;
    this.headers = options.headers || null;
  }
}

class Router {
  constructor() {
    this.routes = [];
  }

  add(method, pattern, handler, options = {}) {
    this.routes.push({
      method: method.toUpperCase(),
      pattern,
      handler,
      options,
    });
    return this;
  }

  match(method, pathname) {
    const requestSegments = splitPath(pathname);
    for (const route of this.routes) {
      if (route.method !== method) continue;
      const patternSegments = splitPath(route.pattern);
      if (patternSegments.length !== requestSegments.length) continue;
      const params = {};
      let matched = true;
      for (let index = 0; index < patternSegments.length; index += 1) {
        const patternSegment = patternSegments[index];
        const requestSegment = requestSegments[index];
        if (patternSegment.startsWith(':')) {
          try {
            params[patternSegment.slice(1)] = decodeURIComponent(requestSegment);
          } catch {
            matched = false;
            break;
          }
        } else if (patternSegment !== requestSegment) {
          matched = false;
          break;
        }
      }
      if (matched) return { route, params };
    }
    return null;
  }
}

function splitPath(pathname) {
  return String(pathname).split('/').filter(Boolean);
}

function setSecurityHeaders(res) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
}

function resolveCorsOrigin(config, origin) {
  if (!origin) return null;
  if (config.corsWildcard) return '*';
  if (config.allowedOrigins.includes(origin)) return origin;
  return null;
}

function applyCors(req, res, config) {
  const origin = req.headers.origin;
  const allowedOrigin = resolveCorsOrigin(config, origin);
  if (allowedOrigin) {
    res.setHeader('Access-Control-Allow-Origin', allowedOrigin);
    if (!config.corsWildcard) {
      res.setHeader('Vary', 'Origin');
    }
  }
  return allowedOrigin;
}

function sendJson(res, status, payload, extraHeaders = {}) {
  if (res.writableEnded || res.destroyed) return;
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Content-Length', String(body.length));
  for (const [key, value] of Object.entries(extraHeaders)) {
    if (value !== undefined && value !== null) res.setHeader(key, String(value));
  }
  res.end(body);
}

function sendError(res, error) {
  const status = error instanceof HttpError ? error.status : 500;
  const code = error instanceof HttpError ? error.code : 'internal_error';
  const message =
    error instanceof HttpError ? error.message : 'Internal server error';
  const headers = error instanceof HttpError ? error.headers : null;
  const extraHeaders = { ...(headers || {}) };
  if (error instanceof HttpError && error.retryAfter !== undefined) {
    extraHeaders['Retry-After'] = String(error.retryAfter);
  }
  sendJson(res, status, { error: { code, message } }, extraHeaders);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const declaredLength = Number(req.headers['content-length']);
    if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
      req.resume();
      reject(
        new HttpError(413, 'payload_too_large', 'Request body is too large'),
      );
      return;
    }

    let total = 0;
    let settled = false;
    const chunks = [];

    function fail(error) {
      if (settled) return;
      settled = true;
      req.removeListener('data', onData);
      req.removeListener('end', onEnd);
      req.removeListener('error', fail);
      reject(error);
    }

    function onData(chunk) {
      if (settled) return;
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        req.resume();
        fail(
          new HttpError(413, 'payload_too_large', 'Request body is too large'),
        );
        return;
      }
      chunks.push(chunk);
    }

    function onEnd() {
      if (settled) return;
      settled = true;
      req.removeListener('data', onData);
      req.removeListener('error', fail);
      const raw = Buffer.concat(chunks).toString('utf8');
      if (raw.trim() === '') {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new HttpError(400, 'invalid_json', 'Invalid JSON body'));
      }
    }

    req.on('data', onData);
    req.on('end', onEnd);
    req.on('error', (error) => {
      fail(
        error instanceof HttpError
          ? error
          : new HttpError(400, 'invalid_request', 'Could not read request body'),
      );
    });
    req.on('aborted', () => fail(new HttpError(400, 'invalid_request', 'Request aborted')));
  });
}

class RateLimiter {
  constructor() {
    this.buckets = new Map();
    this.checks = 0;
  }

  consume(scope, key, { limit, windowMs }, now = Date.now()) {
    const bucketKey = `${scope}:${key}`;
    let bucket = this.buckets.get(bucketKey);
    if (!bucket || bucket.resetAt <= now) {
      bucket = { count: 0, resetAt: now + windowMs };
      this.buckets.set(bucketKey, bucket);
    }
    bucket.count += 1;
    this.checks += 1;
    if (this.checks % 1000 === 0) this.cleanup(now);
    return {
      allowed: bucket.count <= limit,
      remaining: Math.max(0, limit - bucket.count),
      retryAfter: Math.max(1, Math.ceil((bucket.resetAt - now) / 1000)),
      resetAt: bucket.resetAt,
    };
  }

  cleanup(now = Date.now()) {
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAt <= now) this.buckets.delete(key);
    }
  }
}

function getClientIp(req) {
  return req.socket?.remoteAddress || 'unknown';
}

function rateLimitRequest(limiter, scope, key, settings) {
  const result = limiter.consume(scope, key, settings);
  if (!result.allowed) {
    throw new HttpError(429, 'rate_limited', 'Too many requests', {
      retryAfter: result.retryAfter,
    });
  }
}

function createHttpHandler({
  router,
  config,
  db,
  hub,
  petStore,
  logger = createLogger({ level: config.logLevel }),
}) {
  const limiter = new RateLimiter();

  return async function httpHandler(req, res) {
    const startedAt = performance.now();
    setSecurityHeaders(res);

    let url;
    try {
      url = new URL(req.url || '/', 'http://localhost');
    } catch {
      sendError(res, new HttpError(400, 'invalid_request', 'Invalid URL'));
      return;
    }

    const pathname = url.pathname;
    const method = String(req.method || 'GET').toUpperCase();
    if (pathname.startsWith('/api/')) {
      res.setHeader('Cache-Control', 'no-store');
    }
    applyCors(req, res, config);

    res.on('finish', () => {
      logger.info('http_request', {
        method,
        path: pathname,
        status: res.statusCode,
        durationMs: Math.round(performance.now() - startedAt),
        ip: getClientIp(req),
      });
    });

    if (method === 'OPTIONS') {
      res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,DELETE,OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
      res.setHeader('Access-Control-Max-Age', '600');
      res.statusCode = 204;
      res.setHeader('Content-Length', '0');
      res.end();
      return;
    }

    const ip = getClientIp(req);

    try {
      if (pathname.startsWith(`${API_PREFIX}/`)) {
        rateLimitRequest(limiter, 'global', ip, RATE_LIMITS.global);
      }

      const matched = router.match(method, pathname);
      if (!matched) {
        throw new HttpError(404, 'not_found', 'Route not found');
      }

      if (matched.route.options.rateLimit === 'requestCode') {
        rateLimitRequest(
          limiter,
          'request-code',
          ip,
          RATE_LIMITS.requestCode,
        );
      } else if (matched.route.options.rateLimit === 'verify') {
        rateLimitRequest(limiter, 'verify', ip, RATE_LIMITS.verify);
      }

      let body = {};
      if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) {
        body = await readJsonBody(req);
      }

      const context = {
        req,
        res,
        url,
        method,
        pathname,
        ip,
        params: matched.params,
        body,
        config,
        db,
        hub,
        petStore,
        logger,
      };

      await matched.route.handler(context);
    } catch (error) {
      if (res.writableEnded || res.destroyed) return;
      if (error instanceof HttpError) {
        sendError(res, error);
        return;
      }
      logger.error('http_internal_error', {
        method,
        path: pathname,
        error,
      });
      sendError(res, new HttpError(500, 'internal_error', 'Internal server error'));
    }
  };
}

module.exports = {
  API_PREFIX,
  HttpError,
  MAX_BODY_BYTES,
  RATE_LIMITS,
  RateLimiter,
  Router,
  createHttpHandler,
  readJsonBody,
  sendError,
  sendJson,
};
