import 'dart:convert';

enum Presence { online, active, away, offline }

Presence presenceFromWire(String? value) => switch (value) {
      'online' => Presence.online,
      'active' => Presence.active,
      'away' => Presence.away,
      _ => Presence.offline,
    };

String presenceToWire(Presence p) => switch (p) {
      Presence.online => 'online',
      Presence.active => 'active',
      Presence.away => 'away',
      Presence.offline => 'offline',
    };

class User {
  const User({
    required this.id,
    this.username = '',
    this.phone = '',
    required this.name,
    this.about = '',
    this.avatarColor = '#1A9C7A',
    this.avatar = '',
    this.lastSeen,
    this.presence = Presence.offline,
  });

  final String id;
  final String username;
  final String phone;
  final String name;
  final String about;
  final String avatarColor;
  final String avatar;
  final DateTime? lastSeen;
  final Presence presence;

  bool get isOnline =>
      presence == Presence.online ||
      presence == Presence.active ||
      presence == Presence.away;

  User copyWith({
    String? name,
    String? about,
    String? avatarColor,
    String? avatar,
    DateTime? lastSeen,
    Presence? presence,
  }) =>
      User(
        id: id,
        username: username,
        phone: phone,
        name: name ?? this.name,
        about: about ?? this.about,
        avatarColor: avatarColor ?? this.avatarColor,
        avatar: avatar ?? this.avatar,
        lastSeen: lastSeen ?? this.lastSeen,
        presence: presence ?? this.presence,
      );

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        username: (json['username'] as String?) ?? '',
        phone: (json['phone'] as String?) ?? '',
        name: (json['name'] as String?) ?? 'Coralink',
        about: (json['about'] as String?) ?? '',
        avatarColor: (json['avatarColor'] as String?) ?? '#1A9C7A',
        avatar: (json['avatar'] as String?) ?? '',
        lastSeen: json['lastSeen'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((json['lastSeen'] as num).toInt()),
        presence: json['online'] == true
            ? Presence.online
            : presenceFromWire(json['presence'] as String?),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'phone': phone,
        'name': name,
        'about': about,
        'avatar_color': avatarColor,
        'avatar': avatar,
        'last_seen': lastSeen?.millisecondsSinceEpoch,
        'presence': presenceToWire(presence),
      };

  factory User.fromRow(Map<String, Object?> row) => User(
        id: row['id'] as String,
        phone: (row['phone'] as String?) ?? '',
        name: (row['name'] as String?) ?? 'Coralink',
        about: (row['about'] as String?) ?? '',
        avatarColor: (row['avatar_color'] as String?) ?? '#1A9C7A',
        avatar: (row['avatar'] as String?) ?? '',
        lastSeen: row['last_seen'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((row['last_seen'] as num).toInt()),
        presence: presenceFromWire(row['presence'] as String?),
      );

  @override
  bool operator ==(Object other) =>
      other is User &&
      other.id == id &&
      other.name == name &&
      other.about == about &&
      other.avatarColor == avatarColor &&
      other.avatar == avatar &&
      other.presence == presence &&
      other.lastSeen == lastSeen;

  @override
  int get hashCode =>
      Object.hash(id, name, about, avatarColor, avatar, presence, lastSeen);
}

class Chat {
  const Chat({
    required this.id,
    required this.peerId,
    required this.peerName,
    this.peerPhone = '',
    this.peerAbout = '',
    this.peerAvatarColor = '#1A9C7A',
    this.peerAvatar = '',
    this.isGroup = false,
    this.memberCount = 0,
    this.peerLastSeen,
    this.peerPresence = Presence.offline,
    this.lastMessageText = '',
    this.lastMessageAt,
    this.unreadCount = 0,
    this.archived = false,
    this.pinned = false,
    this.muted = false,
    this.updatedAt,
  });

  final String id;
  final String peerId;
  final String peerName;
  final String peerPhone;
  final String peerAbout;
  final String peerAvatarColor;
  final String peerAvatar;
  final bool isGroup;
  final int memberCount;
  final DateTime? peerLastSeen;
  final Presence peerPresence;
  final String lastMessageText;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final bool archived;
  final bool pinned;
  final bool muted;
  final DateTime? updatedAt;

  String get sortStamp => (lastMessageAt ?? updatedAt ?? DateTime(2000)).toIso8601String();

  Chat copyWith({
    String? peerName,
    String? peerPhone,
    String? peerAbout,
    String? peerAvatarColor,
    String? peerAvatar,
    bool? isGroup,
    int? memberCount,
    DateTime? peerLastSeen,
    Presence? peerPresence,
    String? lastMessageText,
    DateTime? lastMessageAt,
    int? unreadCount,
    bool? archived,
    bool? pinned,
    bool? muted,
    DateTime? updatedAt,
  }) =>
      Chat(
        id: id,
        peerId: peerId,
        peerName: peerName ?? this.peerName,
        peerPhone: peerPhone ?? this.peerPhone,
        peerAbout: peerAbout ?? this.peerAbout,
        peerAvatarColor: peerAvatarColor ?? this.peerAvatarColor,
        peerAvatar: peerAvatar ?? this.peerAvatar,
        isGroup: isGroup ?? this.isGroup,
        memberCount: memberCount ?? this.memberCount,
        peerLastSeen: peerLastSeen ?? this.peerLastSeen,
        peerPresence: peerPresence ?? this.peerPresence,
        lastMessageText: lastMessageText ?? this.lastMessageText,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        unreadCount: unreadCount ?? this.unreadCount,
        archived: archived ?? this.archived,
        pinned: pinned ?? this.pinned,
        muted: muted ?? this.muted,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory Chat.fromUser(User user) => Chat(
        id: user.id,
        peerId: user.id,
        peerName: user.name,
        peerPhone: user.phone,
        peerAbout: user.about,
        peerAvatarColor: user.avatarColor,
        peerAvatar: user.avatar,
        peerLastSeen: user.lastSeen,
        peerPresence: user.presence,
        updatedAt: DateTime.now(),
      );

  factory Chat.group({
    required String id,
    required String title,
    String avatar = '',
    int memberCount = 0,
  }) =>
      Chat(
        id: id,
        peerId: id,
        peerName: title,
        peerAvatar: avatar,
        isGroup: true,
        memberCount: memberCount,
        updatedAt: DateTime.now(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'peer_id': peerId,
        'peer_name': peerName,
        'peer_phone': peerPhone,
        'peer_about': peerAbout,
        'peer_avatar_color': peerAvatarColor,
        'peer_avatar': peerAvatar,
        'is_group': isGroup ? 1 : 0,
        'member_count': memberCount,
        'peer_last_seen': peerLastSeen?.millisecondsSinceEpoch,
        'peer_presence': presenceToWire(peerPresence),
        'last_message_text': lastMessageText,
        'last_message_at': lastMessageAt?.millisecondsSinceEpoch,
        'unread_count': unreadCount,
        'archived': archived ? 1 : 0,
        'pinned': pinned ? 1 : 0,
        'muted': muted ? 1 : 0,
        'updated_at': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
      };

  factory Chat.fromRow(Map<String, Object?> row) => Chat(
        id: row['id'] as String,
        peerId: row['peer_id'] as String,
        peerName: (row['peer_name'] as String?) ?? '',
        peerPhone: (row['peer_phone'] as String?) ?? '',
        peerAbout: (row['peer_about'] as String?) ?? '',
        peerAvatarColor: (row['peer_avatar_color'] as String?) ?? '#1A9C7A',
        peerAvatar: (row['peer_avatar'] as String?) ?? '',
        isGroup: (row['is_group'] as num?)?.toInt() == 1,
        memberCount: (row['member_count'] as num?)?.toInt() ?? 0,
        peerLastSeen: row['peer_last_seen'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((row['peer_last_seen'] as num).toInt()),
        peerPresence: presenceFromWire(row['peer_presence'] as String?),
        lastMessageText: (row['last_message_text'] as String?) ?? '',
        lastMessageAt: row['last_message_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((row['last_message_at'] as num).toInt()),
        unreadCount: (row['unread_count'] as num?)?.toInt() ?? 0,
        archived: (row['archived'] as num?)?.toInt() == 1,
        pinned: (row['pinned'] as num?)?.toInt() == 1,
        muted: (row['muted'] as num?)?.toInt() == 1,
        updatedAt: row['updated_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((row['updated_at'] as num).toInt()),
      );
}

enum MessageKind { text, image, file, reaction, delete }

MessageKind messageKindFromWire(String? value) => switch (value) {
      'image' => MessageKind.image,
      'file' => MessageKind.file,
      'reaction' => MessageKind.reaction,
      'delete' => MessageKind.delete,
      _ => MessageKind.text,
    };

String messageKindToWire(MessageKind kind) => switch (kind) {
      MessageKind.text => 'text',
      MessageKind.image => 'image',
      MessageKind.file => 'file',
      MessageKind.reaction => 'reaction',
      MessageKind.delete => 'delete',
    };

enum MessageStatus { sending, sent, delivered, read, failed }

MessageStatus messageStatusFromWire(String? value) => switch (value) {
      'delivered' => MessageStatus.delivered,
      'read' => MessageStatus.read,
      'sending' => MessageStatus.sending,
      'failed' => MessageStatus.failed,
      _ => MessageStatus.sent,
    };

String messageStatusToWire(MessageStatus status) => status.name;

class Message {
  const Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    this.text = '',
    this.kind = MessageKind.text,
    this.status = MessageStatus.sending,
    required this.createdAt,
    this.deliveredAt,
    this.readAt,
    this.meta = const {},
    this.imageBase64,
    this.reactions = const {},
    this.archived = false,
    this.deleted = false,
  });

  final String id;
  final String chatId;
  final String senderId;
  final String text;
  final MessageKind kind;
  final MessageStatus status;
  final DateTime createdAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final Map<String, dynamic> meta;
  final String? imageBase64;
  final Map<String, List<String>> reactions;
  final bool archived;
  final bool deleted;

  bool isMine(String myId) => senderId == myId;
  bool get isImage => kind == MessageKind.image;
  bool get isFile => kind == MessageKind.file;
  bool get isControl => kind == MessageKind.reaction || kind == MessageKind.delete;

  Message copyWith({
    String? text,
    MessageKind? kind,
    MessageStatus? status,
    DateTime? deliveredAt,
    DateTime? readAt,
    Map<String, dynamic>? meta,
    String? imageBase64,
    Map<String, List<String>>? reactions,
    bool? archived,
    bool? deleted,
  }) =>
      Message(
        id: id,
        chatId: chatId,
        senderId: senderId,
        text: text ?? this.text,
        kind: kind ?? this.kind,
        status: status ?? this.status,
        createdAt: createdAt,
        deliveredAt: deliveredAt ?? this.deliveredAt,
        readAt: readAt ?? this.readAt,
        meta: meta ?? this.meta,
        imageBase64: imageBase64 ?? this.imageBase64,
        reactions: reactions ?? this.reactions,
        archived: archived ?? this.archived,
        deleted: deleted ?? this.deleted,
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'chat_id': chatId,
        'sender_id': senderId,
        'text': text,
        'kind': messageKindToWire(kind),
        'status': messageStatusToWire(status),
        'created_at': createdAt.millisecondsSinceEpoch,
        'delivered_at': deliveredAt?.millisecondsSinceEpoch,
        'read_at': readAt?.millisecondsSinceEpoch,
        'meta': jsonEncode(meta),
        'image_b64': imageBase64,
        'reactions': jsonEncode(reactions),
        'archived': archived ? 1 : 0,
        'deleted': deleted ? 1 : 0,
      };

  factory Message.fromRow(Map<String, Object?> row) {
    final reactionsRaw = row['reactions'] as String?;
    final reactions = <String, List<String>>{};
    if (reactionsRaw != null && reactionsRaw.isNotEmpty) {
      final decoded = jsonDecode(reactionsRaw) as Map<String, dynamic>;
      decoded.forEach((key, value) {
        reactions[key] = (value as List).cast<String>();
      });
    }
    return Message(
      id: row['id'] as String,
      chatId: row['chat_id'] as String,
      senderId: row['sender_id'] as String,
      text: (row['text'] as String?) ?? '',
      kind: messageKindFromWire(row['kind'] as String?),
      status: messageStatusFromWire(row['status'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch((row['created_at'] as num).toInt()),
      deliveredAt: row['delivered_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((row['delivered_at'] as num).toInt()),
      readAt: row['read_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((row['read_at'] as num).toInt()),
      meta: (row['meta'] as String?)?.isNotEmpty == true
          ? jsonDecode(row['meta'] as String) as Map<String, dynamic>
          : const {},
      imageBase64: row['image_b64'] as String?,
      reactions: reactions,
      archived: (row['archived'] as num?)?.toInt() == 1,
      deleted: (row['deleted'] as num?)?.toInt() == 1,
    );
  }
}

class Contact {
  const Contact({required this.user, required this.addedAt});
  final User user;
  final DateTime addedAt;
}

class GroupMember {
  const GroupMember({
    required this.id,
    required this.name,
    this.username = '',
    this.avatar = '',
    this.avatarColor = '#1A9C7A',
    this.role = 'member',
  });

  final String id;
  final String name;
  final String username;
  final String avatar;
  final String avatarColor;
  final String role;

  factory GroupMember.fromJson(Map<String, dynamic> json) => GroupMember(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '',
        username: (json['username'] as String?) ?? '',
        avatar: (json['avatar'] as String?) ?? '',
        avatarColor: (json['avatarColor'] as String?) ?? '#1A9C7A',
        role: (json['role'] as String?) ?? 'member',
      );
}

class Group {
  const Group({
    required this.id,
    required this.title,
    this.avatar = '',
    this.createdBy = '',
    this.members = const [],
  });

  final String id;
  final String title;
  final String avatar;
  final String createdBy;
  final List<GroupMember> members;

  factory Group.fromJson(Map<String, dynamic> json) {
    final raw = json['group'] as Map<String, dynamic>? ?? json;
    final members = (json['members'] as List?)
            ?.map((e) => GroupMember.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const <GroupMember>[];
    return Group(
      id: raw['id'] as String,
      title: (raw['title'] as String?) ?? '',
      avatar: (raw['avatar'] as String?) ?? '',
      createdBy: (raw['createdBy'] as String?) ?? '',
      members: members,
    );
  }
}

class AuthSession {
  const AuthSession({required this.token, required this.user, required this.isNew});
  final String token;
  final User user;
  final bool isNew;
}
