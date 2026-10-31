import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../core/app_colors.dart';
import '../../services/audio_service.dart';
import '../widgets/coral_widgets.dart';

class SettingsSoundsScreen extends ConsumerStatefulWidget {
  const SettingsSoundsScreen({super.key});

  @override
  ConsumerState<SettingsSoundsScreen> createState() => _SettingsSoundsScreenState();
}

class _SettingsSoundsScreenState extends ConsumerState<SettingsSoundsScreen> {
  late double _volume = ref.read(settingsProvider).volume;

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
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
            child: Text(
              strings.get('soundsTitle'),
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
          GlassPanel(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                SwitchListTile(
                  value: settings.rustleSound,
                  onChanged: (value) {
                    ref.read(settingsProvider.notifier).setRustle(value);
                    if (value) audio.play(NatureSound.rustle, gain: 0.7);
                  },
                  secondary: Icon(Icons.forest_outlined, color: palette.accent),
                  title: Text(strings.get('rustleSound')),
                  subtitle: Text(
                    strings.get('rustleSoundDesc'),
                    style: TextStyle(color: palette.textMuted, fontSize: 12),
                  ),
                ),
                SwitchListTile(
                  value: settings.sendSound,
                  onChanged: (value) {
                    ref.read(settingsProvider.notifier).setSendSound(value);
                    if (value) audio.play(NatureSound.drop);
                  },
                  secondary: Icon(Icons.water_drop_outlined, color: palette.accent),
                  title: Text(strings.get('sendSound')),
                  subtitle: Text(
                    strings.get('sendSoundDesc'),
                    style: TextStyle(color: palette.textMuted, fontSize: 12),
                  ),
                ),
                SwitchListTile(
                  value: settings.receiveSound,
                  onChanged: (value) {
                    ref.read(settingsProvider.notifier).setReceiveSound(value);
                    if (value) audio.play(NatureSound.splash);
                  },
                  secondary: Icon(Icons.waves_outlined, color: palette.accent),
                  title: Text(strings.get('receiveSound')),
                  subtitle: Text(
                    strings.get('receiveSoundDesc'),
                    style: TextStyle(color: palette.textMuted, fontSize: 12),
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
            label: Text(strings.get('previewSounds')),
          ),
        ],
      ),
    );
  }
}
