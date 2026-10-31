import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

enum NatureSound { rustle, drop, splash, inhale, chime }

/// Small audio layer with one player per effect; respects user volume and
/// individual toggles from settings.
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

  String _asset(NatureSound sound) => switch (sound) {
        NatureSound.rustle => 'sounds/rustle.wav',
        NatureSound.drop => 'sounds/drop.wav',
        NatureSound.splash => 'sounds/splash.wav',
        NatureSound.inhale => 'sounds/inhale.wav',
        NatureSound.chime => 'sounds/chime.wav',
      };

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

  Future<void> startRustle() async {
    if (!enabled) return;
    try {
      final player = await _playerFor(NatureSound.rustle, loop: true);
      await player.setVolume((volume * 0.25).clamp(0, 1));
      await player.play(AssetSource(_asset(NatureSound.rustle)));
    } catch (error) {
      if (kDebugMode) debugPrint('audio: $error');
    }
  }

  Future<void> stopRustle() async {
    try {
      await _loops[NatureSound.rustle]?.stop();
    } catch (_) {}
  }

  Future<void> previewAll() async {
    await play(NatureSound.rustle, gain: 0.8);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await play(NatureSound.drop);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await play(NatureSound.splash);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await play(NatureSound.chime);
  }

  Future<void> dispose() async {
    for (final player in [..._players.values, ..._loops.values]) {
      await player.dispose();
    }
    _players.clear();
    _loops.clear();
  }
}
