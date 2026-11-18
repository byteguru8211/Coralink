import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/utils.dart';
import '../../data/settings_store.dart';
import '../../network/call.dart';
import '../../services/audio_service.dart';
import '../../services/message_service.dart';
import '../controllers.dart';
import '../widgets/coral_widgets.dart';
import 'call_screen.dart';
import 'chats_screen.dart';
import 'contacts_screen.dart';
import 'settings_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  StreamSubscription<IncomingEvent>? _incomingSub;

  @override
  void initState() {
    super.initState();
    final client = ref.read(clientProvider);
    _incomingSub = client.messages.incoming.listen(_onIncoming);
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    super.dispose();
  }

  Future<void> _onIncoming(IncomingEvent event) async {
    if (!mounted || event.isActiveChat) return;
    final client = ref.read(clientProvider);
    final settings = ref.read(settingsProvider);
    final chat = await client.store.getChat(event.message.chatId);
    if (chat?.muted == true) return;
    if (settings.receiveSound) {
      await ref.read(audioProvider).play(NatureSound.splash, gain: 0.8);
    }
    if (settings.notificationMode != NotificationMode.offline) {
      final preview = event.message.isImage
          ? (settings.localeCode == 'en' ? 'Photo' : 'Фото')
          : event.message.text;
      await ref.read(notificationProvider).show(
            chatId: event.message.chatId,
            title: chat?.peerName ?? 'Coralink',
            body: truncate(preview, 140),
            mode: settings.notificationMode,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final unread = ref.watch(chatsProvider.select((state) => state.unread));
    final palette = context.palette;

    // Surface an incoming call over whatever screen is open.
    ref.listen<AsyncValue<CallStatus>>(callStatusProvider, (previous, next) {
      final status = next.value;
      final wasIncoming = previous?.value == CallStatus.incoming;
      if (status == CallStatus.incoming && !wasIncoming) {
        final peerId = ref.read(callProvider).peerId;
        if (peerId != null) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => CallScreen(peerId: peerId)),
          );
        }
      }
    });

    return Scaffold(
      body: CoralBackground(
        child: IndexedStack(
          index: _index,
          children: const [
            ChatsScreen(),
            ContactsScreen(),
            SettingsScreen(),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: palette.navBackground.withValues(alpha: 0.96),
          border: Border(top: BorderSide(color: palette.divider)),
        ),
        child: SafeArea(
          top: false,
          child: BottomNavigationBar(
            currentIndex: _index,
            onTap: (index) => setState(() => _index = index),
            items: [
              BottomNavigationBarItem(
                icon: _NavIcon(
                  icon: Icons.chat_bubble_outline_rounded,
                  active: _index == 0,
                  badge: unread > 0,
                ),
                activeIcon: _NavIcon(
                  icon: Icons.chat_bubble_rounded,
                  active: true,
                  badge: unread > 0,
                ),
                label: strings.get('chatsTab'),
              ),
              BottomNavigationBarItem(
                icon: _NavIcon(
                  icon: Icons.people_outline_rounded,
                  active: _index == 1,
                ),
                activeIcon: _NavIcon(icon: Icons.people_rounded, active: true),
                label: strings.get('contactsTab'),
              ),
              BottomNavigationBarItem(
                icon: _NavIcon(
                  icon: Icons.settings_outlined,
                  active: _index == 2,
                ),
                activeIcon: _NavIcon(icon: Icons.settings_rounded, active: true),
                label: strings.get('settingsTab'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  const _NavIcon({required this.icon, required this.active, this.badge = false});
  final IconData icon;
  final bool active;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: 24, color: active ? palette.accent : palette.textMuted),
        if (badge)
          Positioned(
            right: -3,
            top: -1,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: palette.accent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(color: palette.accent.withValues(alpha: 0.7), blurRadius: 6),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
