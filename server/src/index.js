'use strict';

const http = require('node:http');
const { loadConfig } = require('./config');
const { createDatabase } = require('./db');
const { createHttpHandler, Router, sendJson } = require('./lib/http');
const { createLogger } = require('./lib/log');
const { registerAuthRoutes } = require('./routes/auth');
const { registerBackupRoutes } = require('./routes/backup');
const { registerGroupRoutes } = require('./routes/groups');
const { registerKeyRoutes } = require('./routes/keys');
const { registerMessageRoutes } = require('./routes/messages');
const { registerPushRoutes } = require('./routes/push');
const { registerPetRoutes } = require('./routes/pets');
const { PetStore } = require('./pet_store');
const { registerUserRoutes } = require('./routes/users');
const { createHub } = require('./ws/hub');

function createApp(options = {}) {
  const config = options.config || loadConfig(options.env || process.env);
  const logger =
    options.logger ||
    createLogger({
      level: config.logLevel,
      base: { service: 'coralink-server' },
    });
  const db = createDatabase(config.dbPath);
  const hub = createHub({ db, config, logger });
  const petStore = new PetStore(db);

  const router = new Router();
  registerAuthRoutes(router);
  registerUserRoutes(router);
  registerGroupRoutes(router);
  registerKeyRoutes(router);
  registerBackupRoutes(router);
  registerMessageRoutes(router);
  registerPushRoutes(router);
  registerPetRoutes(router);

  router.add('GET', '/health', async (context) => {
    sendJson(context.res, 200, {
      ok: true,
      version: config.version,
    });
  });

  const handler = createHttpHandler({
    router,
    config,
    db,
    hub,
    petStore,
    logger,
  });
  const server = http.createServer(handler);
  server.headersTimeout = 30_000;
  server.requestTimeout = 60_000;
  server.keepAliveTimeout = 5_000;

  server.on('clientError', (error, socket) => {
    if (!socket.writable) return;
    const body = JSON.stringify({
      error: { code: 'bad_request', message: 'Bad request' },
    });
    socket.end(
      `HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`,
    );
  });

  hub.attach(server);

  let started = false;
  let stopping = null;

  async function start(port = config.port, host = config.host) {
    if (started) throw new Error('Server is already started');
    await new Promise((resolve, reject) => {
      const onError = (error) => {
        server.removeListener('listening', onListening);
        reject(error);
      };
      const onListening = () => {
        server.removeListener('error', onError);
        resolve();
      };
      server.once('error', onError);
      server.once('listening', onListening);
      server.listen(port, host);
    });
    started = true;
    const address = server.address();
    const actualPort =
      address && typeof address === 'object' ? address.port : port;
    logger.info('server_started', {
      host,
      port: actualPort,
      nodeEnv: config.nodeEnv,
      devMode: config.devMode,
    });
    return { host, port: actualPort };
  }

  async function stop() {
    if (stopping) return stopping;
    stopping = (async () => {
      await hub.close();
      if (started) {
        await new Promise((resolve) => {
          server.close(() => resolve());
          if (typeof server.closeAllConnections === 'function') {
            server.closeAllConnections();
          }
        });
        started = false;
      }
      try {
        db.close();
      } finally {
        logger.info('server_stopped');
      }
    })();
    return stopping;
  }

  return {
    config,
    db,
    hub,
    petStore,
    logger,
    router,
    server,
    start,
    stop,
  };
}

async function main() {
  let app;
  try {
    app = createApp();
    await app.start();
  } catch (error) {
    const logger = app?.logger || createLogger();
    logger.error('server_start_failed', { error });
    if (app) await app.stop();
    process.exitCode = 1;
    return;
  }

  let shuttingDown = false;
  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    app.logger.info('server_shutdown_requested', { signal });
    try {
      await app.stop();
      process.exit(0);
    } catch (error) {
      app.logger.error('server_shutdown_failed', { error });
      process.exit(1);
    }
  }

  process.once('SIGINT', () => {
    void shutdown('SIGINT');
  });
  process.once('SIGTERM', () => {
    void shutdown('SIGTERM');
  });
}

if (require.main === module) {
  void main();
}

module.exports = {
  createApp,
  main,
};
