'use strict';

const { WebSocket, WebSocketServer } = require('ws');
const { verifyJwt } = require('../auth');
const { ProtocolError, parseClientEvent } = require('./protocol');

const WS_PATH = '/ws';
const HEARTBEAT_INTERVAL_MS = 30 * 1000;
const MAX_WS_PAYLOAD = 1024 * 1024;

const STATUS_TEXT = {
  400: 'Bad Request',
  401: 'Unauthorized',
  404: 'Not Found',
  429: 'Too Many Requests',
};

function createHub({ db, config, logger }) {
  const wss = new WebSocketServer({
    noServer: true,
    clientTracking: true,
    maxPayload: MAX_WS_PAYLOAD,
    perMessageDeflate: false,
  });
  const clients = new Map();
  let heartbeatTimer = null;
  let attached = false;
  let shuttingDown = false;

  function send(ws, event) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return false;
    try {
      ws.send(JSON.stringify(event));
      return true;
    } catch (error) {
      logger.warn('ws_send_failed', { error });
      return false;
    }
  }

  function sendToUser(userId, event) {
    const sockets = clients.get(userId);
    if (!sockets) return 0;
    let sent = 0;
    for (const socket of Array.from(sockets)) {
      if (send(socket, event)) sent += 1;
    }
    return sent;
  }

  function effectiveStatus(userId) {
    const sockets = clients.get(userId);
    if (!sockets || sockets.size === 0) return null;
    let hasAway = false;
    for (const socket of sockets) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      if (socket.coralinkPresence === 'online') return 'online';
      if (socket.coralinkPresence === 'away') hasAway = true;
    }
    return hasAway ? 'away' : null;
  }

  function isOnline(userId) {
    return effectiveStatus(userId) !== null;
  }

  function broadcastPresence(userId, status, lastSeen) {
    const contactIds = db.getUserIdsHavingContact(userId);
    const event = {
      type: 'presence',
      userId,
      status,
      lastSeen,
    };
    for (const contactId of contactIds) {
      sendToUser(contactId, event);
    }
  }

  function rejectUpgrade(socket, status, code, message) {
    if (socket.destroyed) return;
    const body = JSON.stringify({ error: { code, message } });
    const response = [
      `HTTP/1.1 ${status} ${STATUS_TEXT[status] || 'Error'}`,
      'Connection: close',
      'Content-Type: application/json; charset=utf-8',
      `Content-Length: ${Buffer.byteLength(body, 'utf8')}`,
      '',
      body,
    ].join('\r\n');
    socket.write(response);
    socket.end();
  }

  function handleUpgrade(req, socket, head) {
    let url;
    try {
      url = new URL(req.url || '/', 'http://localhost');
    } catch {
      rejectUpgrade(socket, 400, 'invalid_request', 'Invalid request');
      return;
    }
    if (url.pathname !== WS_PATH) {
      rejectUpgrade(socket, 404, 'not_found', 'Route not found');
      return;
    }

    const token = url.searchParams.get('token');
    if (!token) {
      rejectUpgrade(socket, 401, 'unauthorized', 'Authentication required');
      return;
    }
    const payload = verifyJwt(token, config.jwtSecret);
    if (!payload) {
      rejectUpgrade(socket, 401, 'unauthorized', 'Authentication required');
      return;
    }
    const user = db.getUserById(payload.sub);
    if (!user) {
      rejectUpgrade(socket, 401, 'unauthorized', 'Authentication required');
      return;
    }

    const existing = clients.get(user.id);
    if (existing && existing.size >= config.wsMaxConnections) {
      rejectUpgrade(
        socket,
        429,
        'too_many_connections',
        'Too many active connections',
      );
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.coralinkUser = user;
      wss.emit('connection', ws, req);
    });
  }

  function handlePresenceUpdate(ws, status) {
    const user = ws.coralinkUser;
    const previous = effectiveStatus(user.id);
    ws.coralinkPresence = status;
    const now = Date.now();
    db.touchLastSeen(user.id, now);
    const next = effectiveStatus(user.id);
    if (next && next !== previous) {
      broadcastPresence(user.id, next, now);
    }
  }

  function handleIncomingMessage(ws, event) {
    if (ws.readyState !== WebSocket.OPEN) return;
    const sender = ws.coralinkUser;
    const recipient = db.getUserById(event.to);
    if (!recipient) {
      send(ws, {
        type: 'error',
        code: 'recipient_not_found',
        message: 'Recipient not found',
      });
      return;
    }

    const now = Date.now();
    const createdAt = event.createdAt === null ? now : event.createdAt;
    const result = db.insertMessage({
      id: event.id,
      senderId: sender.id,
      recipientId: recipient.id,
      ciphertext: event.ciphertext,
      kind: event.kind,
      meta: event.meta,
      createdAt,
      expiresAt: now + config.messageTtlMs,
    });

    if (!result.inserted) {
      if (
        !result.message ||
        result.message.senderId !== sender.id ||
        result.message.recipientId !== recipient.id
      ) {
        send(ws, {
          type: 'error',
          code: 'duplicate_id',
          message: 'Message id is already in use',
        });
        return;
      }
      send(ws, {
        type: 'message.ack',
        id: event.id,
        status: isOnline(recipient.id) ? 'delivered' : 'queued',
      });
      return;
    }

    const delivered =
      sendToUser(recipient.id, {
        type: 'message',
        message: {
          id: event.id,
          from: sender.id,
          ciphertext: event.ciphertext,
          kind: event.kind,
          meta: event.meta,
          createdAt,
        },
      }) > 0;

    send(ws, {
      type: 'message.ack',
      id: event.id,
      status: delivered ? 'delivered' : 'queued',
    });
  }

  function handleIncomingAck(ws, event) {
    const user = ws.coralinkUser;
    const result = db.ackMessages(user.id, event.ids, Date.now());
    for (const group of result.bySender) {
      sendToUser(group.senderId, {
        type: 'message.delivered',
        messageIds: group.messageIds,
        ids: group.messageIds,
      });
    }
    send(ws, {
      type: 'message.ack.ok',
      ids: event.ids,
    });
  }

  function handleRead(ws, event) {
    const user = ws.coralinkUser;
    const readIds = db.markMessagesRead(
      user.id,
      event.chatWith,
      event.ids,
      Date.now(),
    );
    if (readIds.length > 0) {
      sendToUser(event.chatWith, {
        type: 'message.read',
        messageIds: readIds,
        by: user.id,
      });
    }
  }

  function handleSignal(ws, event) {
    const user = ws.coralinkUser;
    const sent = isOnline(event.to)
      ? sendToUser(event.to, {
          type: 'signal',
          from: user.id,
          data: event.data,
        })
      : 0;
    if (sent === 0) {
      send(ws, {
        type: 'error',
        code: 'peer_offline',
        message: 'Peer is not connected',
      });
    }
  }

  function handleTyping(ws, event) {
    const user = ws.coralinkUser;
    if (!isOnline(event.to)) return;
    sendToUser(event.to, {
      type: 'typing',
      from: user.id,
      on: event.on,
    });
  }

  function handleEvent(ws, event) {
    switch (event.type) {
      case 'message':
        handleIncomingMessage(ws, event);
        break;
      case 'message.ack':
        handleIncomingAck(ws, event);
        break;
      case 'message.read':
        handleRead(ws, event);
        break;
      case 'signal':
        handleSignal(ws, event);
        break;
      case 'typing':
        handleTyping(ws, event);
        break;
      case 'presence':
        handlePresenceUpdate(
          ws,
          event.status === 'away' ? 'away' : 'online',
        );
        break;
      default:
        send(ws, {
          type: 'error',
          code: 'unknown_type',
          message: 'Unknown event type',
        });
    }
  }

  function handleRawMessage(ws, data, isBinary) {
    if (isBinary) {
      send(ws, {
        type: 'error',
        code: 'invalid_event',
        message: 'Binary events are not supported',
      });
      return;
    }
    let event;
    try {
      event = parseClientEvent(
        typeof data === 'string' ? data : data.toString('utf8'),
      );
    } catch (error) {
      if (error instanceof ProtocolError) {
        send(ws, {
          type: 'error',
          code: error.code,
          message: error.message,
        });
        return;
      }
      logger.warn('ws_parse_error', { error });
      send(ws, {
        type: 'error',
        code: 'invalid_event',
        message: 'Invalid event',
      });
      return;
    }

    try {
      handleEvent(ws, event);
    } catch (error) {
      logger.error('ws_event_error', {
        userId: ws.coralinkUser?.id,
        type: event.type,
        error,
      });
      send(ws, {
        type: 'error',
        code: 'internal_error',
        message: 'Internal server error',
      });
    }
  }

  function handleDisconnect(ws) {
    const user = ws.coralinkUser;
    if (!user) return;
    const sockets = clients.get(user.id);
    if (!sockets) return;
    const previous = effectiveStatus(user.id);
    sockets.delete(ws);
    if (sockets.size === 0) clients.delete(user.id);
    const next = effectiveStatus(user.id);
    const now = Date.now();

    if (!next) {
      db.touchLastSeen(user.id, now);
      broadcastPresence(user.id, 'offline', now);
    } else {
      db.touchLastSeen(user.id, now);
      if (next !== previous) {
        broadcastPresence(user.id, next, now);
      }
    }
  }

  wss.on('connection', (ws, req) => {
    const user = ws.coralinkUser;
    if (!user) {
      ws.close(1011, 'Internal error');
      return;
    }

    const previous = effectiveStatus(user.id);
    ws.coralinkPresence = 'online';
    ws.coralinkIsAlive = true;

    if (!clients.has(user.id)) clients.set(user.id, new Set());
    clients.get(user.id).add(ws);

    const now = Date.now();
    db.touchLastSeen(user.id, now);

    ws.on('pong', () => {
      ws.coralinkIsAlive = true;
    });
    ws.on('message', (data, isBinary) => {
      handleRawMessage(ws, data, isBinary);
    });
    ws.on('close', () => handleDisconnect(ws));
    ws.on('error', (error) => {
      logger.warn('ws_socket_error', {
        userId: user.id,
        error,
      });
    });

    send(ws, {
      type: 'ready',
      userId: user.id,
      serverTime: now,
    });

    if (previous !== 'online') {
      broadcastPresence(user.id, 'online', now);
    }
  });

  function attach(server) {
    if (attached) throw new Error('Hub is already attached');
    attached = true;
    server.on('upgrade', handleUpgrade);
    heartbeatTimer = setInterval(() => {
      for (const ws of wss.clients) {
        if (ws.coralinkIsAlive === false) {
          ws.terminate();
          continue;
        }
        ws.coralinkIsAlive = false;
        try {
          ws.ping();
        } catch {
          ws.terminate();
        }
      }
    }, HEARTBEAT_INTERVAL_MS);
    heartbeatTimer.unref();
  }

  function close() {
    if (shuttingDown) return Promise.resolve();
    shuttingDown = true;
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
    for (const sockets of clients.values()) {
      for (const socket of sockets) {
        try {
          socket.terminate();
        } catch {
          // Ignore sockets that already closed.
        }
      }
    }
    clients.clear();
    return new Promise((resolve) => {
      try {
        wss.close(() => resolve());
      } catch {
        resolve();
      }
    });
  }

  function disconnectUser(userId) {
    const sockets = clients.get(userId);
    if (!sockets) return;
    for (const socket of [...sockets]) {
      try {
        socket.close(4001, 'account_deleted');
      } catch {
        try {
          socket.terminate();
        } catch {
          // Already closed.
        }
      }
    }
    clients.delete(userId);
  }

  return {
    attach,
    close,
    disconnectUser,
    isOnline,
    sendTo: sendToUser,
    sendToUser,
  };
}

module.exports = {
  HEARTBEAT_INTERVAL_MS,
  WS_PATH,
  createHub,
};
