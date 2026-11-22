# API сервера Coralink

Base URL в dev: `http://127.0.0.1:8080`.  
Все ответы — JSON UTF-8. Ошибки:

```json
{"error":{"code":"invalid_code","message":"Wrong or expired code"}}
```

HTTP-коды: `400` неверный запрос, `401` нет/истёк токен, `403` запрещено, `404` не найдено, `409` конфликт, `429` лимит, `500` внутренняя ошибка.

Авторизация: `Authorization: Bearer <JWT>` (HS256, 30 дней).

## REST

### Health

```
GET /health
→ 200 {"ok":true,"version":"1.0.0"}
```

Вне `/api/v1`, без авторизации.

### Аутентификация

```
POST /api/v1/auth/request-code
{"phone":"79990000001"}
→ 200 {"ok":true,"retryAfter":60,"devCode":"123456"}   // devCode только в DEV_MODE
```

Лимиты: 60 с на номер, 5 запросов/час с IP. Код живёт 5 минут, 5 попыток.

```
POST /api/v1/auth/verify
{"phone":"79990000001","code":"123456","name":"Алиса"}   // name необязателен
→ 200 {
  "token":"eyJ...",
  "user":{"id":"...","phone":"79990000001","name":"Алиса","about":"","avatarColor":"#1A9C7A","lastSeen":1730000000000,"online":true},
  "isNew":true
}
```

`phone` нормализуется до 10–15 цифр. Неверный код → `401 invalid_code`; превышение попыток → `429`.

```
POST /api/v1/auth/register
{"username":"alice","password":"secret123","name":"Alice Doe"}   // name необязателен
→ 200 {
  "token":"eyJ...",
  "user":{"id":"...","username":"alice","name":"Alice Doe","about":"","avatarColor":"#1A9C7A","lastSeen":1730000000000,"online":true,"phone":null},
  "isNew":true
}

POST /api/v1/auth/login
{"username":"alice","password":"secret123"}
→ 200 { "token":"eyJ...", "user":{...}, "isNew":false }
```

Основной путь входа в приложении — никнейм + пароль. Пароль проверяется через
scrypt (N=16384, r=8, p=1) с серверным pepper; хранится только хеш. `username`:
3–32, латиница/цифры/`.`/`_`. Занятый ник при регистрации → `409 username_taken`;
неверные данные при входе → `401 invalid_credentials`. SMS-маршруты
(`request-code`/`verify`) сохранены как опциональный путь и не используются в
приложении по умолчанию.

### Профиль

```
GET /api/v1/me
→ 200 {"user":{...приватный профиль с phone...}}

PATCH /api/v1/me
{"name":"Алиса","about":"Люблю растения","avatarColor":"#2FB894","avatar":"data:image/png;base64,...","presenceVisibility":"contacts"}
→ 200 {"user":{...}}

DELETE /api/v1/me
→ 200 {"ok":true}      // каскадное удаление аккаунта и данных
```

Ограничения: имя 1–64, about ≤ 280, цвет `#RRGGBB`, `avatar` — data-URL PNG/JPEG/WebP ≤ 500 КБ, `presenceVisibility` — `everyone | contacts | nobody`.

### Поиск и контакты

```
GET /api/v1/users/search?q=7999
→ 200 {"users":[{публичный профиль без телефона}]}

GET /api/v1/users/:id
→ 200 {"user":{...}}

GET /api/v1/contacts
→ 200 {"contacts":[{...}]}

POST /api/v1/contacts {"userId":"..."}
→ 201 {"contact":{...}}

DELETE /api/v1/contacts/:userId
→ 200 {"ok":true}
```

Поиск: подстрока телефона или префикс имени, до 20 результатов, без себя.

### Ключи

```
POST /api/v1/keys
{
  "identityKey":"<base64>",
  "registrationId":1234,
  "signedPreKey":{"id":1,"publicKey":"<base64>","signature":"<base64>"},
  "preKeys":[{"id":1,"publicKey":"<base64>"}, ...]
}
→ 200 {"ok":true}

POST /api/v1/keys/prekeys
{"preKeys":[{...}]}
→ 200 {"ok":true,"stored":100}

GET /api/v1/keys/:userId
→ 200 {
  "userId":"...",
  "identityKey":"<base64>",
  "registrationId":1234,
  "signedPreKey":{"id":1,"publicKey":"<base64>","signature":"<base64>"},
  "preKey":{"id":42,"publicKey":"<base64>"} | null
}
```

`GET /keys/:userId` **атомарно расходует** один one-time prekey. Если ключей нет → `404 no_keys`.

### Сообщения (REST)

```
GET /api/v1/messages/queued
→ 200 {"messages":[
  {"id":"uuid","senderId":"uuid","ciphertext":"<base64>","kind":"text|image|control","meta":{},"createdAt":1730000000000}
]}

POST /api/v1/messages/ack
{"ids":["uuid"]}
→ 200 {"ok":true,"acked":1}
```

Очередь — недоставленные сообщения (без ack), до 500, старше TTL удаляются.

### Присутствие

```
GET /api/v1/presence?ids=uuid1,uuid2
→ 200 {"presence":{"uuid1":{"online":true,"lastSeen":1730000000000}}}
```

Фильтрация: при `nobody` другие видят `online:false` и `lastSeen:null`; при `contacts` — только взаимные контакты; `everyone` — все авторизованные. Сервер применяет ту же политику к WS-событиям `presence`.

### Push-токены

```
POST /api/v1/push/register {"token":"...","platform":"android"}
→ 200 {"ok":true}

DELETE /api/v1/push/register {"token":"..."}
→ 200 {"ok":true}
```

> Отправка FCM/APNS требует креденшелов и в этой версии не включена; токены только сохраняются.

### Группы

```
POST /api/v1/groups
{"title":"Команда","members":["uuid",...],"avatar":"data:image/png;base64,..."}
→ 201 {"group":{...},"members":[{...}]}

GET /api/v1/groups
→ 200 {"groups":[{"id":"...","title":"...","avatar":"...","createdBy":"...","memberCount":3,"createdAt":...}]}

GET /api/v1/groups/:id
→ 200 {"group":{...},"members":[{id,name,username,avatar,avatarColor,role}]}   // только участник

PATCH /api/v1/groups/:id
{"title":"Новое имя","avatar":"data:image/png;base64,..."}   // только owner/admin
→ 200 {"group":{...}}

POST /api/v1/groups/:id/members
{"userId":"uuid"}   // пригласить может любой участник
→ 200 {"members":[...]}

DELETE /api/v1/groups/:id/members/:userId
→ 200 {"ok":true}   // выход участника или удаление админом

GET /api/v1/groups/queued
→ 200 {"messages":[{id,groupId,senderId,ciphertext,kind,meta,createdAt}]}

POST /api/v1/groups/ack
{"ids":["uuid"]}
→ 200 {"ok":true}
```

Содержимое групповых сообщений — AES-GCM шифротекст (ключ группы распределяется
по 1-на-1 Signal-каналам); сервер видит только его. `avatar` группы — data-URL ≤ 500 КБ.

### Бэкап ключей (мультидевайс)

```
PUT /api/v1/backup
{"blob":"<base64 AES-GCM>","salt":"<base64>"}
→ 200 {"ok":true}

GET /api/v1/backup
→ 200 {"blob":"<base64>","salt":"<base64>","updatedAt":1730000000000}
→ 404 no_backup   // если бэкапа ещё нет
```

Сервер хранит только непрозрачный шифротекст и соль; ключ выводится из пароля на
устройстве (PBKDF2-HMAC-SHA256). `blob` ≤ 1 МБ.

## WebSocket

`ws(s)://host/ws?token=<JWT>`

Неавторизованный upgrade → HTTP 401. Максимум 3 соединения на пользователя.
Клиент шлёт прикладной heartbeat `{"type":"ping"}` каждые 25 с, сервер отвечает
`{"type":"pong"}`.

### Сервер → клиент

```json
{"type":"ready","userId":"uuid","serverTime":1730000000000}
{"type":"message","message":{"id":"uuid","from":"uuid","ciphertext":"...","kind":"text","meta":{},"createdAt":1730000000000}}
{"type":"message.ack","id":"uuid","status":"delivered|queued"}
{"type":"message.delivered","messageIds":["uuid"],"ids":["uuid"]}
{"type":"message.read","messageIds":["uuid"],"ids":["uuid"],"by":"uuid"}
{"type":"group.message","message":{"id":"uuid","groupId":"uuid","from":"uuid","ciphertext":"...","kind":"text","meta":{},"createdAt":1730000000000}}
{"type":"group.read","messageIds":["uuid"],"by":"uuid","groupId":"uuid"}
{"type":"signal","from":"uuid","data":{"kind":"offer|answer|ice","sdp":"...","candidate":"...","sdpMid":"0","sdpMLineIndex":0}}
{"type":"call","from":"uuid","data":{"action":"call|answer|ice|decline|busy|hangup","mode":"audio|video","sdp":"...","candidate":"..."}}
{"type":"typing","from":"uuid","on":true}
{"type":"presence","userId":"uuid","status":"online|away|offline","lastSeen":1730000000000}
{"type":"pong"}
{"type":"error","code":"peer_offline","message":"Peer is not connected"}
```

`message.delivered` содержит и `messageIds`, и `ids` для совместимости. `call` —
relay WebRTC-signaling для звонков; если получатель офлайн и `action=call`,
отправителю приходит `busy`.

### Клиент → сервер

```json
{"type":"message","id":"uuid","to":"uuid","ciphertext":"<base64>","kind":"text|image|file|audio|video|video_note|sticker|control","meta":{},"createdAt":1730000000000}
{"type":"message.ack","ids":["uuid"]}
{"type":"message.read","chatWith":"uuid","ids":["uuid"]}
{"type":"group.send","id":"uuid","groupId":"uuid","ciphertext":"<base64>","kind":"text","meta":{},"createdAt":1730000000000}
{"type":"group.read","groupId":"uuid","ids":["uuid"]}
{"type":"signal","to":"uuid","data":{"kind":"offer","sdp":"..."}}
{"type":"signal","to":"uuid","data":{"kind":"ice","candidate":"...","sdpMid":"0","sdpMLineIndex":0}}
{"type":"call","to":"uuid","data":{"action":"call","mode":"audio|video","sdp":"..."}}
{"type":"typing","to":"uuid","on":true}
{"type":"presence","status":"active|away"}
{"type":"ping"}
```

Правила:

- `ciphertext` — base64, ≤ 9 МБ (позволяет передавать вложения через relay); `id` — UUID.
- `meta` — ≤ 16 КБ и не содержит байтов вложения (они внутри шифротекста).
- Отправка дубликата `id` идемпотентна.
- `kind=control` используется для реакций и удаления; сервер считает нагрузку непрозрачной.
- `kind=sticker` — стикер: в шифрованном конверте лежит `{"type":"sticker","meta":{"sticker":"wave"}}`; id — один из `wave`, `hug`, `moon`, `star`, `laugh`, `miss`, `yay`, `thanks`.
- `signal`/`call` доставляются только при живом сокете получателя, иначе `peer_offline`/`busy`.
- Тело сообщения не логируется.

## Rate limits

| Действие | Лимит |
|---|---|
| request-code | 1/60 c на номер, 5/час на IP |
| verify | 10/15 мин на IP |
| API всего | 300/мин на IP |

При превышении — `429` с `Retry-After`.
