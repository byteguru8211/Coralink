'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { WebSocket } = require('ws');
const { createApp } = require('../src/index');

const TEST_JWT_SECRET =
  'test-only-jwt-secret-with-more-than-thirty-two-characters';
const TEST_AUTH_PEPPER =
  'test-only-auth-pepper-with-more-than-thirty-two-characters';

class TestWsClient {
  constructor(socket) {
    this.socket = socket;
    this.events = [];
    this.waiters = [];
    this.closed = false;
    this.closePromise = new Promise((resolve) => {
      socket.once('close', () => {
        this.closed = true;
        resolve();
      });
    });
    socket.on('message', (data, isBinary) => {
      if (isBinary) return;
      let event;
      try {
        event = JSON.parse(data.toString('utf8'));
      } catch {
        event = { type: '_invalid_json', raw: data.toString('utf8') };
      }
      const waiterIndex = this.waiters.findIndex((waiter) =>
        waiter.predicate(event),
      );
      if (waiterIndex >= 0) {
        const [waiter] = this.waiters.splice(waiterIndex, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(event);
      } else {
        this.events.push(event);
      }
    });
  }

  waitFor(typeOrPredicate, timeoutMs = 3000) {
    const predicate =
      typeof typeOrPredicate === 'function'
        ? typeOrPredicate
        : (event) => event.type === typeOrPredicate;
    const existingIndex = this.events.findIndex(predicate);
    if (existingIndex >= 0) {
      return Promise.resolve(this.events.splice(existingIndex, 1)[0]);
    }
    if (this.closed) {
      return Promise.reject(new Error('WebSocket is closed'));
    }
    return new Promise((resolve, reject) => {
      const waiter = {
        predicate,
        resolve,
        reject,
        timer: null,
      };
      waiter.timer = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(
          new Error(
            `Timed out waiting for WS event; received: ${this.events
              .map((event) => event.type)
              .join(', ') || '(none)'}`,
          ),
        );
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  send(event) {
    if (this.closed) throw new Error('WebSocket is closed');
    this.socket.send(JSON.stringify(event));
  }

  async close() {
    if (this.closed) return;
    this.socket.close(1000, 'test done');
    const timeout = setTimeout(() => {
      if (!this.closed) this.socket.terminate();
    }, 1000);
    await this.closePromise;
    clearTimeout(timeout);
  }

  terminate() {
    if (!this.closed) this.socket.terminate();
  }
}

async function startTestApp(overrides = {}) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'coralink-test-'));
  const env = {
    NODE_ENV: 'test',
    DEV_MODE: 'true',
    JWT_SECRET: TEST_JWT_SECRET,
    AUTH_PEPPER: TEST_AUTH_PEPPER,
    DB_PATH: path.join(tempDir, 'test.db'),
    LOG_LEVEL: 'silent',
    ALLOWED_ORIGINS: '*',
    MESSAGE_TTL_DAYS: '30',
    WS_MAX_CONNECTIONS: '3',
    ...overrides,
  };

  const app = createApp({ env });
  const { port } = await app.start(0, '127.0.0.1');
  const baseUrl = `http://127.0.0.1:${port}`;
  const wsBaseUrl = `ws://127.0.0.1:${port}/ws`;
  const clients = new Set();
  let closed = false;

  async function api(pathname, options = {}) {
    const headers = { ...(options.headers || {}) };
    if (options.token) headers.Authorization = `Bearer ${options.token}`;
    let body;
    if (options.body !== undefined) {
      headers['Content-Type'] = 'application/json';
      body = JSON.stringify(options.body);
    }
    const response = await fetch(`${baseUrl}${pathname}`, {
      method: options.method || 'GET',
      headers,
      body,
    });
    const text = await response.text();
    let parsed = null;
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        parsed = null;
      }
    }
    return {
      status: response.status,
      headers: response.headers,
      body: parsed,
      text,
    };
  }

  async function login(phone, name = 'Test User') {
    const codeResponse = await api('/api/v1/auth/request-code', {
      method: 'POST',
      body: { phone },
    });
    if (codeResponse.status !== 200 || !codeResponse.body?.devCode) {
      throw new Error(
        `Could not request test code (${codeResponse.status}): ${codeResponse.text}`,
      );
    }
    const verifyResponse = await api('/api/v1/auth/verify', {
      method: 'POST',
      body: {
        phone,
        code: codeResponse.body.devCode,
        name,
      },
    });
    if (verifyResponse.status !== 200) {
      throw new Error(
        `Could not verify test user (${verifyResponse.status}): ${verifyResponse.text}`,
      );
    }
    return {
      token: verifyResponse.body.token,
      user: verifyResponse.body.user,
      isNew: verifyResponse.body.isNew,
      code: codeResponse.body.devCode,
      phone,
    };
  }

  async function openWs(token) {
    if (closed) throw new Error('Test app is closed');
    const socket = new WebSocket(
      `${wsBaseUrl}?token=${encodeURIComponent(token)}`,
      { handshakeTimeout: 3000 },
    );
    const client = new TestWsClient(socket);
    clients.add(client);
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        socket.terminate();
        reject(new Error('Timed out opening WebSocket'));
      }, 3000);
      socket.once('open', () => {
        clearTimeout(timeout);
        resolve();
      });
      socket.once('error', (error) => {
        clearTimeout(timeout);
        reject(error);
      });
    });
    return client;
  }

  async function close() {
    if (closed) return;
    closed = true;
    for (const client of clients) client.terminate();
    clients.clear();
    try {
      await app.stop();
    } finally {
      fs.rmSync(tempDir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  }

  return {
    app,
    baseUrl,
    wsBaseUrl,
    api,
    login,
    openWs,
    close,
    tempDir,
  };
}

function randomUuid() {
  return require('node:crypto').randomUUID();
}

function base64(value) {
  return Buffer.from(value).toString('base64');
}

module.exports = {
  TEST_AUTH_PEPPER,
  TEST_JWT_SECRET,
  TestWsClient,
  base64,
  randomUuid,
  startTestApp,
};
