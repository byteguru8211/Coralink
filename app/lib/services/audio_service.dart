import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// The synthesized nature sounds shipped with the app. Every functional cue in
/// the interface can be mapped to any of them from settings.
enum NatureSound { rustle, drop, splash, inhale, chime, bell, breeze }

/// A functional moment that plays a sound. Each cue has its own user-chosen
/// sound (or "no sound").
enum SoundCue { presence, send, receive, call }

const Map<NatureSound, String> kSoundAssets = {
  NatureSound.rustle: 'sounds/rustle.wav',
  NatureSound.drop: 'sounds/drop.wav',
  NatureSound.splash: 'sounds/splash.wav',
  NatureSound.inhale: 'sounds/inhale.wav',
  NatureSound.chime: 'sounds/chime.wav',
  NatureSound.bell: 'sounds/bell.wav',
  NatureSound.breeze: 'sounds/breeze.wav',
};

/// Order used by the picker in settings.
const List<NatureSound> kSoundChoices = [
  NatureSound.rustle,
  NatureSound.drop,
  NatureSound.splash,
  NatureSound.inhale,
  NatureSound.chime,
  NatureSound.bell,
  NatureSound.breeze,
];

NatureSound? natureSoundFromId(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final sound in NatureSound.values) {
    if (sound.name == id) return sound;
  }
  return null;
}

String soundIdOf(NatureSound sound) => sound.name;

/// Asset file name (useful for previews/diagnostics).
String soundAssetOf(NatureSound sound) => kSoundAssets[sound] ?? '';

/// Localization key for a sound's human name.
String soundNameKey(NatureSound sound) => 'sound_${sound.name}';

String cueNameKey(SoundCue cue) => 'cue_${cue.name}';

String cueDescKey(SoundCue cue) => 'cue_${cue.name}Desc';

/// Small audio layer with one player per effect; respects user volume and
/// per-cue sound choice from settings.
class AudioService {
  final _players = <NatureSound, AudioPlayer>{};
  final _loops = <NatureSound, AudioPlayer>{};
  bool enabled = true;
  double volume = 0.7;

  Future<AudioPlayer> _playerFor(NatureSound sound, {bool loop = false}) async {
    final map = loop ? _loops : _players;
    final existing = map[sound];
    if (existing != null) return existing;
    final player = AudioPlayer();
    if (loop) {
      await player.setReleaseMode(ReleaseMode.loop);
    }
    map[sound] = player;
    return player;
  }

  String _asset(NatureSound sound) => kSoundAssets[sound]!;

  Future<void> play(NatureSound sound, {double gain = 1}) async {
    if (!enabled) return;
    try {
      final player = await _playerFor(sound);
      await player.stop();
      await player.setVolume((volume * gain).clamp(0, 1));
      await player.play(AssetSource(_asset(sound)));
    } catch (error) {
      if (kDebugMode) debugPrint('audio: $error');
    }
  }

  /// Plays the sound chosen for [cue] (an empty id means "no sound").
  Future<void> playCue(SoundCue cue, String id) async {
    final sound = natureSoundFromId(id);
    if (sound == null) return;
    switch (cue) {
      case SoundCue.presence:
        await startPresence(id);
      case SoundCue.send:
        await play(sound);
      case SoundCue.receive:
        await play(sound, gain: 0.85);
      case SoundCue.call:
        await play(sound);
    }
  }

  Future<void> startPresence(String id) async {
    if (!enabled) return;
    final sound = natureSoundFromId(id);
    if (sound == null) return;
    try {
      // Only one presence loop at a time.
      await stopPresence();
      final player = await _playerFor(sound, loop: true);
      await player.setVolume((volume * 0.25).clamp(0, 1));
      await player.play(AssetSource(_asset(sound)));
    } catch (error) {
      if (kDebugMode) debugPrint('audio: $error');
    }
  }

  Future<void> stopPresence() async {
    for (final player in _loops.values) {
      try {
        await player.stop();
      } catch (_) {}
    }
  }

  Future<void> preview(NatureSound sound) => play(sound);

  Future<void> previewAll() async {
    for (final sound in kSoundChoices) {
      await play(sound, gain: 0.8);
      await Future<void>.delayed(const Duration(milliseconds: 650));
    }
  }

  Future<void> dispose() async {
    for (final player in [..._players.values, ..._loops.values]) {
      await player.dispose();
    }
    _players.clear();
    _loops.clear();
  }
}
