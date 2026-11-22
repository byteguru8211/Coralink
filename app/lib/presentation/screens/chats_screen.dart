import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../domain/models.dart';
import '../../network/realtime.dart';
import '../controllers.dart';
import '../widgets/chat_widgets.dart';
import '../widgets/coral_widgets.dart';
import 'chat_screen.dart';
import 'echo_screen.dart';
import 'group_create_screen.dart';
import 'people_search_screen.dart';

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});

  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  bool _archiveOpen = false;

  // Coral growth: chats the list already knew about, and chats that just
  // appeared and should sprout once.
  final Set<String> _knownChatIds = <String>{};
  final Set<String> _growingChatIds = <String>{};
  final List<Timer> _growthTimers = <Timer>[];
  bool _primed = false;

  @override
  void dispose() {
    for (final timer in _growthTimers) {
      timer.cancel();
    }
    super.dispose();
  }

  /// Detects conversations that appeared since the previous frame (a new peer,
  /// a group invitation) and starts their coral growth animation.
  void _syncGrowth(List<Chat> chats) {
    final ids = chats.map((chat) => chat.id).toSet();
    if (!_primed) {
      _primed = true;
      _knownChatIds.addAll(ids);
      return;
    }
    final fresh = ids.difference(_knownChatIds);
    _knownChatIds
      ..clear()
      ..addAll(ids);
    if (fresh.isEmpty) return;
    _growingChatIds.addAll(fresh);
    final timer = Timer(const Duration(milliseconds: 2000), () {
      if (!mounted) return;
      setState(() => _growingChatIds.removeAll(fresh));
    });
    _growthTimers.add(timer);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatsProvider);
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    if (!state.loading) _syncGrowth(state.chats);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        titleSpacing: 18,
        title: Row(
          children: [
            const CoralMark(size: 30),
            const SizedBox(width: 10),
            const Text('Coralink'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: strings.get('echoTitle'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EchoScreen()),
            ),
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            tooltip: strings.get('newGroup'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const GroupCreateScreen()),
            ),
            icon: const Icon(Icons.group_add_rounded),
          ),
          IconButton(
            tooltip: strings.get('newChat'),
            onPressed: _openPeopleSearch,
            icon: const Icon(Icons.person_add_alt_1_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openPeopleSearch,
        backgroundColor: palette.accent,
        foregroundColor: Colors.white,
        elevation: 6,
        child: const Icon(Icons.auto_awesome_rounded),
      ),
      body: state.loading
          ? Center(child: CircularProgressIndicator(color: palette.accent))
          : RefreshIndicator(
              color: palette.accent,
              backgroundColor: palette.surface,
              onRefresh: () => ref.read(chatsProvider.notifier).refresh(),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  if (!state.connected)
                    SliverToBoxAdapter(
                      child: _ReconnectBanner(strings: strings, status: state.connection),
                    ),
                  if (state.chats.isEmpty && state.archived.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        title: strings.get('noChatsTitle'),
                        subtitle: strings.get('noChatsText'),
                        actionLabel: strings.get('findFriends'),
                        onAction: _openPeopleSearch,
                        icon: Icons.bubble_chart_outlined,
                      ),
                    )
                  else ...[
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final chat = state.chats[index];
                          return ChatTile(
                            chat: chat,
                            strings: strings,
                            growing: _growingChatIds.contains(chat.id),
                            onTap: () => _openChat(chat),
                            onLongPress: () => _showChatMenu(chat),
                            onArchive: () => ref.read(chatsProvider.notifier).archive(chat.id),
                          );
                        },
                        childCount: state.chats.length,
                      ),
                    ),
                    if (state.archived.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _ArchiveHeader(
                          count: state.archived.length,
                          open: _archiveOpen,
                          strings: strings,
                          onTap: () => setState(() => _archiveOpen = !_archiveOpen),
                        ),
                      ),
                    if (_archiveOpen)
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final chat = state.archived[index];
                            return Opacity(
                              opacity: 0.75,
                              child: ChatTile(
                                chat: chat,
                                strings: strings,
                                onTap: () => _openChat(chat),
                                onLongPress: () => _showChatMenu(chat),
                                onArchive: () => ref.read(chatsProvider.notifier).unarchive(chat.id),
                              ),
                            );
                          },
                          childCount: state.archived.length,
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 100)),
                  ],
                ],
              ),
            ),
    );
  }

  void _openChat(Chat chat) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initialTitle: chat.peerName)),
    );
  }

  Future<void> _openPeopleSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PeopleSearchScreen()),
    );
    ref.read(chatsProvider.notifier).refresh();
  }

  Future<void> _showChatMenu(Chat chat) async {
    final strings = ref.read(stringsProvider);
    final palette = context.palette;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsTile(
              icon: chat.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
              title: strings.get(chat.pinned ? 'unpin' : 'pinned'),
              onTap: () {
                Navigator.pop(context);
                ref.read(chatsProvider.notifier).togglePin(chat.id);
              },
            ),
            SettingsTile(
              icon: chat.muted ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              title: chat.muted
                  ? (strings.locale.languageCode == 'en' ? 'Unmute' : 'Включить звук')
                  : (strings.locale.languageCode == 'en' ? 'Mute' : 'Без звука'),
              onTap: () {
                Navigator.pop(context);
                ref.read(chatsProvider.notifier).toggleMute(chat.id);
              },
            ),
            SettingsTile(
              icon: chat.archived ? Icons.unarchive_rounded : Icons.archive_outlined,
              title: strings.get(chat.archived ? 'unarchive' : 'archiveAction'),
              onTap: () {
                Navigator.pop(context);
                if (chat.archived) {
                  ref.read(chatsProvider.notifier).unarchive(chat.id);
                } else {
                  ref.read(chatsProvider.notifier).archive(chat.id);
                }
              },
            ),
            SettingsTile(
              icon: Icons.delete_outline_rounded,
              title: strings.get('delete'),
              danger: true,
              onTap: () async {
                Navigator.pop(context);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    backgroundColor: palette.surface,
                    title: Text(strings.get('deleteChat')),
                    content: Text(strings.get('deleteChatConfirm')),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(strings.get('cancel')),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(strings.get('delete'), style: TextStyle(color: palette.coral)),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref.read(chatsProvider.notifier).delete(chat.id);
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _ArchiveHeader extends StatelessWidget {
  const _ArchiveHeader({
    required this.count,
    required this.open,
    required this.strings,
    required this.onTap,
  });

  final int count;
  final bool open;
  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: palette.surface.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.divider),
          ),
          child: Row(
            children: [
              Icon(Icons.waves_rounded, size: 18, color: palette.accentSoft),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${strings.get('archivedSection')} · $count',
                  style: TextStyle(color: palette.textMuted, fontSize: 13),
                ),
              ),
              Icon(
                open ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                color: palette.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReconnectBanner extends StatelessWidget {
  const _ReconnectBanner({required this.strings, required this.status});
  final AppStrings strings;
  final RealtimeStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: palette.accentSoft,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              strings.get('reconnecting'),
              style: TextStyle(color: palette.textMuted, fontSize: 12.5),
            ),
          ),
          ConnectionPill(status: status, strings: strings),
        ],
      ),
    );
  }
}
