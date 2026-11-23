import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/session.dart';
import '../core/log.dart';
import '../domain/models.dart';
import '../domain/pet.dart';
import '../services/message_service.dart';

class PetUiState {
  const PetUiState({
    this.loading = true,
    this.pet,
    this.busy = false,
    this.error,
  });

  final bool loading;
  final PetState? pet;
  final bool busy;
  final String? error;

  PetUiState copyWith({
    bool? loading,
    PetState? pet,
    bool? busy,
    String? error,
    bool clearError = false,
  }) =>
      PetUiState(
        loading: loading ?? this.loading,
        pet: pet ?? this.pet,
        busy: busy ?? this.busy,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Drives the conversation's shared Tamagotchi: local ticking, care actions,
/// adoption and merging of states that arrive from other participants.
class PetController extends Notifier<PetUiState> {
  PetController(this.chatId);

  final String chatId;

  final _subscriptions = <StreamSubscription>[];
  Timer? _ticker;
  Timer? _syncTimer;
  DateTime? _lastSnapshotAt;
  bool _requestedSync = false;

  @override
  PetUiState build() {
    final client = ref.watch(clientProvider);
    _subscriptions
      ..add(client.messages.petEvents.listen(_onRemote))
      ..add(client.messages.messageUpdates.listen(_onMessageUpdate));
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    _load();
    ref.onDispose(() {
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _ticker?.cancel();
      _syncTimer?.cancel();
    });
    return const PetUiState();
  }

  Future<void> _load() async {
    final client = ref.read(clientProvider);
    final stored = await client.store.getPet(chatId);
    if (!ref.mounted) return;
    final ticked = stored?.tick(DateTime.now());
    if (ticked != null && stored != null && ticked.wellbeing != stored.wellbeing) {
      await client.store.upsertPet(ticked);
    }
    state = state.copyWith(loading: false, pet: ticked ?? state.pet);
    if (ticked == null && !_requestedSync) {
      // A conversation without a local pet may still have one on the other
      // side (fresh install). Ask quietly after the chat settles.
      _requestedSync = true;
      _syncTimer = Timer(const Duration(milliseconds: 1200), () {
        client.messages.requestPetSync(chatId);
      });
    }
  }

  void _onMessageUpdate(Message message) {
    if (message.chatId != chatId || !message.isPet) return;
    final raw = message.meta['petState'];
    if (raw is! Map) return;
    final remote = PetState.fromJson(raw.cast<String, dynamic>());
    if (remote == null) return;
    _merge(remote);
  }

  void _onRemote(PetEvent event) {
    if (event.chatId != chatId) return;
    if (event.state.chatId != chatId) return;
    if (event.action == 'ping') {
      final mine = state.pet;
      if (mine != null && mine.revision >= event.state.revision) {
        _maybeSnapshot(mine);
      }
      return;
    }
    _merge(event.state);
  }

  void _maybeSnapshot(PetState pet) {
    final now = DateTime.now();
    if (_lastSnapshotAt != null &&
        now.difference(_lastSnapshotAt!) < const Duration(seconds: 5)) {
      return;
    }
    _lastSnapshotAt = now;
    unawaited(
      ref.read(clientProvider).messages.sendPetSnapshot(chatId, pet).catchError(
        (Object error) => Log.d('pet.snapshot', '$error'),
      ),
    );
  }

  Future<void> _merge(PetState remote) async {
    final merged = mergePet(state.pet, remote);
    if (identical(merged, state.pet)) return;
    state = state.copyWith(pet: merged);
    await ref.read(clientProvider).store.upsertPet(merged);
  }

  Future<void> _tick() async {
    final pet = state.pet;
    if (pet == null) return;
    final ticked = pet.tick(DateTime.now());
    if (ticked.hunger == pet.hunger &&
        ticked.joy == pet.joy &&
        ticked.energy == pet.energy) {
      return;
    }
    state = state.copyWith(pet: ticked);
    await ref.read(clientProvider).store.upsertPet(ticked);
  }

  Future<void> adopt(PetSpecies species, String name) async {
    final client = ref.read(clientProvider);
    final myId = ref.read(sessionProvider).user?.id ?? '';
    final pet = PetState.adopt(
      chatId: chatId,
      species: species,
      name: name,
      adopterId: myId,
    );
    state = state.copyWith(pet: pet, busy: true, clearError: true);
    await client.store.upsertPet(pet);
    try {
      await client.messages.sendPet(
        chatId,
        action: 'adopt',
        state: pet,
        preview: 'Тамагочи',
      );
    } catch (error) {
      Log.e('pet.adopt', error);
      if (ref.mounted) state = state.copyWith(error: '$error');
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> care(PetAction action) async {
    final current = state.pet;
    if (current == null) return;
    final now = DateTime.now();
    final myId = ref.read(sessionProvider).user?.id ?? '';
    final before = current.tick(now);
    if (before.cooldownLeft(action, now) > Duration.zero) return;
    final pet = before.care(action, myId, now);
    state = state.copyWith(pet: pet, busy: true, clearError: true);
    final client = ref.read(clientProvider);
    await client.store.upsertPet(pet);
    try {
      await client.messages.sendPet(
        chatId,
        action: action.name,
        state: pet,
        preview: 'Тамагочи',
      );
    } catch (error) {
      Log.e('pet.care', error);
      if (ref.mounted) state = state.copyWith(error: '$error');
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> rename(String name) async {
    final current = state.pet;
    final clean = name.trim();
    if (current == null || clean.isEmpty || clean == current.name) return;
    final pet = current.rename(clean, DateTime.now());
    state = state.copyWith(pet: pet);
    final client = ref.read(clientProvider);
    await client.store.upsertPet(pet);
    try {
      await client.messages.sendPet(
        chatId,
        action: 'rename',
        state: pet,
        preview: 'Тамагочи',
      );
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
    }
  }

  Future<void> refresh() => _load();
}

final petProvider =
    NotifierProvider.family<PetController, PetUiState, String>(
  PetController.new,
);
