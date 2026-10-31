import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../core/app_colors.dart';
import '../widgets/coral_widgets.dart';

class ErrorScreen extends ConsumerWidget {
  const ErrorScreen({
    super.key,
    required this.message,
    required this.onRetry,
    required this.onSignOut,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    return Scaffold(
      body: CoralBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.cloud_off_rounded, size: 56, color: palette.coral),
                const SizedBox(height: 22),
                Text(
                  strings.get('connectionLost'),
                  style: TextStyle(color: palette.textPrimary, fontSize: 22, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.textMuted, fontSize: 13.5, height: 1.4),
                ),
                const SizedBox(height: 28),
                FilledButton(onPressed: onRetry, child: Text(strings.get('retry'))),
                const SizedBox(height: 8),
                TextButton(onPressed: onSignOut, child: Text(strings.get('logout'))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
