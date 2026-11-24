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
import '../widgets/pet_widgets.dart';
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
    client.messages.start();
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
    final resumed = _inForeground;
    if (event.isActiveChat && resumed) return;
    final client = ref.read(clientProvider);
    final settings = ref.read(settingsProvider);
    final chat = await client.store.getChat(event.message.chatId);
    if (chat?.muted == true) return;
    final sender = event.message.senderId == client.messages.myId
        ? null
        : await client.store.getUser(event.message.senderId);
    final name = chat?.peerName ?? 'Coralink';
    final title = chat?.isGroup == true && sender != null
        ? '$name · ${sender.name}'
        : name;
    final preview = _messagePreview(event.message, settings.localeCode == 'en');
    if (resumed) {
      if (settings.notificationMode != NotificationMode.minimal) {
        await ref
            .read(audioProvider)
            .playCue(SoundCue.receive, settings.receiveSoundId);
      }
      _banner(
        title: title,
        body: truncate(preview, 140),
        onOpen: () => _openChat(event.message.chatId, chat?.peerName),
      );
      return;
    }
    if (settings.notificationMode == NotificationMode.offline) return;
    await ref
        .read(notificationProvider)
        .show(
          chatId: event.message.chatId,
          title: title,
          body: truncate(preview, 140),
          mode: settings.notificationMode,
        );
  }

  String _messagePreview(Message message, bool english) {
    if (message.isSticker) return english ? 'Sticker' : 'Стикер';
    if (message.isPet) return english ? 'Tamagotchi' : 'Тамагочи';
    if (message.isImage) return english ? 'Photo' : 'Фото';
    if (message.isFile) return english ? 'File' : 'Файл';
    if (message.isAudio)
      return english ? 'Voice message' : 'Голосовое сообщение';
    if (message.isVideo) return english ? 'Video' : 'Видео';
    if (message.isVideoNote) return english ? 'Video note' : 'Видеокружок';
    return message.text;
  }

  Future<void> _onGroupAdded(GroupAddedEvent event) async {
    if (!mounted) return;
    await ref.read(chatsProvider.notifier).refresh();
    if (!mounted) return;
    final settings = ref.read(settingsProvider);
    final strings = ref.read(stringsProvider);
    final chat = await ref.read(clientProvider).store.getChat(event.groupId);
    if (chat?.muted == true || event.title.isEmpty) return;
    final body = strings.get('addedToGroup').replaceAll('{title}', event.title);
    if (_inForeground) {
      if (settings.notificationMode != NotificationMode.minimal) {
        await ref
            .read(audioProvider)
            .playCue(SoundCue.receive, settings.receiveSoundId);
      }
      _banner(
        title: strings.get('newGroup'),
        body: body,
        onOpen: () => _openChat(event.groupId, event.title),
      );
      return;
    }
    if (settings.notificationMode == NotificationMode.offline) return;
    await ref
        .read(notificationProvider)
        .show(
          chatId: event.groupId,
          title: strings.get('newGroup'),
          body: body,
          mode: settings.notificationMode,
        );
  }

  Future<void> _showCallNotification(String peerId) async {
    final user = await ref.read(clientProvider).store.getUser(peerId);
    if (!mounted) return;
    await ref
        .read(notificationProvider)
        .showCall(peerId: peerId, name: user?.name ?? 'Coralink');
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
        ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
        final settings = ref.read(settingsProvider);
        final peerId = ref.read(callProvider).peerId;
        if (_inForeground && peerId != null) {
          ref.read(audioProvider).playCue(SoundCue.call, settings.callSoundId);
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => CallScreen(peerId: peerId)));
        } else if (peerId != null) {
          unawaited(_showCallNotification(peerId));
        }
      } else if (status == CallStatus.outgoing &&
          previous?.value != CallStatus.outgoing &&
          _inForeground) {
        ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
        final settings = ref.read(settingsProvider);
        ref.read(audioProvider).playCue(SoundCue.call, settings.callSoundId);
      } else if (wasIncoming && status != CallStatus.incoming) {
        unawaited(ref.read(notificationProvider).cancelCall());
      }
    });

    return Scaffold(
      body: CoralBackground(
        child: IndexedStack(
          index: _index,
          children: const [
            ChatsScreen(),
            ContactsScreen(),
            PersonalPetScreen(),
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
                icon: _NavIcon(icon: Icons.spa_outlined, active: _index == 2),
                activeIcon: _NavIcon(icon: Icons.spa_rounded, active: true),
                label: strings.get('petTab'),
              ),
              BottomNavigationBarItem(
                icon: _NavIcon(
                  icon: Icons.settings_outlined,
                  active: _index == 3,
                ),
                activeIcon: _NavIcon(
                  icon: Icons.settings_rounded,
                  active: true,
                ),
                label: strings.get('settingsTab'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PersonalPetScreen extends ConsumerWidget {
  const PersonalPetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(sessionProvider).user?.id ?? '';
    final strings = ref.watch(stringsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(strings.get('petPersonalTitle'))),
      body: CoralBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          children: [
            PetPanel(
              chatId: 'personal:$userId',
              strings: strings,
              personal: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  const _NavIcon({
    required this.icon,
    required this.active,
    this.badge = false,
  });
  final IconData icon;
  final bool active;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          icon,
          size: 24,
          color: active ? palette.accent : palette.textMuted,
        ),
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
                  BoxShadow(
                    color: palette.accent.withValues(alpha: 0.7),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
