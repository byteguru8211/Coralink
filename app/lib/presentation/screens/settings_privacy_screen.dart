import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../data/api_client.dart';
import '../../data/settings_store.dart';
import '../widgets/coral_widgets.dart';

class SettingsPrivacyScreen extends ConsumerWidget {
  const SettingsPrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final settings = ref.watch(settingsProvider);
    final palette = context.palette;

    final scopes = [
      (PrivacyScope.everyone, strings.get('privacyEveryone')),
      (PrivacyScope.contacts, strings.get('privacyContacts')),
      (PrivacyScope.nobody, strings.get('privacyNobody')),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(strings.get('privacyTitle'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text(
              strings.get('privacyWhoSees'),
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          GlassPanel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                for (final scope in scopes)
                  SettingsTile(
                    icon: switch (scope.$1) {
                      PrivacyScope.everyone => Icons.public_rounded,
                      PrivacyScope.contacts => Icons.people_outline_rounded,
                      PrivacyScope.nobody => Icons.visibility_off_outlined,
                    },
                    title: scope.$2,
                    trailing: settings.privacyScope == scope.$1
                        ? Icon(Icons.check_rounded, color: palette.accent)
                        : null,
                    onTap: () async {
                      await ref.read(settingsProvider.notifier).setPrivacy(scope.$1);
                      try {
                        await ref
                            .read(clientProvider)
                            .api
                            .updateProfile(presenceVisibility: scope.$1.name);
                      } catch (_) {
                        // Offline: applied locally and synced on next launch.
                      }
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 14, color: palette.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.get('presenceNote'),
                    style: TextStyle(color: palette.textMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          GlassPanel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                SettingsTile(
                  icon: Icons.block_rounded,
                  title: strings.get('blocked'),
                  subtitle: strings.get('blockedEmpty'),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: palette.surface,
                      title: Text(strings.get('blocked')),
                      content: Text(strings.get('blockedEmpty')),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(strings.get('cancel')),
                        ),
                      ],
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.visibility_off_outlined,
                  title: strings.get('presenceOnlyContacts'),
                  subtitle: strings.get('privacyContacts'),
                  onTap: () => ref
                      .read(settingsProvider.notifier)
                      .setPrivacy(PrivacyScope.contacts),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          GlassPanel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SettingsTile(
              icon: Icons.delete_forever_outlined,
              title: strings.get('deleteAccount'),
              subtitle: strings.get('deleteAccountConfirm'),
              danger: true,
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: palette.surface,
                    title: Text(strings.get('deleteAccount')),
                    content: Text(strings.get('deleteAccountConfirm')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(strings.get('cancel')),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(
                          strings.get('delete'),
                          style: TextStyle(color: palette.coral),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                try {
                  await ref.read(sessionProvider.notifier).deleteAccount();
                } on ApiException catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(error.message)),
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
