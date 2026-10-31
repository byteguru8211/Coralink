import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/utils.dart';
import '../../data/api_client.dart';
import '../../domain/models.dart';
import '../widgets/coral_widgets.dart';

const _avatarColors = [
  '#1A9C7A',
  '#2FB894',
  '#7FCDB5',
  '#0D4F3C',
  '#3E9C6B',
  '#58C3A2',
];

class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key, required this.user});
  final User user;

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  late final TextEditingController _name =
      TextEditingController(text: widget.user.name == 'Гость' ? '' : widget.user.name);
  late final TextEditingController _about = TextEditingController(text: widget.user.about);
  String _color = _avatarColors.first;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _color = widget.user.avatarColor;
    if (!_avatarColors.contains(_color)) _color = _avatarColors.first;
  }

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final strings = ref.read(stringsProvider);
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.get('nameRequired'))),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      await ref.read(sessionProvider.notifier).completeProfile(
            name,
            _about.text.trim(),
            _color,
          );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    return Scaffold(
      body: CoralBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.get('profileTitle'),
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  strings.get('profileSubtitle'),
                  style: TextStyle(color: palette.textMuted, fontSize: 14),
                ),
                const SizedBox(height: 34),
                Center(
                  child: PulseHalo(
                    active: true,
                    size: 140,
                    child: SeedAvatar(
                      seedId: widget.user.id,
                      name: _name.text.isEmpty ? '?' : _name.text,
                      colorHex: _color,
                      size: 116,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final color in _avatarColors)
                      GestureDetector(
                        onTap: () => setState(() => _color = color),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colorFromHex(color),
                            border: Border.all(
                              color: _color == color ? Colors.white : Colors.transparent,
                              width: 2,
                            ),
                            boxShadow: [
                              if (_color == color)
                                BoxShadow(
                                  color: colorFromHex(color).withValues(alpha: 0.45),
                                  blurRadius: 12,
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  style: TextStyle(color: palette.textPrimary, fontSize: 16),
                  decoration: InputDecoration(
                    labelText: strings.get('yourName'),
                    prefixIcon: Icon(Icons.person_outline_rounded, color: palette.accent),
                  ),
                  onChanged: (_) => setState(() {}),
                  maxLength: 64,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _about,
                  maxLines: 3,
                  maxLength: 280,
                  style: TextStyle(color: palette.textPrimary, fontSize: 15),
                  decoration: InputDecoration(
                    labelText: strings.get('aboutOptional'),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.spa_rounded, size: 19),
                            const SizedBox(width: 8),
                            Text(strings.get('start')),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
