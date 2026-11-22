import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../core/app_colors.dart';
import '../../data/settings_store.dart';
import '../widgets/coral_widgets.dart';

class SettingsNotificationsScreen extends ConsumerWidget {
  const SettingsNotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final settings = ref.watch(settingsProvider);
    final palette = context.palette;

    final options = [
      (
        NotificationMode.minimal,
        Icons.volume_mute_rounded,
        strings.get('notifMinimal'),
        strings.get('notifMinimalDesc'),
      ),
      (
        NotificationMode.medium,
        Icons.eco_outlined,
        strings.get('notifMedium'),
        strings.get('notifMediumDesc'),
      ),
      (
        NotificationMode.advanced,
        Icons.auto_awesome_rounded,
        strings.get('notifAdvanced'),
        strings.get('notifAdvancedDesc'),
      ),
      (
        NotificationMode.offline,
        Icons.nightlight_outlined,
        strings.get('notifOffline'),
        strings.get('notifOfflineDesc'),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(strings.get('notificationsSection'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
            child: Text(
              strings.get('notificationTitle'),
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
          for (final option in options)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () async {
                  final granted = option.$1 == NotificationMode.offline
                      ? true
                      : await ref.read(notificationProvider).requestPermission();
                  await ref
                      .read(settingsProvider.notifier)
                      .setNotificationMode(option.$1);
                  if (!granted && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(strings.get('notificationsDenied'))),
                    );
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: settings.notificationMode == option.$1
                        ? palette.accent.withValues(alpha: 0.12)
                        : palette.surface.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: settings.notificationMode == option.$1
                          ? palette.accent.withValues(alpha: 0.6)
                          : palette.divider,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: palette.accent.withValues(alpha: 0.12),
                        ),
                        child: Icon(option.$2, color: palette.accent, size: 21),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              option.$3,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              option.$4,
                              style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                            ),
                          ],
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: settings.notificationMode == option.$1
                                ? palette.accent
                                : palette.textMuted,
                            width: 2,
                          ),
                        ),
                        child: settings.notificationMode == option.$1
                            ? Center(
                                child: Container(
                                  width: 11,
                                  height: 11,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: palette.accent,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (defaultTargetPlatform == TargetPlatform.android) ...[
            const SizedBox(height: 20),
            GlassPanel(
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SwitchListTile(
                value: settings.backgroundAlive,
                activeColor: palette.accent,
                onChanged: (value) =>
                    ref.read(settingsProvider.notifier).setBackgroundAlive(value),
                secondary: Icon(Icons.nightlight_round, color: palette.accent),
                title: Text(
                  strings.get('backgroundAlive'),
                  style: TextStyle(color: palette.textPrimary, fontSize: 15),
                ),
                subtitle: Text(
                  strings.get('backgroundAliveDesc'),
                  style: TextStyle(color: palette.textMuted, fontSize: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 14, color: palette.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  strings.get('notifHint'),
                  style: TextStyle(color: palette.textMuted, fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
