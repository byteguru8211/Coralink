'use strict';

const {
  isBase64String,
  isKind,
  isPlainObject,
  isUuidLike,
} = require('../lib/validate');

// Decoded ciphertext ceiling: ~9 MB allows an ~8 MB file attachment to travel
// through the relay. Image messages stay far below this.
const MAX_MESSAGE_BYTES = 9 * 1024 * 1024;
const MAX_BATCH = 500;
const MAX_META_BYTES = 16 * 1024;
const MAX_SDP_BYTES = 256 * 1024;
const MAX_CANDIDATE_BYTES = 16 * 1024;

class ProtocolError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ProtocolError';
    this.code = code;
  }
}

function fail(code, message) {
  throw new ProtocolError(code, message);
}

function requireUuid(value, field) {
  if (!isUuidLike(value)) {
    fail('invalid_event', `${field} must be a valid id`);
  }
  return value;
}

function validateIds(value, field = 'ids') {
  if (!Array.isArray(value) || value.length > MAX_BATCH) {
    fail('invalid_event', `${field} must be an array of at most ${MAX_BATCH} ids`);
  }
  for (const id of value) {
    requireUuid(id, field);
  }
  return value;
}

function validateMeta(value) {
  if (value === undefined) return {};
  if (!isPlainObject(value)) {
    fail('invalid_event', 'meta must be an object');
  }
  let serialized;
  try {
    serialized = JSON.stringify(value);
  } catch {
    fail('invalid_event', 'meta must be JSON serializable');
  }
  if (Buffer.byteLength(serialized, 'utf8') > MAX_META_BYTES) {
    fail('invalid_event', 'meta is too large');
  }
  return value;
}

function validateCreatedAt(value) {
  if (value === undefined || value === null) return null;
  if (!Number.isSafeInteger(value) || value <= 0) {
    fail('invalid_event', 'createdAt must be a positive epoch millisecond value');
  }
  return value;
}

function validateSignalData(value) {
  if (!isPlainObject(value)) {
    fail('invalid_event', 'data must be an object');
  }
  if (!['offer', 'answer', 'ice'].includes(value.kind)) {
    fail('invalid_event', 'data.kind must be offer, answer, or ice');
  }
  if (value.kind === 'offer' || value.kind === 'answer') {
    if (
      typeof value.sdp !== 'string' ||
      value.sdp.length === 0 ||
      Buffer.byteLength(value.sdp, 'utf8') > MAX_SDP_BYTES
    ) {
      fail('invalid_event', 'data.sdp is required for offers and answers');
    }
    return { kind: value.kind, sdp: value.sdp };
  }

  const withCandidateMetadata = (candidate) => {
    const result = { kind: 'ice', candidate };
    if (typeof value.sdpMid === 'string' && value.sdpMid.length <= 64) {
      result.sdpMid = value.sdpMid;
    }
    if (Number.isInteger(value.sdpMLineIndex)) {
      result.sdpMLineIndex = value.sdpMLineIndex;
    }
    return result;
  };

  if (value.candidate === undefined) return { kind: 'ice' };
  if (typeof value.candidate === 'string') {
    if (
      value.candidate.length === 0 ||
      Buffer.byteLength(value.candidate, 'utf8') > MAX_CANDIDATE_BYTES
    ) {
      fail('invalid_event', 'data.candidate is invalid');
    }
    return withCandidateMetadata(value.candidate);
  }
  if (isPlainObject(value.candidate)) {
    let serialized;
    try {
      serialized = JSON.stringify(value.candidate);
    } catch {
      fail('invalid_event', 'data.candidate is invalid');
    }
    if (Buffer.byteLength(serialized, 'utf8') > MAX_CANDIDATE_BYTES) {
      fail('invalid_event', 'data.candidate is too large');
    }
    return withCandidateMetadata(value.candidate);
  }
  fail('invalid_event', 'data.candidate must be a string or object');
  return null;
}

/**
 * Parses and strictly validates a client-originated WebSocket event.
 */
function parseClientEvent(raw) {
  if (typeof raw !== 'string') {
    fail('invalid_event', 'Text messages are required');
  }
  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    fail('invalid_json', 'Invalid JSON');
  }
  if (!isPlainObject(event)) {
    fail('invalid_event', 'Event must be an object');
  }
  if (typeof event.type !== 'string' || event.type.length === 0) {
    fail('invalid_event', 'Event type is required');
  }

  switch (event.type) {
    case 'message': {
      if (
        !isBase64String(event.ciphertext, MAX_MESSAGE_BYTES)
      ) {
        fail(
          'invalid_message',
          `ciphertext must be base64 and no larger than ${MAX_MESSAGE_BYTES} bytes`,
        );
      }
      const kind = event.kind === undefined ? 'text' : event.kind;
      if (!isKind(kind)) {
        fail('invalid_message', 'kind is invalid');
      }
      return {
        type: 'message',
        id: requireUuid(event.id, 'id'),
        to: requireUuid(event.to, 'to'),
        ciphertext: event.ciphertext,
        kind,
        meta: validateMeta(event.meta),
        createdAt: validateCreatedAt(event.createdAt),
      };
    }
    case 'message.ack':
      return {
        type: 'message.ack',
        ids: validateIds(event.ids),
      };
    case 'message.read': {
      const ids = validateIds(event.ids);
      return {
        type: 'message.read',
        chatWith: requireUuid(event.chatWith, 'chatWith'),
        ids,
      };
    }
    case 'signal':
      return {
        type: 'signal',
        to: requireUuid(event.to, 'to'),
        data: validateSignalData(event.data),
      };
    case 'typing':
      if (typeof event.on !== 'boolean') {
        fail('invalid_event', 'on must be a boolean');
      }
      return {
        type: 'typing',
        to: requireUuid(event.to, 'to'),
        on: event.on,
      };
    case 'presence':
      if (!['active', 'away'].includes(event.status)) {
        fail('invalid_event', 'status must be active or away');
      }
      return { type: 'presence', status: event.status };
    default:
      fail('unknown_type', 'Unknown event type');
  }
}

module.exports = {
  MAX_BATCH,
  MAX_MESSAGE_BYTES,
  ProtocolError,
  parseClientEvent,
  validateSignalData,
};
