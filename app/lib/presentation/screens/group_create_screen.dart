import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

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
  String _avatar = '';
  bool _picking = false;

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

  /// Lets the user choose the group picture before the group even exists.
  Future<void> _pickAvatar() async {
    if (_picking) return;
    final strings = ref.read(stringsProvider);
    final mobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsTile(
              icon: Icons.photo_library_outlined,
              title: strings.get('gallery'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            if (mobile)
              SettingsTile(
                icon: Icons.photo_camera_outlined,
                title: strings.get('camera'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
            if (_avatar.isNotEmpty)
              SettingsTile(
                icon: Icons.delete_outline_rounded,
                title: strings.get('removePhoto'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'remove') {
      setState(() => _avatar = '');
      return;
    }
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 320,
        maxHeight: 320,
        imageQuality: 82,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes > 360 * 1024) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.get('imageTooLarge'))),
        );
        return;
      }
      if (!mounted) return;
      setState(
        () => _avatar = 'data:image/jpeg;base64,${base64Encode(bytes)}',
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('imageTooLarge'))),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _create() async {
    final title = _title.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final group = await ref.read(clientProvider).messages.createGroup(
            title: title,
            memberIds: _selected.toList(),
            avatar: _avatar,
          );
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
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
            child: Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: _pickAvatar,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SeedAvatar(
                        seedId: _title.text.trim().isEmpty
                            ? 'new-group'
                            : _title.text.trim(),
                        name: _title.text.trim().isEmpty
                            ? strings.get('newGroup')
                            : _title.text.trim(),
                        avatar: _avatar,
                        size: 62,
                      ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: palette.accent,
                            border: Border.all(
                              color: palette.background,
                              width: 2,
                            ),
                          ),
                          child: _picking
                              ? const Padding(
                                  padding: EdgeInsets.all(5),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(
                                  Icons.photo_camera_rounded,
                                  size: 13,
                                  color: Colors.white,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.get('chooseGroupIcon'),
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        strings.get('chooseGroupIconDesc'),
                        style: TextStyle(color: palette.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
