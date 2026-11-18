# Coralink

**Grow your conversations.**  
Coralink — кросс-платформенный мессенджер со сквозным шифрованием, P2P-доставкой и «природным» интерфейсом: сообщения прорастают, уведомления светятся, а старые разговоры уплывают в нижний слой.

<p align="center">
  <img src="docs/screens/android_login.png" width="240" alt="Экран входа" />
  <img src="docs/screens/android_chats_empty.png" width="240" alt="Список чатов" />
</p>

---

## Что реализовано

| Блок | Статус |
|---|---|
| Flutter-приложение (Android, Windows, Web, iOS-каркас) | ✅ |
| Сквозное шифрование Signal Protocol (X3DH + Double Ratchet) | ✅ |
| Локальная БД: SQLCipher на Android/iOS, SQLite на desktop, память на web | ✅ |
| WebRTC DataChannel + fallback на серверный relay | ✅ |
| Офлайн-очередь, дедупликация, повторная отправка | ✅ |
| Присутствие (online / active / away / offline), печатает… | ✅ |
| Экраны: splash, вход, SMS-код, профиль, чаты, переписка, контакты, настройки, уведомления, звуки, приватность, эхолокация | ✅ |
| Анимации прорастания, пульсации, «капли», звуки природы | ✅ |
| 4 режима уведомлений, локальные уведомления | ✅ |
| «Эхолокация» — локальный поиск по смыслу (стемминг + синонимы + триграммы) | ✅ |
| «Приливы и отливы» — автоархив неактивных чатов и старых сообщений | ✅ |
| Реакции-капли, удаление у себя/у всех, фото и файлы (до 8 МБ) | ✅ |
| Фото профиля, настраиваемая ссылка сервера, вход по никнейму | ✅ |
| Тёмная/светлая изумрудная темы, RU/EN | ✅ |
| Сервер: auth, ключи, signaling, relay, presence, push-токены | ✅ |
| Уведомления: Windows и Android (запрос разрешения при старте) | ✅ |
| Тесты: 33 серверных + 11 клиентских + реальный E2E двух клиентов | ✅ |

## Статус проверки (2026-11-18)

| Проверка | Результат |
|---|---|
| `server: npm test` | 33/33 |
| `app: flutter test` | 11/11 |
| `flutter analyze` | 0 ошибок и предупреждений |
| E2E двух клиентов (Windows integration test) | пройден: A↔B, офлайн-очередь, сервер видит только шифротекст |
| Release-сборки | APK (arm64/armeabi/x86_64/universal, подписан), Windows x64, Web |
| UI | проверен на Android-эмуляторе и в Chrome |

Готовые файлы: `dist/` (APK, Windows-zip, Web-zip, презентация, SHA256SUMS). Папка исключена из git из-за размера.

## Архитектура в двух словах

```
┌──────────────────────────────┐        ┌──────────────────────────────┐
│        Flutter-клиент        │        │        Node.js сервер        │
│  UI (Riverpod)               │        │  HTTP API + WebSocket hub    │
│  Domain-сервисы              │◄──────►│  SQLite (node:sqlite)        │
│  Signal Protocol (E2EE)      │  TLS   │  auth / keys / relay / signal│
│  SQLCipher / SQLite          │        │  НЕ видит открытый текст     │
└──────────────┬───────────────┘        └──────────────────────────────┘
               │  WebRTC DataChannel (напрямую, когда возможно)
               ▼
        Другой клиент Coralink
```

Подробно: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/SECURITY.md](docs/SECURITY.md).

## Быстрый старт

### 1. Сервер

```bash
cd server
npm install
NODE_ENV=development DEV_MODE=true PORT=8080 \
JWT_SECRET=dev-jwt-secret-with-more-than-32-characters \
AUTH_PEPPER=dev-auth-pepper-with-more-than-32-characters \
node src/index.js
```

Проверка: `curl http://127.0.0.1:8080/health` → `{"ok":true,"version":"1.0.0"}`.

В dev-режиме код подтверждения возвращается в ответе `request-code` и пишется в лог — SMS-провайдер не нужен.

### 2. Приложение

```bash
cd app
flutter pub get

# Windows (удобно для локальной пары клиентов)
flutter run -d windows

# Web
flutter run -d chrome

# Android-эмулятор (сервер доступен по 10.0.2.2)
flutter run -d emulator-5554
```

Адрес сервера по умолчанию: `http://127.0.0.1:8080` (Android-эмулятор — `http://10.0.2.2:8080`).
Переопределение:

```bash
flutter run --dart-define=API_URL=https://coralink.example.com
flutter run --dart-define=WS_URL=wss://coralink.example.com/ws
flutter run --dart-define=TURN_URL=turn:turn.example.com:3478 \
  --dart-define=TURN_USERNAME=user --dart-define=TURN_CREDENTIAL=secret
```

### 3. Демо-сценарий

1. Запустите сервер.
2. Запустите два клиента (например, Windows и Android-эмулятор).
3. На первом введите номер `79990000001`, на втором — `79990000002` (любые 10–15 цифр).
4. Код показан прямо на экране (dev-режим).
5. Задайте имя, найдите собеседника по номеру через иконку поиска людей.
6. Пишите — сообщения шифруются на устройстве и доставляются напрямую или через relay.

## Сборка

```bash
cd app
flutter build apk --release --split-per-abi   # Android (рекомендуется для стора)
flutter build apk --release                   # универсальный APK
flutter build windows --release               # Windows
flutter build web --release                   # Web
```

Release-подпись Android берётся из `android/key.properties` (файл и keystore не коммитятся). В репозитории для демо уже сгенерирован `android/keystore/coralink-release.jks` с паролем `coralink-demo-pass` — **замените его перед публикацией**. Инструкция: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

Готовые артефакты складываются в `app/build/...`; универсальный APK занимает 113 МБ из-за WebRTC-нативных библиотек, поэтому для стора используйте split-per-abi. Цель из ТЗ «< 30 МБ» недостижима с WebRTC + SQLCipher в одной универсальной сборке — это осознанный компромисс, зафиксированный в ограничениях.

## Презентация

[Скачать Coralink_Presentation.pptx](presentation/Coralink_Presentation.pptx) — 13 слайдов: проблема, решение, архитектура, безопасность, UI, тесты, деплой. Рендеры слайдов лежат в `presentation/preview/`.

## Тесты

```bash
cd server && npm test                # 29 тестов API + WS
cd app && flutter test               # юнит- и виджет-тесты
# E2E: требует запущенный сервер на 127.0.0.1:8080
cd app && flutter test integration_test/e2e_test.dart -d windows
```

E2E-тест поднимает двух клиентов, обменивается E2EE-сообщениями, проверяет офлайн-очередь и то, что сервер хранит только шифротекст.

## Структура репозитория

```
app/                    Flutter-приложение
  lib/
    app/                сессия, зависимости, сборка клиента
    core/               тема, локализация, конфиг, утилиты
    data/               БД, API-клиент, secure storage
    domain/             модели
    network/            WebSocket, WebRTC
    presentation/       экраны, виджеты, Riverpod-контроллеры
    security/           Signal Protocol, ключи
    services/           сообщения, поиск, звук, уведомления, экспорт
  test/                 юнит-тесты
  integration_test/     реальный E2E
server/                 Node.js signaling/relay сервер
  src/                  HTTP, WS, БД, auth
  test/                 node:test
docs/                   архитектура, безопасность, API, деплой, гайд
Plan/PLAN.docx          исходное ТЗ
```

## Ограничения текущей версии

- Групповые чаты и голосовые вызовы не входят в MVP.
- Одно устройство на аккаунт (multi-device — в дорожной карте).
- Web-версия хранит историю в памяти (демо/превью).
- Desktop-БД не шифруется SQLCipher (preview-платформа); мобильные — шифруются.
- Нет готовых креденшелов SMS/Firebase/TURN — предусмотрены dev-режим и конфигурация.
- Криптография собрана на проверенной библиотеке Signal Protocol, но код не проходил внешний аудит.
- Dockerfile и docker-compose не проверялись сборкой (Docker отсутствует в среде разработки).
- Универсальный release APK — 113 МБ (WebRTC + SQLCipher); используйте split-per-abi.
- Демо-keystore лежит локально и исключён из git; для продакшена создайте свой.

## Документация

- [Архитектура](docs/ARCHITECTURE.md)
- [Безопасность и модель угроз](docs/SECURITY.md)
- [API сервера](docs/API.md)
- [Развёртывание](docs/DEPLOYMENT.md)
- [Запуск через Tailscale (одна ссылка, без вложений)](docs/DEPLOYMENT-TAILSCALE.md)
- [Дорожная карта: группы, каналы, звонки, AV-сообщения](docs/ROADMAP-GROUPS-CHANNELS-CALLS.md)
- [Тестирование](docs/TESTING.md)
- [Руководство пользователя](docs/USER_GUIDE.md)

## Лицензия

Проект создан как учебно-демонстрационный продукт. Перед публикацией в сторах замените демо-ключи, настройте HTTPS/TURN/SMS и проведите аудит безопасности.
