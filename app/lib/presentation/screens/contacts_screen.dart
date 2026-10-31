import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/utils.dart';
import '../../domain/models.dart';
import '../controllers.dart';
import '../widgets/coral_widgets.dart';
import 'chat_screen.dart';
import 'people_search_screen.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(contactsProvider.notifier).refresh());
  }

  Future<void> _open(Contact contact) async {
    final client = ref.read(clientProvider);
    final chat = await client.messages.ensureChat(contact.user.id, peer: contact.user);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(chatId: chat.id, initialTitle: contact.user.name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(contactsProvider);
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(strings.get('contactsTitle')),
        actions: [
          IconButton(
            tooltip: strings.get('searchPeople'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PeopleSearchScreen()),
            ),
            icon: const Icon(Icons.person_search_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PeopleSearchScreen()),
        ),
        backgroundColor: palette.accent,
        foregroundColor: Colors.white,
        child: const Icon(Icons.person_add_alt_1_rounded),
      ),
      body: state.loading
          ? Center(child: CircularProgressIndicator(color: palette.accent))
          : state.contacts.isEmpty
              ? EmptyState(
                  title: strings.get('noContactsTitle'),
                  subtitle: strings.get('noContactsText'),
                  actionLabel: strings.get('findFriends'),
                  onAction: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PeopleSearchScreen()),
                  ),
                  icon: Icons.people_outline_rounded,
                )
              : RefreshIndicator(
                  color: palette.accent,
                  backgroundColor: palette.surface,
                  onRefresh: () => ref.read(contactsProvider.notifier).refresh(),
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 6, bottom: 96),
                    itemCount: state.contacts.length,
                    itemBuilder: (context, index) {
                      final contact = state.contacts[index];
                      final user = contact.user;
                      final online = user.presence != Presence.offline;
                      final subtitle = switch (user.presence) {
                        Presence.online => strings.get('online'),
                        Presence.active => strings.get('active'),
                        Presence.away => strings.get('away'),
                        Presence.offline => lastSeenLabel(user.lastSeen, strings),
                      };
                      return Dismissible(
                        key: ValueKey('contact-${user.id}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 28),
                          color: palette.surfaceElevated,
                          child: Icon(Icons.person_remove_outlined, color: palette.coral),
                        ),
                        onDismissed: (_) =>
                            ref.read(contactsProvider.notifier).remove(user.id),
                        child: ListTile(
                          onTap: () => _open(contact),
                          leading: SeedAvatar(
                            seedId: user.id,
                            name: user.name,
                            colorHex: user.avatarColor,
                            online: online,
                            size: 48,
                          ),
                          title: Text(
                            user.name,
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Row(
                            children: [
                              if (online)
                                Container(
                                  width: 6,
                                  height: 6,
                                  margin: const EdgeInsets.only(right: 6),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: palette.halo,
                                  ),
                                ),
                              Flexible(
                                child: Text(
                                  subtitle,
                                  style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            onPressed: () => _open(contact),
                            icon: Icon(Icons.chat_bubble_outline_rounded, color: palette.accent),
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
