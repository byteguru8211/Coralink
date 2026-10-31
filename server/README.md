# Coralink Server

Signaling and message relay backend for the Coralink end-to-end encrypted
messenger. The server stores ciphertext, public keys, routing metadata, and
presence; it never receives plaintext or private keys.

## Requirements

- Node.js 24.x
- npm 11.x

The only runtime dependency is [`ws`](https://www.npmjs.com/package/ws). SQLite
is provided by the built-in `node:sqlite` module.

## Run locally

```bash
npm install
cp .env.example .env

# Node 24 can load .env directly:
node --env-file=.env src/index.js

# Or export variables in your shell and use:
npm start
```

Development mode (`DEV_MODE=true`) is enabled automatically outside
`NODE_ENV=production`. In development the `/api/v1/auth/request-code` response
contains `devCode` so the flow can be tested without an SMS provider; the code
is also written to the structured development log.

Development default secrets exist only when `DEV_MODE=true`. With
`NODE_ENV=production` (or `DEV_MODE=false`), `JWT_SECRET` and `AUTH_PEPPER` are
mandatory and must each be at least 32 characters. Generate them with:

```bash
openssl rand -hex 32
```

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `NODE_ENV` | `development` | Set to `production` for production. |
| `HOST` | `0.0.0.0` | HTTP listen address. |
| `PORT` | `8080` | HTTP/WebSocket listen port. |
| `DB_PATH` | `./data/coralink.db` | SQLite file. WAL mode is enabled. |
| `JWT_SECRET` | dev-only default | HS256 signing secret, ≥32 chars in production. |
| `AUTH_PEPPER` | dev-only default | Pepper used to HMAC phone verification codes. |
| `DEV_MODE` | `true` outside production | Returns/logs `devCode`; ignored in production. |
| `ALLOWED_ORIGINS` | `*` in development, empty in production | Comma-separated CORS origins. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error`, or `silent`. |
| `MESSAGE_TTL_DAYS` | `30` | Offline message retention. |
| `WS_MAX_CONNECTIONS` | `3` | Concurrent sockets per user. |

## API overview

All endpoints are JSON under `/api/v1`. Authenticated requests use
`Authorization: Bearer <JWT>`. Errors have the shape
`{"error":{"code":"...","message":"..."}}`.

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `POST` | `/auth/request-code` | No | Request a 6-digit code. |
| `POST` | `/auth/verify` | No | Verify code, create user if needed, return JWT. |
| `GET` | `/me` | Yes | Current profile and online state. |
| `PATCH` | `/me` | Yes | Update name/about/avatar color. |
| `GET` | `/users/search?q=` | Yes | Search by name prefix or phone digits. |
| `GET` | `/users/:id` | Yes | Public profile. |
| `GET` | `/contacts` | Yes | List contacts. |
| `POST` | `/contacts` | Yes | Add a contact (idempotent). |
| `DELETE` | `/contacts/:userId` | Yes | Remove a contact. |
| `POST` | `/keys` | Yes | Publish identity, signed prekey, and one-time prekeys. |
| `GET` | `/keys/:userId` | Yes | Fetch a key bundle and atomically consume a prekey. |
| `POST` | `/keys/prekeys` | Yes | Replenish one-time prekeys. |
| `GET` | `/messages/queued` | Yes | Fetch up to 500 undelivered messages. |
| `POST` | `/messages/ack` | Yes | Mark messages delivered and notify senders. |
| `GET` | `/presence?ids=a,b,c` | Yes | Presence for up to 100 users. |
| `POST` | `/push/register` | Yes | Store a push token. |
| `DELETE` | `/push/register` | Yes | Remove a push token. |
| `GET` | `/health` | No | Liveness/version response. |

Rate limits: request-code `5/hour/IP`, verify `10/15 min/IP`, all API routes
`300/min/IP`. Request-code also enforces a 60-second cooldown per phone.
`429` responses include `Retry-After`.

## WebSocket protocol

Connect to `ws://host:port/ws?token=<JWT>`. The first server event is:

```json
{"type":"ready","userId":"...","serverTime":1700000000000}
```

Client events:

- `{"type":"message","id":"<uuid>","to":"<userId>","ciphertext":"<base64>","kind":"text","meta":{},"createdAt":1700000000000}`
- `{"type":"message.ack","ids":["<uuid>"]}`
- `{"type":"message.read","chatWith":"<userId>","ids":["<uuid>"]}`
- `{"type":"signal","to":"<userId>","data":{"kind":"offer|answer|ice","sdp":"...","candidate":"..."}}`
- `{"type":"typing","to":"<userId>","on":true}`
- `{"type":"presence","status":"active|away"}`

Server events include `message`, `message.ack`, `message.ack.ok`,
`message.delivered`, `message.read`, `signal`, `typing`, `presence`, and
`error`. The server sends ping frames every 30 seconds and terminates sockets
that do not answer with pong.

## Tests

```bash
npm test
```

Tests use the built-in `node:test` runner and real HTTP/WebSocket servers on
ephemeral ports with isolated temporary SQLite databases.

## Docker

```bash
docker build -t coralink-server .
docker run --rm -p 8080:8080 \
  -e JWT_SECRET="$(openssl rand -hex 32)" \
  -e AUTH_PEPPER="$(openssl rand -hex 32)" \
  -e ALLOWED_ORIGINS="https://app.example" \
  -v coralink-data:/app/data \
  coralink-server
```

Production containers do not return development codes. Supply TLS termination
at a reverse proxy and use a persistent volume for `DB_PATH`.
