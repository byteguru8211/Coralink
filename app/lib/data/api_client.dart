import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/log.dart';
import '../domain/models.dart';
import '../domain/pet.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.code, this.message);
  final int statusCode;
  final String code;
  final String message;

  bool get isUnauthorized => statusCode == 401;
  bool get isRateLimited => statusCode == 429;
  bool get isNetwork => statusCode == 0;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

class KeyBundleDto {
  const KeyBundleDto({
    required this.userId,
    required this.identityKey,
    required this.registrationId,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.preKeyId,
    this.preKey,
  });

  final String userId;
  final String identityKey;
  final int registrationId;
  final int signedPreKeyId;
  final String signedPreKey;
  final String signedPreKeySignature;
  final int? preKeyId;
  final String? preKey;

  factory KeyBundleDto.fromJson(Map<String, dynamic> json) {
    final signed = json['signedPreKey'] as Map<String, dynamic>;
    final oneTime = json['preKey'] as Map<String, dynamic>?;
    return KeyBundleDto(
      userId: json['userId'] as String,
      identityKey: json['identityKey'] as String,
      registrationId: (json['registrationId'] as num).toInt(),
      signedPreKeyId: (signed['id'] as num).toInt(),
      signedPreKey: signed['publicKey'] as String,
      signedPreKeySignature: signed['signature'] as String,
      preKeyId: oneTime == null ? null : (oneTime['id'] as num).toInt(),
      preKey: oneTime?['publicKey'] as String?,
    );
  }
}

class IncomingMessageDto {
  const IncomingMessageDto({
    required this.id,
    required this.senderId,
    required this.ciphertext,
    required this.kind,
    required this.meta,
    required this.createdAt,
    this.groupId,
  });

  final String id;
  final String senderId;
  final String ciphertext;
  final String kind;
  final Map<String, dynamic> meta;
  final DateTime createdAt;
  final String? groupId;

  factory IncomingMessageDto.fromJson(Map<String, dynamic> json) =>
      IncomingMessageDto(
        id: json['id'] as String,
        senderId: (json['senderId'] ?? json['from']) as String,
        ciphertext: json['ciphertext'] as String,
        kind: (json['kind'] as String?) ?? 'text',
        meta: (json['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['createdAt'] as num?) ?? 0).toInt(),
        ),
        groupId: json['groupId'] as String?,
      );
}

class PresenceInfo {
  const PresenceInfo({required this.online, this.lastSeen});
  final bool online;
  final DateTime? lastSeen;
}

class ApiClient {
  ApiClient({required this.baseUrl, String? token, http.Client? client})
    : _token = token,
      _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  String? _token;

  String? get token => _token;
  set token(String? value) => _token = value;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl/api/v1$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool auth = true,
  }) async {
    if (auth && _token == null) {
      throw ApiException(401, 'unauthorized', 'No token');
    }
    try {
      final request = http.Request(method, _uri(path, query))
        ..headers.addAll(_headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      final response = await http.Response.fromStream(streamed);
      final decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return decoded;
      }
      final error = decoded['error'] as Map<String, dynamic>?;
      throw ApiException(
        response.statusCode,
        (error?['code'] as String?) ?? 'http_error',
        (error?['message'] as String?) ??
            'Request failed (${response.statusCode})',
      );
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(0, 'timeout', 'Request timed out');
    } on http.ClientException {
      throw ApiException(0, 'network', 'Network unavailable');
    } catch (error) {
      Log.e('api', error);
      throw ApiException(0, 'network', 'Network error');
    }
  }

  Future<AuthSession> register(
    String username, {
    required String password,
    String? name,
  }) async {
    final json = await _send(
      'POST',
      '/auth/register',
      body: {
        'username': username,
        'password': password,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      },
      auth: false,
    );
    final token = json['token'] as String;
    _token = token;
    return AuthSession(
      token: token,
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      isNew: json['isNew'] == true,
    );
  }

  Future<AuthSession> login(String username, String password) async {
    final json = await _send(
      'POST',
      '/auth/login',
      body: {'username': username, 'password': password},
      auth: false,
    );
    final token = json['token'] as String;
    _token = token;
    return AuthSession(
      token: token,
      user: User.fromJson(json['user'] as Map<String, dynamic>),
      isNew: json['isNew'] == true,
    );
  }

  Future<User> me() async => User.fromJson(
    (await _send('GET', '/me'))['user'] as Map<String, dynamic>,
  );

  Future<User> updateProfile({
    String? name,
    String? about,
    String? avatarColor,
    String? avatar,
    String? presenceVisibility,
  }) async {
    final json = await _send(
      'PATCH',
      '/me',
      body: {
        if (name != null) 'name': name,
        if (about != null) 'about': about,
        if (avatarColor != null) 'avatarColor': avatarColor,
        if (avatar != null) 'avatar': avatar,
        if (presenceVisibility != null)
          'presenceVisibility': presenceVisibility,
      },
    );
    return User.fromJson(json['user'] as Map<String, dynamic>);
  }

  Future<List<User>> searchUsers(String query) async {
    final json = await _send('GET', '/users/search', query: {'q': query});
    return (json['users'] as List)
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<User> getUser(String id) async => User.fromJson(
    (await _send('GET', '/users/$id'))['user'] as Map<String, dynamic>,
  );

  Future<List<User>> contacts() async {
    final json = await _send('GET', '/contacts');
    return (json['contacts'] as List)
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<User> addContact(String userId) async {
    final json = await _send('POST', '/contacts', body: {'userId': userId});
    return User.fromJson(json['contact'] as Map<String, dynamic>);
  }

  Future<void> removeContact(String userId) =>
      _send('DELETE', '/contacts/$userId');

  Future<Group> createGroup({
    required String title,
    List<String> memberIds = const [],
    String avatar = '',
  }) async {
    final json = await _send(
      'POST',
      '/groups',
      body: {'title': title, 'members': memberIds, 'avatar': avatar},
    );
    return Group.fromJson(json);
  }

  Future<List<Group>> myGroups() async {
    final json = await _send('GET', '/groups');
    return (json['groups'] as List)
        .map((e) => Group.fromJson({'group': e}))
        .toList();
  }

  Future<Group> groupDetail(String groupId) async {
    final json = await _send('GET', '/groups/$groupId');
    return Group.fromJson(json);
  }

  Future<List<GroupMember>> addGroupMember(
    String groupId,
    String userId,
  ) async {
    final json = await _send(
      'POST',
      '/groups/$groupId/members',
      body: {'userId': userId},
    );
    return (json['members'] as List)
        .map((e) => GroupMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> leaveGroup(String groupId, String userId) =>
      _send('DELETE', '/groups/$groupId/members/$userId');

  Future<Group> updateGroup(
    String groupId, {
    String? title,
    String? avatar,
  }) async {
    final json = await _send(
      'PATCH',
      '/groups/$groupId',
      body: {
        if (title != null) 'title': title,
        if (avatar != null) 'avatar': avatar,
      },
    );
    return Group.fromJson(json);
  }

  Future<List<IncomingMessageDto>> pendingGroupMessages() async {
    final json = await _send('GET', '/groups/queued');
    return (json['messages'] as List)
        .map((e) => IncomingMessageDto.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> ackGroupMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    await _send('POST', '/groups/ack', body: {'ids': ids});
  }

  Future<void> uploadKeys({
    required String identityKey,
    required int registrationId,
    required int signedPreKeyId,
    required String signedPreKey,
    required String signedPreKeySignature,
    required List<({int id, String publicKey})> preKeys,
  }) => _send(
    'POST',
    '/keys',
    body: {
      'identityKey': identityKey,
      'registrationId': registrationId,
      'signedPreKey': {
        'id': signedPreKeyId,
        'publicKey': signedPreKey,
        'signature': signedPreKeySignature,
      },
      'preKeys': [
        for (final key in preKeys) {'id': key.id, 'publicKey': key.publicKey},
      ],
    },
  );

  Future<void> replenishPreKeys(List<({int id, String publicKey})> preKeys) =>
      _send(
        'POST',
        '/keys/prekeys',
        body: {
          'preKeys': [
            for (final key in preKeys)
              {'id': key.id, 'publicKey': key.publicKey},
          ],
        },
      );

  Future<KeyBundleDto> fetchKeyBundle(String userId) async =>
      KeyBundleDto.fromJson(await _send('GET', '/keys/$userId'));

  Future<int> preKeyCount() async {
    final json = await _send('GET', '/keys/status');
    return (json['count'] as num).toInt();
  }

  Future<({String identityKey, int registrationId, int signedPreKeyId})>
  fetchKeyInfo(String userId) async {
    final json = await _send('GET', '/keys/$userId/info');
    return (
      identityKey: json['identityKey'] as String,
      registrationId: (json['registrationId'] as num).toInt(),
      signedPreKeyId: (json['signedPreKeyId'] as num).toInt(),
    );
  }

  Future<void> uploadBackup({
    required String blob,
    required String salt,
    required int revision,
  }) => _send(
    'PUT',
    '/backup',
    body: {'blob': blob, 'salt': salt, 'revision': revision},
  );

  /// Returns the stored encrypted backup, or null when none exists yet.
  Future<({String blob, String salt, int revision})?> fetchBackup() async {
    try {
      final json = await _send('GET', '/backup');
      return (
        blob: json['blob'] as String,
        salt: json['salt'] as String,
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );
    } on ApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<List<IncomingMessageDto>> queuedMessages() async {
    final json = await _send('GET', '/messages/queued');
    return (json['messages'] as List)
        .map((e) => IncomingMessageDto.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> ackMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    await _send('POST', '/messages/ack', body: {'ids': ids});
  }

  Future<void> markMessagesRead(String chatWith, List<String> ids) async {
    if (ids.isEmpty) return;
    await _send(
      'POST',
      '/messages/read',
      body: {'chatWith': chatWith, 'ids': ids},
    );
  }

  Future<Map<String, String>> messageStatuses(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final json = await _send('POST', '/messages/status', body: {'ids': ids});
    final raw = (json['statuses'] as List?) ?? const [];
    return {
      for (final item in raw)
        if (item is Map && item['id'] is String && item['status'] is String)
          item['id'] as String: item['status'] as String,
    };
  }

  Future<void> markGroupMessagesRead(String groupId, List<String> ids) async {
    if (ids.isEmpty) return;
    await _send('POST', '/groups/read', body: {'groupId': groupId, 'ids': ids});
  }

  Future<Map<String, PresenceInfo>> presence(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final json = await _send('GET', '/presence', query: {'ids': ids.join(',')});
    final raw = (json['presence'] as Map).cast<String, dynamic>();
    return raw.map((key, value) {
      final item = value as Map<String, dynamic>;
      return MapEntry(
        key,
        PresenceInfo(
          online: item['online'] == true,
          lastSeen: item['lastSeen'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (item['lastSeen'] as num).toInt(),
                ),
        ),
      );
    });
  }

  Future<List<PetRecord>> pets() async {
    final json = await _send('GET', '/pets');
    return ((json['pets'] as List?) ?? const [])
        .whereType<Map>()
        .map((pet) => PetRecord.fromJson(pet.cast<String, dynamic>()))
        .toList();
  }

  Future<PetRecord> createPet({
    required String petId,
    required PetScope scope,
    required String snapshot,
    String? peerId,
    String? groupId,
  }) async {
    final json = await _send(
      'POST',
      '/pets',
      body: {
        'scope': scope.name,
        'id': petId,
        'snapshot': snapshot,
        if (peerId != null) 'peerId': peerId,
        if (groupId != null) 'groupId': groupId,
      },
    );
    return PetRecord.fromJson((json['pet'] as Map).cast<String, dynamic>());
  }

  Future<({PetRecord pet, List<PetOperation> operations, bool hasMore})>
  petDetail(String petId, {int afterSeq = 0}) async {
    final json = await _send(
      'GET',
      '/pets/$petId',
      query: {'afterSeq': '$afterSeq'},
    );
    return (
      pet: PetRecord.fromJson((json['pet'] as Map).cast<String, dynamic>()),
      operations: ((json['pet']['operations'] as List?) ?? const [])
          .whereType<Map>()
          .map(
            (operation) =>
                PetOperation.fromJson(operation.cast<String, dynamic>()),
          )
          .toList(),
      hasMore: json['pet']['hasMoreOperations'] == true,
    );
  }

  Future<PetOperation> sendPetOperation({
    required String petId,
    required String operationId,
    required String action,
    required String payload,
  }) async {
    final json = await _send(
      'POST',
      '/pets/$petId/operations',
      body: {'id': operationId, 'action': action, 'payload': payload},
    );
    return PetOperation.fromJson(
      (json['operation'] as Map).cast<String, dynamic>(),
    );
  }

  Future<void> savePetSnapshot({
    required String petId,
    required int seq,
    required String snapshot,
  }) async {
    await _send(
      'PUT',
      '/pets/$petId/snapshot',
      body: {'seq': seq, 'snapshot': snapshot},
    );
  }

  Future<void> acceptPet(String petId) async =>
      _send('POST', '/pets/$petId/accept');
  Future<void> declinePet(String petId) async =>
      _send('POST', '/pets/$petId/decline');
  Future<void> releasePet(String petId) async =>
      _send('POST', '/pets/$petId/release');

  Future<void> registerPush(String token, String platform) => _send(
    'POST',
    '/push/register',
    body: {'token': token, 'platform': platform},
  );

  Future<void> deleteAccount() => _send('DELETE', '/me');

  Future<void> health() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        throw ApiException(response.statusCode, 'health', 'Server unhealthy');
      }
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(0, 'network', 'Server unreachable');
    }
  }

  void close() => _client.close();
}
