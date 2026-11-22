import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../services/audio_service.dart';
import '../widgets/coral_widgets.dart';

/// Every functional moment (presence, sending, receiving, calls) gets its own
/// sound, and each one can be swapped for any of the bundled nature sounds.
class SettingsSoundsScreen extends ConsumerStatefulWidget {
  const SettingsSoundsScreen({super.key});

  @override
  ConsumerState<SettingsSoundsScreen> createState() => _SettingsSoundsScreenState();
}

class _SettingsSoundsScreenState extends ConsumerState<SettingsSoundsScreen> {
  late double _volume = ref.read(settingsProvider).volume;

  IconData _cueIcon(SoundCue cue) => switch (cue) {
        SoundCue.presence => Icons.forest_outlined,
        SoundCue.send => Icons.water_drop_outlined,
        SoundCue.receive => Icons.waves_outlined,
        SoundCue.call => Icons.phone_in_talk_outlined,
      };

  String _soundLabel(AppStrings strings, String id) {
    final sound = natureSoundFromId(id);
    if (sound == null) return strings.get('soundOff');
    return strings.get(soundNameKey(sound));
  }

  Future<void> _choose(SoundCue cue) async {
    final strings = ref.read(stringsProvider);
    final palette = context.palette;
    final settings = ref.read(settingsProvider);
    final audio = ref.read(audioProvider);
    final current = settings.soundIdFor(cue);

    final choice = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${strings.get(cueNameKey(cue))} · ${strings.get('soundPick')}',
                    style: TextStyle(color: palette.textPrimary, fontSize: 15),
                  ),
                ),
              ),
              ListTile(
                leading: Icon(Icons.volume_off_rounded, color: palette.textMuted),
                title: Text(
                  strings.get('soundOff'),
                  style: TextStyle(color: palette.textPrimary),
                ),
                trailing: current.isEmpty
                    ? Icon(Icons.check_rounded, color: palette.accent)
                    : null,
                onTap: () => Navigator.pop(context, ''),
              ),
              for (final sound in kSoundChoices)
                ListTile(
                  leading: Icon(Icons.music_note_rounded, color: palette.accent),
                  title: Text(
                    strings.get(soundNameKey(sound)),
                    style: TextStyle(color: palette.textPrimary),
                  ),
                  trailing: current == sound.name
                      ? Icon(Icons.check_rounded, color: palette.accent)
                      : IconButton(
                          icon: Icon(
                            Icons.play_circle_outline_rounded,
                            color: palette.textMuted,
                          ),
                          onPressed: () => audio.preview(sound),
                        ),
                  onTap: () {
                    audio.preview(sound);
                    Navigator.pop(context, sound.name);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    await ref.read(settingsProvider.notifier).setSound(cue, choice);
    if (!mounted) return;
    if (choice.isEmpty) return;
    final sound = natureSoundFromId(choice);
    if (sound != null && cue != SoundCue.presence) {
      await ref.read(audioProvider).preview(sound);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final settings = ref.watch(settingsProvider);
    final palette = context.palette;
    final audio = ref.read(audioProvider);

    return Scaffold(
      appBar: AppBar(title: Text(strings.get('soundsSection'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: Text(
              strings.get('soundsTitle'),
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Text(
              strings.get('soundsPerEventNote'),
              style: TextStyle(color: palette.textMuted, fontSize: 12.5, height: 1.4),
            ),
          ),
          GlassPanel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (final cue in SoundCue.values)
                  ListTile(
                    onTap: () => _choose(cue),
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: palette.accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(_cueIcon(cue), size: 20, color: palette.accent),
                    ),
                    title: Text(
                      strings.get(cueNameKey(cue)),
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      _soundLabel(strings, settings.soundIdFor(cue)),
                      style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                    ),
                    trailing: IconButton(
                      tooltip: strings.get('previewSounds'),
                      icon: Icon(
                        Icons.play_circle_outline_rounded,
                        color: palette.textMuted,
                      ),
                      onPressed: () {
                        final sound = natureSoundFromId(settings.soundIdFor(cue));
                        if (sound != null) audio.preview(sound);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          GlassPanel(
            margin: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.graphic_eq_rounded, size: 18, color: palette.accent),
                    const SizedBox(width: 8),
                    Text(
                      strings.get('volume'),
                      style: TextStyle(color: palette.textPrimary, fontSize: 14),
                    ),
                    const Spacer(),
                    Text(
                      '${(_volume * 100).round()}%',
                      style: TextStyle(color: palette.textMuted, fontSize: 12.5),
                    ),
                  ],
                ),
                Slider(
                  value: _volume,
                  activeColor: palette.accent,
                  inactiveColor: palette.surfaceElevated,
                  onChanged: (value) => setState(() => _volume = value),
                  onChangeEnd: (value) {
                    ref.read(settingsProvider.notifier).setVolume(value);
                    ref.read(audioProvider).volume = value;
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => audio.previewAll(),
            icon: const Icon(Icons.play_circle_outline_rounded, size: 20),
            label: Text(strings.get('previewAllSounds')),
          ),
        ],
      ),
    );
  }
}
