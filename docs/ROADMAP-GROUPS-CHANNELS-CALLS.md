# Coralink — архитектура: группы, каналы, звонки, аудио/видео-сообщения

> **Статус (2026-11-19): реализовано.** Группы (E2EE через AES-GCM ключи),
> аудио/видеозвонки (WebRTC, signaling по WebSocket), аудио/видеосообщения и
> «видеокружки», а также мультидевайс-бэкап ключей — в коде и проверены на
> Android-эмуляторах. Документ ниже сохраняет проектную архитектуру как
> справочник реализации. Не реализовано пока: каналы (broadcast), полноценный
> concurrent multi-device (per-device sessions + sender keys), внешний push (FCM/ntfy).

Проектный документ. Описывает, как расширить текущую P2P/E2EE-архитектуру
(1-на-1 Double Ratchet, signaling через WS, WebRTC DataChannel) до групп,
каналов, звонков и AV-сообщений. Реализация — фазами; здесь — целевая
архитектура, модель данных, протокол и порядок работ.

Принципы (сохраняем то, что уже есть):
- E2EE по умолчанию; сервер не видит содержимое.
- Чистая слоятная архитектура: `domain` ↔ `data` ↔ `services` ↔ `presentation`,
  зависимости через Riverpod, порты (интерфейсы) вместо конкретных реализаций.
- Один аккаунт = несколько устройств; идентичность Signal — на устройстве.

---

## 1. Групповые чаты

### 1.1 Модель данных (сервер)
```
groups(id, title, avatar, created_by, created_at)
group_members(group_id, user_id, role[owner|admin|member], joined_at)  PK(group_id,user_id)
group_invites(code, group_id, created_by, expires_at, uses_left)
```
Relay-очередь расширяется: `messages` получает колонку `group_id` (NULL для 1-1).
Доставка группового сообщения = fan-out всем участникам (relay) + офлайн-очередь
каждому.

### 1.2 E2EE для групп — Sender Keys (как Signal/WhatsApp)
Пер-пир-рачкет на N участников не масштабируется. Используем **sealed sender
keys**:
- Каждый участник генерирует пару `ChainKey`-состояний (Main Key → Chain Keys по
  эпохам) — «sender key».
- Sender key распространяется остальным **зашифрованным 1-на-1 каналом**
  (существующий Double Ratchet с каждым участником). При входе участник получает
  все текущие sender keys; при «смене ключей» (участник вышел) — перегенерация.
- Сообщение в группе шифруется sender key отправителя; получатель расшифровывает
  ключом, привязанным к автору.
- `identity changed`/`outbox`-логика переиспользуется.

Клиент: новый `GroupSignalService` поверх `PersistentSignalStore` (хранит map
`groupId → {peerId → senderChainState}`).

### 1.3 Протокол WS (добавить)
```
{type:'group.create', title, avatar}            -> {groupId}
{type:'group.invite', groupId, username|code}   -> invite
{type:'group.join', code}                       -> {group, members}
{type:'group.leave', groupId}
{type:'group.send', id, groupId, ciphertext, senderKeyVersion}
{type:'group.members', groupId}                 -> [{id,name,role,avatar}]
{type:'senderKey.distribute', groupId, forUserId, encryptedBundle}
```
Presence/typing расширяются на `groupId`.

### 1.4 Клиент/UX
- Экран «Новая группа»: название, аватар, выбор контактов.
- Список чатов: групповые тайлы (аватар-коллаж или фото, счётчик участников).
- Экран группы: участники, роли, «Пригласить по ссылке» (group invite code).
- `ChatsController` различает `chatType: direct|group`.

### 1.5 Границы/безопасность
- Сервер авторизует членство до доставки; не читает содержимое.
- При выходе участника — принудительная ротация sender keys (post-compromise
  security).
- Лимиты: размер группы, частота fan-out.

---

## 2. Каналы (broadcast)

Односторонняя рассылка: владелец постит, подписчики читают (без ответов либо с
ограниченными реакциями).

### 2.1 Модель
```
channels(id, title, about, avatar, owner_id, created_at, is_public)
channel_subscribers(channel_id, user_id, joined_at)  PK(channel_id,user_id)
```
Сообщения канала — тот же `messages` с `channel_id`; E2EE: sender key владельца
распространяется подписчикам (1-на-1 канал владельца→подписчик).

### 2.2 Протокол
```
{type:'channel.create', ...} / {type:'channel.subscribe', id|handle}
{type:'channel.post', channelId, ciphertext} / {type:'channel.read', channelId, upto}
```
Отличие от группы: нет member-typing, нет права писать у подписчиков; публичный
каталог каналов (по желанию).

### 2.3 UX
- Отдельная вкладка/раздел «Каналы», лента поста, счётчик непрочитанных,
  «подписаться/отписаться».

---

## 3. Аудио- и видеозвонки

Переиспользуем существующий WebRTC-стек (`flutter_webrtc`, signaling через WS,
уже есть offer/answer/ICE через `P2PManager`).

### 3.1 Сигнализация (добавить к WS)
```
{type:'call.invite', to, mode:'audio'|'video', offer}
{type:'call.accept'|'call.decline'|'call.busy', to}
{type:'call.offer'|'call.answer'|'call.ice', to, ...}   (уже похоже на p2p.*)
{type:'call.hangup', to, reason}
```
1-на-1 звонок: два WebRTC-пирa, `getUserMedia` (микро/камера), `RTCPeerConnection`
с аудио/видео дорожками + DataChannel для метаданных. TURN обязателен для NAT
за пределами tailnet (coturn; в tailnet P2P обычно прямой).

### 3.2 Групповые звонки (позже, фаза 2)
- MVP: SFU-нет — full-mesh до ~4 участников (как в текущем P2P).
- Дальше: mediasoup/LiveKit SFU на сервере для масштаба. Отдельный проект.

### 3.3 Клиент
- `CallService` (порт) + `WebRtcCallService`. Состояния: ringing/in-call/ended.
- UI: экран звонка (PIP видео, mute/camera/hangup), входящий звонок =
  уведомление + полноэкранный.
- `flutter_webrtc` уже в зависимостях; добавить разрешения microphone/camera
  (уже в AndroidManifest — проверить), `permission_handler` для запроса.

### 3.4 Безопасность
- Медиа идёт P2P (SRTP, DTLS) — сервер видит только signaling.
- Верификация пиров через существующие Signal identity (fingerprint во время
  звонка — «safety number» как в Signal).

---

## 4. Аудио- и видеосообщения (в чате)

«Особенное, но не перегруженное»: не просто файл, а нативные плееры.

### 4.1 Голосовые сообщения (voice notes)
- Запись: пакет `record` (`AudioRecorder`), AAC/opus, нормализация громкости.
- Отправка: envelope `type:'audio'`, base64 (лимит ~2 МБ ≈ 2–3 мин при 64 kbps),
  meta `{durationMs, mime}`.
- Прослушка: «пузырь» с волной, кнопка play, прогресс, скорость 1x/1.5x/2x.
- Хранение: как изображения (base64 в meta локально), сервер — только шифротекст.

### 4.2 Видеосообщения (видеокружки)
- Запись: короткое видео (камера) до ~30 с / ~8 МБ, сжатие.
- envelope `type:'video'`, meta `{durationMs, mime, w, h}`.
- Просмотр: вложенный плеер с tap-to-play, полноэкранный режим.
- Ограничения по размеру согласованы с лимитами WS (см. hub/protocol).

### 4.3 Модель
- `MessageKind` += `audio`, `video`.
- `Message` += `audioBase64`/`videoBase64` (или единый `attachmentBase64` +
  `attachmentKind`). Лучше: обобщить вложение — `attachment{kind,b64,mime,name,size,durationMs}`
  в `meta`, чтобы аудио/видео/файл/фото шли одним путём (рефакторинг image-пути).

---

## 5. Рефакторинг вложений (общая основа для 3/4)
Сейчас изображения идут отдельным полем `imageBase64`. Для аудио/видео/файлов
ввести единый `Attachment`:
```
class Attachment { kind: image|video|audio|file; data: base64; mime; name; size; durationMs; }
```
`MessageKind` → `text | attachment | reaction | delete`, а тип вложения — в
`attachment.kind`. Упрощает bubble-рендер и retry. Это предваряет фазу 4.

---

## 6. План реализации (фазы)

| Фаза | Содержание | Оценка | Зависимости |
|------|-----------|--------|-------------|
| A | Рефакторинг вложений (Attachment) + голосовые сообщения | M | — |
| B | Видеосообщения + видеокружки | M | A |
| C | Группы 1-на-1→много (Sender Keys, fan-out, UI) | L | существующий Signal |
| D | 1-на-1 аудио/видеозвонки (WebRTC media + signaling) | L | TURN для публ. сети |
| E | Каналы (broadcast) | M | C (sender keys) |
| F | Групповые звонки (mesh→SFU) | XL | C+D |

Рекомендуемый порядок: **A → C → D → B → E → F** (сначала общая основа и группы,
потому что каналы/звонки опираются на групповые примитивы).

## 7. Что нужно от пользователя для публичного запуска звонков
- TURN-сервер (coturn) с секретами, либо оставаться в tailnet (P2P прямой).
- Разрешения микрофона/камеры на Android (AndroidManifest) — проверить.

---

Этот документ — контракт для последующих PR. Каждая фаза — отдельная ветка с
тестами (сервер: unit; клиент: unit + integration E2E на Windows, как сейчас).
