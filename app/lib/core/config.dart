import 'package:flutter/foundation.dart';

/// Runtime configuration. All values can be overridden at build time:
/// `flutter build apk --dart-define=API_URL=https://coralink.example.com`
class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.wsUrl,
    required this.devMode,
    required this.stunUrl,
    this.turnUrl,
    this.turnUsername,
    this.turnCredential,
  });

  final String apiBaseUrl;
  final String wsUrl;
  final bool devMode;
  final String stunUrl;
  final String? turnUrl;
  final String? turnUsername;
  final String? turnCredential;

  factory AppConfig.resolve() {
    const apiOverride = String.fromEnvironment('API_URL');
    const wsOverride = String.fromEnvironment('WS_URL');
    const devMode = bool.fromEnvironment('DEV_MODE', defaultValue: true);
    const stun = String.fromEnvironment(
      'STUN_URL',
      defaultValue: 'stun:stun.l.google.com:19302',
    );
    const turn = String.fromEnvironment('TURN_URL');
    const turnUser = String.fromEnvironment('TURN_USERNAME');
    const turnPass = String.fromEnvironment('TURN_CREDENTIAL');

    var base = apiOverride;
    if (base.isEmpty) {
      if (kIsWeb) {
        base = 'http://127.0.0.1:8080';
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        // Android emulator reaches the host loopback through 10.0.2.2.
        base = 'http://10.0.2.2:8080';
      } else {
        base = 'http://127.0.0.1:8080';
      }
    }
    base = base.replaceAll(RegExp(r'/+$'), '');

    var ws = wsOverride;
    if (ws.isEmpty) {
      ws = base.replaceFirst('http', 'ws') + '/ws';
    }

    return AppConfig(
      apiBaseUrl: base,
      wsUrl: ws,
      devMode: devMode,
      stunUrl: stun,
      turnUrl: turn.isEmpty ? null : turn,
      turnUsername: turnUser.isEmpty ? null : turnUser,
      turnCredential: turnPass.isEmpty ? null : turnPass,
    );
  }

  bool get supportsSecureStorage => !kIsWeb;
}
