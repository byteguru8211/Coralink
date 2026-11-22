import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app.dart';
import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/utils.dart';
import '../../data/settings_store.dart';
import '../../domain/models.dart';
import '../../network/call.dart';
import '../../services/audio_service.dart';
import '../../services/message_service.dart';
import '../controllers.dart';
import '../widgets/coral_widgets.dart';
import 'call_screen.dart';
import 'chat_screen.dart';
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
  StreamSubscription<GroupAddedEvent>? _groupSub;

  @override
  void initState() {
    super.initState();
    final client = ref.read(clientProvider);
    _incomingSub = client.messages.incoming.listen(_onIncoming);
    _groupSub = client.messages.groupEvents.listen(_onGroupAdded);
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _groupSub?.cancel();
    super.dispose();
  }

  bool get _inForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// True while a call owns the screen: the in-app banner floats above the
  /// call controls, so it must never be shown during one.
  bool get _inCall {
    final status = ref.read(callStatusProvider).value;
    return status == CallStatus.incoming ||
        status == CallStatus.outgoing ||
        status == CallStatus.active;
  }

  void _openChat(String chatId, [String? title]) {
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(chatId: chatId, initialTitle: title),
      ),
    );
  }

  /// A quiet in-app banner instead of a system notification while the app is
  /// on screen, so the notification tray is only used when it is useful.
  void _banner({
    required String title,
    required String body,
    required VoidCallback onOpen,
  }) {
    if (!mounted || _inCall) return;
    final strings = ref.read(stringsProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (body.isNotEmpty)
              Text(body, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
        action: SnackBarAction(label: strings.get('open'), onPressed: onOpen),
      ),
    );
  }

  Future<void> _onIncoming(IncomingEvent event) async {
    if (!mounted) return;
    // Suppress only when the user is actively viewing that chat in the
    // foreground. Once the app is backgrounded, the last-open chat should still
    // raise notifications, matching messenger expectations.
    final resumed = _inForeground;
    if (event.isActiveChat && resumed) return;
    final client = ref.read(clientProvider);
    final settings = ref.read(settingsProvider);
    final chat = await client.store.getChat(event.message.chatId);
    if (chat?.muted == true) return;
    await ref.read(audioProvider).playCue(SoundCue.receive, settings.receiveSoundId);
    final name = chat?.peerName ?? 'Coralink';
    final english = settings.localeCode == 'en';
    final preview = event.message.isSticker
        ? (english ? 'Sticker' : 'Стикер')
        : event.message.isImage
            ? (english ? 'Photo' : 'Фото')
            : event.message.text;
    if (resumed) {
      _banner(
        title: name,
        body: truncate(preview, 140),
        onOpen: () => _openChat(event.message.chatId, chat?.peerName),
      );
      return;
    }
    if (settings.notificationMode != NotificationMode.offline) {
      await ref.read(notificationProvider).show(
            chatId: event.message.chatId,
            title: name,
            body: truncate(preview, 140),
            mode: settings.notificationMode,
          );
    }
  }

  /// Somebody added this account to a group: refresh the list (the chat row is
  /// already stored) and tell the user, in-app or in the notification tray.
  Future<void> _onGroupAdded(GroupAddedEvent event) async {
    if (!mounted) return;
    await ref.read(chatsProvider.notifier).refresh();
    if (!mounted) return;
    final settings = ref.read(settingsProvider);
    final strings = ref.read(stringsProvider);
    if (event.title.isEmpty) return;
    await ref.read(audioProvider).playCue(SoundCue.receive, settings.receiveSoundId);
    final body = strings.get('addedToGroup').replaceAll('{title}', event.title);
    if (_inForeground) {
      _banner(
        title: strings.get('newGroup'),
        body: body,
        onOpen: () => _openChat(event.groupId, event.title),
      );
      return;
    }
    if (settings.notificationMode != NotificationMode.offline) {
      await ref.read(notificationProvider).show(
            chatId: event.groupId,
            title: strings.get('newGroup'),
            body: body,
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
        // A banner must not cover the answer/decline buttons of the call UI.
        ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
        final settings = ref.read(settingsProvider);
        ref.read(audioProvider).playCue(SoundCue.call, settings.callSoundId);
        final peerId = ref.read(callProvider).peerId;
        if (peerId != null) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => CallScreen(peerId: peerId)),
          );
        }
      } else if (status == CallStatus.outgoing &&
          previous?.value != CallStatus.outgoing) {
        ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
        final settings = ref.read(settingsProvider);
        ref.read(audioProvider).playCue(SoundCue.call, settings.callSoundId);
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
