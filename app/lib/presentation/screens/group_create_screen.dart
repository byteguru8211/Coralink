import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../domain/models.dart';
import '../controllers.dart';
import '../widgets/coral_widgets.dart';
import 'chat_screen.dart';

class GroupCreateScreen extends ConsumerStatefulWidget {
  const GroupCreateScreen({super.key});

  @override
  ConsumerState<GroupCreateScreen> createState() => _GroupCreateScreenState();
}

class _GroupCreateScreenState extends ConsumerState<GroupCreateScreen> {
  final _title = TextEditingController();
  final _selected = <String>{};
  List<User> _contacts = const [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      final contacts = await ref.read(clientProvider).api.contacts();
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final group = await ref
          .read(clientProvider)
          .messages
          .createGroup(title: title, memberIds: _selected.toList());
      if (!mounted) return;
      await ref.read(chatsProvider.notifier).refresh();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: group.id, initialTitle: group.title)),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.get('newGroup')),
        actions: [
          TextButton(
            onPressed:
                (_title.text.trim().isEmpty || _saving) ? null : _create,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(strings.get('create')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 64,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: TextStyle(color: palette.textPrimary, fontSize: 16),
              decoration: InputDecoration(
                labelText: strings.get('groupTitle'),
                prefixIcon: Icon(Icons.groups_rounded, color: palette.accent),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${strings.get('addMembers')} (${_selected.length})',
                style: TextStyle(color: palette.textMuted, fontSize: 13),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: palette.accent))
                : _contacts.isEmpty
                    ? Center(
                        child: Text(
                          strings.get('noContacts'),
                          style: TextStyle(color: palette.textMuted),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _contacts.length,
                        itemBuilder: (context, index) {
                          final user = _contacts[index];
                          final checked = _selected.contains(user.id);
                          return CheckboxListTile(
                            value: checked,
                            activeColor: palette.accent,
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(user.id);
                              } else {
                                _selected.remove(user.id);
                              }
                            }),
                            secondary: SeedAvatar(
                              seedId: user.id,
                              name: user.name,
                              colorHex: user.avatarColor,
                              avatar: user.avatar,
                              size: 40,
                            ),
                            title: Text(
                              user.name,
                              style: TextStyle(color: palette.textPrimary),
                            ),
                            subtitle: user.username.isNotEmpty
                                ? Text('@${user.username}',
                                    style: TextStyle(
                                        color: palette.textMuted, fontSize: 12))
                                : null,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
