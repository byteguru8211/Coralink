import 'package:flutter/foundation.dart';

/// Minimal redacting logger. Never logs tokens, codes or message plaintext.
abstract final class Log {
  static const _sensitive = ['token', 'code', 'password', 'ciphertext'];

  static void d(String tag, String message) {
    if (kDebugMode) debugPrint('[$tag] ${_redact(message)}');
  }

  static void e(String tag, Object error, [StackTrace? stack]) {
    if (kDebugMode) {
      debugPrint('[$tag] ERROR ${_redact('$error')}');
      if (stack != null) debugPrint(stack.toString());
    }
  }

  static String _redact(String value) {
    var result = value;
    for (final key in _sensitive) {
      result = result.replaceAllMapped(
        RegExp('("$key"\\s*:\\s*)"[^"]*"', caseSensitive: false),
        (m) => '${m[1]}"***"',
      );
    }
    return result;
  }
}
