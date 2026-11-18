import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../data/api_client.dart';
import '../domain/models.dart';
import '../network/call.dart';
import '../network/realtime.dart';
import '../services/keep_alive.dart';
import 'client_bundle.dart';
import 'dependencies.dart';

enum SessionStatus { booting, unauthenticated, onboarding, authenticated, error }

class SessionState {
  const SessionState({
    required this.status,
    this.user,
    this.client,
    this.pendingToken,
    this.message,
  });

  final SessionStatus status;
  final User? user;
  final ClientBundle? client;
  final String? pendingToken;
  final String? message;

  bool get isAuthenticated =>
      status == SessionStatus.authenticated && client != null;
}

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() {
    Future.microtask(_restore);
    return const SessionState(status: SessionStatus.booting);
  }

  Future<void> _restore() async {
    final secure = ref.read(secureStoreProvider);
    final store = ref.read(localStoreProvider);
    final config = ref.read(effectiveConfigProvider);
    final token = await secure.token;
    if (token == null || token.isEmpty) {
      state = const SessionState(status: SessionStatus.unauthenticated);
      return;
    }
    final userId = _jwtSubject(token);
    final cached = userId == null ? null : await store.getUser(userId);
    final api = ApiClient(baseUrl: config.apiBaseUrl, token: token);
    try {
      final user = await api.me();
      api.close();
      await store.upsertUser(user);
      await secure.setToken(token);
      await _activate(user, token);
    } on ApiException catch (error) {
      api.close();
      if (error.isUnauthorized) {
        await secure.setToken(null);
        state = const SessionState(status: SessionStatus.unauthenticated);
        return;
      }
      if (cached != null) {
        // Offline start is a first-class scenario: history is local.
        await _activate(cached, token);
      } else {
        state = SessionState(
          status: SessionStatus.error,
          message: error.message,
          pendingToken: token,
        );
      }
    } catch (error) {
      api.close();
      if (cached != null) {
        await _activate(cached, token);
      } else {
        state = SessionState(
          status: SessionStatus.error,
          message: '$error',
          pendingToken: token,
        );
      }
    }
  }

  Future<void> retryRestore() async {
    state = const SessionState(status: SessionStatus.booting);
    await _restore();
  }

  Future<void> register(
    String username, {
    required String password,
    String? name,
  }) async {
    final api = ApiClient(baseUrl: ref.read(effectiveConfigProvider).apiBaseUrl);
    try {
      final auth = await api.register(username, password: password, name: name);
      await ref.read(secureStoreProvider).setToken(auth.token);
      await ref.read(localStoreProvider).upsertUser(auth.user);
      if (auth.isNew) {
        state = SessionState(
          status: SessionStatus.onboarding,
          user: auth.user,
          pendingToken: auth.token,
        );
      } else {
        await _activate(auth.user, auth.token);
      }
    } finally {
      api.close();
    }
  }

  Future<void> login(String username, String password) async {
    final api = ApiClient(baseUrl: ref.read(effectiveConfigProvider).apiBaseUrl);
    try {
      final auth = await api.login(username, password);
      await ref.read(secureStoreProvider).setToken(auth.token);
      await ref.read(localStoreProvider).upsertUser(auth.user);
      await _activate(auth.user, auth.token);
    } finally {
      api.close();
    }
  }

  Future<void> completeProfile(String name, String about, String avatarColor) async {
    final token = state.pendingToken;
    if (token == null) throw StateError('No pending session');
    final api = ApiClient(
      baseUrl: ref.read(effectiveConfigProvider).apiBaseUrl,
      token: token,
    );
    try {
      final user = await api.updateProfile(
        name: name,
        about: about,
        avatarColor: avatarColor,
      );
      await ref.read(localStoreProvider).upsertUser(user);
      await _activate(user, token);
    } finally {
      api.close();
    }
  }

  Future<User> saveProfile({
    required String name,
    required String about,
    required String avatarColor,
    String? avatar,
  }) async {
    final client = state.client;
    if (client == null) throw StateError('No active client');
    final user = await client.api.updateProfile(
      name: name,
      about: about,
      avatarColor: avatarColor,
      avatar: avatar,
    );
    await client.store.upsertUser(user);
    state = SessionState(
      status: SessionStatus.authenticated,
      user: user,
      client: client,
      pendingToken: state.pendingToken,
    );
    return user;
  }

  Future<void> refreshProfile() async {
    final client = state.client;
    final token = state.pendingToken ?? await ref.read(secureStoreProvider).token;
    if (client == null || token == null) return;
    final user = await client.api.me();
    await client.store.upsertUser(user);
    state = SessionState(
      status: SessionStatus.authenticated,
      user: user,
      client: client,
    );
  }

  Future<void> _activate(User user, String token) async {
    await state.client?.dispose();
    final bundle = await ClientBundle.create(
      config: ref.read(effectiveConfigProvider),
      secure: ref.read(secureStoreProvider),
      store: ref.read(localStoreProvider),
      token: token,
      user: user,
      archiveDays: ref.read(settingsProvider).autoArchiveDays,
      presenceScope: ref.read(settingsProvider).privacyScope.name,
    );
    state = SessionState(
      status: SessionStatus.authenticated,
      user: user,
      client: bundle,
      pendingToken: token,
    );
    unawaited(startKeepAlive());
  }

  Future<void> deleteAccount() async {
    final client = state.client;
    final user = state.user;
    if (client == null) return;
    await client.api.deleteAccount();
    if (user != null) {
      await ref.read(secureStoreProvider).clearSignalState(user.id);
    }
    await logout();
  }

  Future<void> logout() async {
    final client = state.client;
    if (client != null) {
      await client.dispose();
    }
    final secure = ref.read(secureStoreProvider);
    await secure.setToken(null);
    // Signal identity stays in secure storage so a re-login on this device
    // keeps the same safety number and existing sessions.
    await ref.read(localStoreProvider).clearUserData();
    ref.read(audioProvider).stopRustle();
    await ref.read(notificationProvider).cancelAll();
    await stopKeepAlive();
    state = const SessionState(status: SessionStatus.unauthenticated);
  }

  void setPresence(String status) {
    state.client?.realtime.setPresence(status);
  }

  String? _jwtSubject(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (payload.length % 4 != 0) {
        payload += '=';
      }
      final decoded = jsonDecode(utf8.decode(base64Decode(payload))) as Map<String, dynamic>;
      return decoded['sub'] as String?;
    } catch (error) {
      Log.d('session', 'Bad JWT: $error');
      return null;
    }
  }
}

final sessionProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);

final clientProvider = Provider<ClientBundle>((ref) {
  final session = ref.watch(sessionProvider);
  final client = session.client;
  if (client == null) throw StateError('No authenticated client');
  return client;
});

final realtimeStatusProvider = StreamProvider<RealtimeStatus>((ref) {
  final client = ref.watch(clientProvider);
  return client.realtime.statuses;
});

final callProvider = Provider<CallService>((ref) {
  return ref.watch(clientProvider).call;
});

final callStatusProvider = StreamProvider<CallStatus>((ref) {
  return ref.watch(callProvider).changes;
});
