import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../data/settings_store.dart';
import '../../services/chat_exporter.dart';
import '../controllers.dart';
import '../widgets/coral_widgets.dart';
import 'privacy_policy_screen.dart';
import 'profile_screen.dart';
import 'settings_notifications_screen.dart';
import 'settings_privacy_screen.dart';
import 'settings_sounds_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(stringsProvider);
    final settings = ref.watch(settingsProvider);
    final user = ref.watch(sessionProvider).user;
    final palette = context.palette;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(strings.get('settingsTitle'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 110),
        children: [
          if (user != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                ),
                child: GlassPanel(
                  margin: EdgeInsets.zero,
                  child: Row(
                    children: [
                      SeedAvatar(
                        seedId: user.id,
                        name: user.name,
                        colorHex: user.avatarColor,
                        avatar: user.avatar,
                        online: true,
                        size: 62,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user.name,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              user.about.isEmpty ? user.phone : user.about,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textMuted,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        strings.get('edit'),
                        style: TextStyle(color: palette.accent, fontSize: 13),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: palette.accent,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          SectionHeader(strings.get('notificationsSection')),
          GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                SettingsTile(
                  icon: Icons.notifications_none_rounded,
                  title: strings.get('notificationsSection'),
                  subtitle: _notificationLabel(
                    strings,
                    settings.notificationMode,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SettingsNotificationsScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.music_note_rounded,
                  title: strings.get('soundsSection'),
                  subtitle: strings.get('soundsTitle'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SettingsSoundsScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (defaultTargetPlatform == TargetPlatform.windows) ...[
            SectionHeader(strings.get('desktopSection')),
            GlassPanel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  SwitchListTile(
                    value: settings.trayClose,
                    activeColor: palette.accent,
                    onChanged: (value) =>
                        ref.read(settingsProvider.notifier).setTrayClose(value),
                    secondary: Icon(
                      Icons.desktop_windows_outlined,
                      color: palette.accent,
                    ),
                    title: Text(
                      strings.get('trayClose'),
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 15,
                      ),
                    ),
                    subtitle: Text(
                      strings.get('trayCloseDesc'),
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          SectionHeader(strings.get('privacySection')),
          GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                SettingsTile(
                  icon: Icons.shield_outlined,
                  title: strings.get('privacyTitle'),
                  subtitle: strings.get('presenceNote'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SettingsPrivacyScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.language_rounded,
                  title: strings.get('language'),
                  subtitle: settings.localeCode == 'en'
                      ? strings.get('english')
                      : strings.get('russian'),
                  onTap: () => _chooseLanguage(context, ref, strings),
                ),
                SettingsTile(
                  icon: Icons.palette_outlined,
                  title: strings.get('theme'),
                  subtitle: _themeLabel(strings, settings.themeMode),
                  onTap: () => _chooseTheme(context, ref, strings),
                ),
              ],
            ),
          ),
          SectionHeader(strings.get('dataSection')),
          GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                SettingsTile(
                  icon: Icons.cleaning_services_outlined,
                  title: strings.get('clearCache'),
                  onTap: () => _clearCache(context, ref, strings),
                ),
                SettingsTile(
                  icon: Icons.file_download_outlined,
                  title: strings.get('exportChats'),
                  onTap: () => _exportChats(context, ref, strings),
                ),
                SettingsTile(
                  icon: Icons.link_rounded,
                  title: strings.get('serverLink'),
                  subtitle: settings.serverUrl.isEmpty
                      ? strings.get('serverLinkNote')
                      : settings.serverUrl,
                  onTap: () =>
                      _editServerUrl(context, ref, strings, settings.serverUrl),
                ),
              ],
            ),
          ),
          SectionHeader(strings.get('aboutSection')),
          GlassPanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                SettingsTile(
                  icon: Icons.info_outline_rounded,
                  title: strings.get('appVersion'),
                  trailing: Text(
                    '1.0.0',
                    style: TextStyle(color: palette.textMuted, fontSize: 13),
                  ),
                ),
                SettingsTile(
                  icon: Icons.privacy_tip_outlined,
                  title: strings.get('privacyPolicy'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PrivacyPolicyScreen(),
                    ),
                  ),
                ),
                SettingsTile(
                  icon: Icons.mail_outline_rounded,
                  title: strings.get('support'),
                  subtitle: 'support@coralink.app',
                  onTap: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: 'support@coralink.app'),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(strings.get('copied'))),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassPanel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SettingsTile(
                icon: Icons.logout_rounded,
                title: strings.get('logout'),
                danger: true,
                onTap: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: palette.surface,
                      title: Text(strings.get('logout')),
                      content: Text(strings.get('logoutConfirm')),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(strings.get('cancel')),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(
                            strings.get('logout'),
                            style: TextStyle(color: palette.coral),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await ref.read(sessionProvider.notifier).logout();
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 26),
          Center(
            child: Column(
              children: [
                const CoralMark(size: 34),
                const SizedBox(height: 8),
                Text(
                  'Coralink 1.0 · ${strings.get('slogan')}',
                  style: TextStyle(
                    color: palette.textMuted,
                    fontSize: 10.5,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  String _notificationLabel(AppStrings strings, NotificationMode mode) =>
      switch (mode) {
        NotificationMode.minimal => strings.get('notifMinimal'),
        NotificationMode.medium => strings.get('notifMedium'),
        NotificationMode.offline => strings.get('notifOffline'),
      };

  String _themeLabel(AppStrings strings, ThemeMode mode) => switch (mode) {
    ThemeMode.dark => strings.get('themeDark'),
    ThemeMode.light => strings.get('themeLight'),
    ThemeMode.system => strings.get('themeSystem'),
  };

  Future<void> _chooseTheme(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
  ) async {
    final settings = ref.read(settingsProvider);
    final palette = context.palette;
    final choice = await showModalBottomSheet<ThemeMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in ThemeMode.values)
              SettingsTile(
                icon: switch (mode) {
                  ThemeMode.dark => Icons.dark_mode_outlined,
                  ThemeMode.light => Icons.light_mode_outlined,
                  ThemeMode.system => Icons.brightness_auto_outlined,
                },
                title: _themeLabel(strings, mode),
                trailing: settings.themeMode == mode
                    ? Icon(Icons.check_rounded, color: palette.accent)
                    : null,
                onTap: () => Navigator.pop(context, mode),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setTheme(choice);
    }
  }

  Future<void> _chooseLanguage(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
  ) async {
    final settings = ref.read(settingsProvider);
    final palette = context.palette;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsTile(
              icon: Icons.translate_rounded,
              title: strings.get('russian'),
              trailing: settings.localeCode == 'ru'
                  ? Icon(Icons.check_rounded, color: palette.accent)
                  : null,
              onTap: () => Navigator.pop(context, 'ru'),
            ),
            SettingsTile(
              icon: Icons.translate_rounded,
              title: strings.get('english'),
              trailing: settings.localeCode == 'en'
                  ? Icon(Icons.check_rounded, color: palette.accent)
                  : null,
              onTap: () => Navigator.pop(context, 'en'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null) {
      await ref.read(settingsProvider.notifier).setLocale(choice);
    }
  }

  Future<void> _clearCache(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
  ) async {
    final palette = context.palette;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(strings.get('clearCache')),
        content: Text(strings.get('clearCacheConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              strings.get('clearCache'),
              style: TextStyle(color: palette.coral),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final client = ref.read(clientProvider);
    final chats = await client.store.getChats(includeArchived: true);
    for (final chat in chats) {
      await client.store.deleteMessages(chat.id);
    }
    await ref.read(chatsProvider.notifier).refresh();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.get('cleared'))));
  }

  Future<void> _exportChats(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
  ) async {
    final user = ref.read(sessionProvider).user;
    if (user == null) return;
    final path = await exportChats(ref.read(clientProvider).store, user.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path == null
              ? strings.get('exportUnsupported')
              : '${strings.get('exportPath')} $path',
        ),
      ),
    );
  }

  Future<void> _editServerUrl(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
    String current,
  ) async {
    final palette = context.palette;
    final controller = TextEditingController(text: current);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: palette.surface,
        title: Text(strings.get('serverLink')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            hintText: 'https://host.tailnet.ts.net',
            helperText: strings.get('serverLinkNote'),
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.get('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.get('save')),
          ),
        ],
      ),
    );
    final value = controller.text.trim();
    controller.dispose();
    if (saved != true || value.isEmpty || value == current) return;
    await ref.read(settingsProvider.notifier).setServerUrl(value);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.get('serverLinkSaved'))));
  }
}
