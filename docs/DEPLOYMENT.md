# Развёртывание Coralink

## 1. Требования

| Компонент | Версия |
|---|---|
| Node.js | 24+ (используется `node:sqlite`) |
| Flutter | 3.44+ (Dart 3.12) |
| JDK | 21 (для Android) |
| Android SDK | platform 36, build-tools 36.1 |
| ОС сборки | Windows/Linux/macOS (iOS — только macOS) |

## 2. Переменные окружения сервера

| Переменная | Обязательна | По умолчанию | Описание |
|---|---|---|---|
| `NODE_ENV` | нет | `development` | `production` отключает dev-коды и требует секреты |
| `PORT` | нет | `8080` | Порт HTTP/WS |
| `HOST` | нет | `0.0.0.0` | Интерфейс |
| `JWT_SECRET` | в prod | dev-значение | ≥ 32 символов |
| `AUTH_PEPPER` | в prod | dev-значение | ≥ 32 символов, для HMAC кодов |
| `DEV_MODE` | нет | `true` вне prod | Возвращать `devCode` клиенту |
| `DB_PATH` | нет | `./data/coralink.db` | Путь к SQLite |
| `MESSAGE_TTL_DAYS` | нет | `30` | Сколько хранить недоставленные |
| `ALLOWED_ORIGINS` | нет | `*` в dev | Список origin через запятую |
| `WS_MAX_CONNECTIONS` | нет | `3` | Соединений на пользователя |
| `LOG_LEVEL` | нет | `info` | `debug/info/warn/error/silent` |

Пример production `.env`:

```env
NODE_ENV=production
PORT=8080
JWT_SECRET=<openssl rand -base64 48>
AUTH_PEPPER=<openssl rand -base64 48>
DEV_MODE=false
DB_PATH=/var/lib/coralink/coralink.db
MESSAGE_TTL_DAYS=7
ALLOWED_ORIGINS=https://app.coralink.example.com
LOG_LEVEL=info
```

## 3. Локальный запуск

```bash
cd server
npm ci --omit=dev
node src/index.js
```

## 4. systemd

`/etc/systemd/system/coralink.service`:

```ini
[Unit]
Description=Coralink signaling server
After=network.target

[Service]
Type=simple
User=coralink
WorkingDirectory=/opt/coralink/server
EnvironmentFile=/etc/coralink/coralink.env
ExecStart=/usr/bin/node src/index.js
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/coralink

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now coralink
```

## 5. Nginx + TLS

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    server_name api.coralink.example.com;

    ssl_certificate     /etc/letsencrypt/live/api.coralink.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.coralink.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;

    client_max_body_size 2m;

    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Клиент собирается с `--dart-define=API_URL=https://api.coralink.example.com` (WS-адрес выводится автоматически).

Web-версию можно раздавать с того же домена из `app/build/web` или отдельным сайтом с CORS-origin в `ALLOWED_ORIGINS`.

## 6. Docker

```bash
cd server
docker build -t coralink-server .
docker run -d --name coralink \
  -p 8080:8080 \
  -v coralink-data:/data \
  -e NODE_ENV=production \
  -e JWT_SECRET=... -e AUTH_PEPPER=... \
  -e DB_PATH=/data/coralink.db \
  coralink-server
```

Dockerfile использует `node:24-alpine`, запускается от non-root, содержит healthcheck. (В среде разработки Docker отсутствовал, поэтому образ не собирался.)

## 7. TURN (рекомендуется)

Без TURN часть соединений не установится напрямую и уйдёт на relay. Для coturn:

```conf
listening-port=3478
fingerprint
lt-cred-mech
realm=coralink.example.com
user=coralink:<password>
```

Сборка клиента:

```bash
flutter build apk --release \
  --dart-define=API_URL=https://api.coralink.example.com \
  --dart-define=TURN_URL=turn:turn.coralink.example.com:3478 \
  --dart-define=TURN_USERNAME=coralink \
  --dart-define=TURN_CREDENTIAL=<password>
```

Для продакшена используйте краткоживущие TURN-credentials через API.

## 8. SMS-провайдер

Сейчас код подтверждения генерируется и возвращается только в dev-режиме. Для продакшена:

1. Отключите `DEV_MODE`.
2. В `server/src/routes/auth.js` после сохранения хеша кода вызовите SMS-шлюз (Twilio, SMS.ru, AWS SNS и т.п.).
3. Никогда не возвращайте код в ответе.
4. Настройте антифрод: лимиты по номеру/стране, капчу после нескольких попыток.

## 9. Push-уведомления

Сервер уже принимает и хранит токены (`/push/register`). Чтобы включить доставку:

1. Создайте Firebase-проект, добавьте `google-services.json` в `app/android/app/` (и `GoogleService-Info.plist` для iOS).
2. На сервере добавьте отправку FCM/APNS при `handleIncomingMessage`, если получатель офлайн.
3. В push-payload не включайте текст сообщения — только `chatId` и тип; текст клиент расшифрует локально.

## 10. Release-подпись Android

```bash
keytool -genkeypair -v -keystore coralink-release.jks -keyalg RSA \
  -keysize 2048 -validity 10000 -alias coralink
```

`app/android/key.properties` (не коммитить):

```properties
storePassword=...
keyPassword=...
keyAlias=coralink
storeFile=../keystore/coralink-release.jks
```

Добавьте в `android/app/build.gradle.kts` чтение `key.properties` и `signingConfigs.release`.  
Без файла сборка использует debug-подпись — только для тестов. Никогда не публикуйте debug-подпись в сторах.

## 11. iOS

Требуется macOS + Xcode:

```bash
cd app
flutter build ios --release --dart-define=API_URL=https://api.coralink.example.com
```

Настройте bundle id, команду подписи, APNS, `NSAllowsLocalNetworking` уже добавлен для dev. Минимальная версия — iOS 14.

## 12. Обновления и бэкапы

- БД: SQLite WAL. Бэкап: `sqlite3 coralink.db ".backup '/backup/coralink-$(date +%F).db'"`.
- Храните бэкапы зашифрованными; сервер содержит метаданные и шифротекст.
- Обновление: остановить сервис → заменить код → `npm ci --omit=dev` → запустить. Миграции схемы добавляйте идемпотентно (`CREATE TABLE IF NOT EXISTS`).
- Мониторинг: `/health`, доля 429/401, размер очереди, задержка WS.

## 13. Чек-лист production

- [ ] `DEV_MODE=false`, секреты ≥ 32 символов.
- [ ] HTTPS/WSS, HSTS.
- [ ] `ALLOWED_ORIGINS` ограничен.
- [ ] TURN развёрнут и проверен.
- [ ] SMS-шлюз подключён, dev-код не возвращается.
- [ ] Release-подпись Android/iOS настроена.
- [ ] Бэкапы БД и мониторинг.
- [ ] Проведён аудит безопасности и пентест.
