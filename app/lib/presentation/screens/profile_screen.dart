import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/utils.dart';
import '../../data/api_client.dart';
import '../widgets/coral_widgets.dart';

const _colors = ['#1A9C7A', '#2FB894', '#7FCDB5', '#0D4F3C', '#3E9C6B', '#58C3A2'];

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  late final TextEditingController _name;
  late final TextEditingController _about;
  late String _color;
  late String _avatar;
  bool _changed = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(sessionProvider).user!;
    _name = TextEditingController(text: user.name);
    _about = TextEditingController(text: user.about);
    _color = user.avatarColor;
    _avatar = user.avatar;
    _name.addListener(_markChanged);
    _about.addListener(_markChanged);
  }

  void _markChanged() => setState(() => _changed = true);

  Future<void> _pickAvatar() async {
    final strings = ref.read(stringsProvider);
    final mobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final source = mobile
        ? await showModalBottomSheet<ImageSource>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SettingsTile(
                    icon: Icons.photo_library_outlined,
                    title: strings.get('gallery'),
                    onTap: () => Navigator.pop(context, ImageSource.gallery),
                  ),
                  SettingsTile(
                    icon: Icons.photo_camera_outlined,
                    title: strings.get('camera'),
                    onTap: () => Navigator.pop(context, ImageSource.camera),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          )
        : ImageSource.gallery;
    if (source == null) return;
    try {
      final file = await ImagePicker().pickImage(
        source: source,
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
      setState(() {
        _avatar = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        _changed = true;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('networkError'))),
      );
    }
  }

  Future<void> _removeAvatar() async {
    setState(() {
      _avatar = '';
      _changed = true;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final strings = ref.read(stringsProvider);
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('nameRequired'))),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(sessionProvider.notifier).saveProfile(
            name: _name.text.trim(),
            about: _about.text.trim(),
            avatarColor: _color,
            avatar: _avatar,
          );
      if (!mounted) return;
      setState(() => _changed = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('profileSaved'))),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final user = ref.watch(sessionProvider).user!;
    final palette = context.palette;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.get('myProfile')),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text(
              strings.get('save'),
              style: TextStyle(
                color: _changed ? palette.accent : palette.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          Center(
            child: PulseHalo(
              active: true,
              size: 150,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  SeedAvatar(
                    seedId: user.id,
                    name: _name.text.isEmpty ? user.name : _name.text,
                    colorHex: _color,
                    avatar: _avatar.isEmpty ? null : _avatar,
                    size: 124,
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: _pickAvatar,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: palette.accent,
                          border: Border.all(color: palette.background, width: 3),
                        ),
                        child: Icon(Icons.photo_camera_rounded,
                            size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_avatar.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Center(
                child: TextButton.icon(
                  onPressed: _removeAvatar,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: palette.textMuted),
                  label: Text(strings.get('removePhoto'),
                      style: TextStyle(color: palette.textMuted, fontSize: 13)),
                ),
              ),
            ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              user.phone,
              style: TextStyle(color: palette.textMuted, fontSize: 13, letterSpacing: 0.6),
            ),
          ),
          const SizedBox(height: 26),
          Text(
            strings.get('changeSeed'),
            style: TextStyle(color: palette.textMuted, fontSize: 12, letterSpacing: 0.6),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final color in _colors)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _color = color;
                      _changed = true;
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colorFromHex(color),
                      border: Border.all(
                        color: _color == color ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _name,
            maxLength: 64,
            style: TextStyle(color: palette.textPrimary, fontSize: 16),
            decoration: InputDecoration(
              labelText: strings.get('yourName'),
              prefixIcon: Icon(Icons.person_outline_rounded, color: palette.accent),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _about,
            maxLines: 4,
            maxLength: 280,
            style: TextStyle(color: palette.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              labelText: strings.get('aboutYou'),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          if (_changed)
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(strings.get('save')),
            ),
          const SizedBox(height: 20),
          GlassPanel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                SettingsTile(
                  icon: Icons.ios_share_rounded,
                  title: strings.get('invite'),
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(text: strings.get('inviteText')),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(strings.get('copied'))),
                    );
                  },
                ),
                SettingsTile(
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
