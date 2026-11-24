import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/session.dart';
import '../domain/pet.dart';

class PetUiState {
  const PetUiState({
    this.loading = false,
    this.record,
    this.busy = false,
    this.error,
  });

  final bool loading;
  final PetRecord? record;
  final bool busy;
  final String? error;

  PetState? get pet => record?.state;
  bool get canCare => record?.canCare ?? false;

  PetUiState copyWith({
    bool? loading,
    PetRecord? record,
    bool? busy,
    String? error,
    bool clearRecord = false,
    bool clearError = false,
  }) => PetUiState(
    loading: loading ?? this.loading,
    record: clearRecord ? null : (record ?? this.record),
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
  );
}

class PetController extends Notifier<PetUiState> {
  PetController(this.chatId);

  final String chatId;
  final _subscriptions = <StreamSubscription>[];
  Timer? _ticker;

  bool get _personal => chatId.startsWith('personal:');

  @override
  PetUiState build() {
    final client = ref.watch(clientProvider);
    _subscriptions.add(client.pets.updates.listen(_onRemote));
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    unawaited(_load());
    ref.onDispose(() {
      for (final subscription in _subscriptions) {
        subscription.cancel();
      }
      _ticker?.cancel();
    });
    return const PetUiState();
  }

  Future<void> _load() async {
    try {
      final record = await ref.read(clientProvider).pets.find(chatId);
      if (!ref.mounted) return;
      state = state.copyWith(
        loading: false,
        record: record,
        clearRecord: record == null,
        clearError: true,
      );
    } catch (error) {
      if (ref.mounted) {
        state = state.copyWith(loading: false, error: '$error');
      }
    }
  }

  void _onRemote(PetRecord record) {
    if (record.localChatId(ref.read(clientProvider).pets.myId) != chatId)
      return;
    if (!ref.mounted) return;
    state = state.copyWith(record: record, loading: false, clearError: true);
  }

  void _tick() {
    final record = state.record;
    final pet = record?.state;
    if (pet == null) return;
    final ticked = pet.tick(DateTime.now());
    if (identical(ticked, pet)) return;
    state = state.copyWith(record: record!.copyWith(state: ticked));
  }

  Future<void> adopt(PetSpecies species, String name) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(busy: true, clearError: true);
    try {
      final record = await client.pets.create(
        chatId: chatId,
        species: species,
        name: name,
        personal: _personal,
      );
      if (ref.mounted) state = state.copyWith(record: record, busy: false);
    } catch (error) {
      if (ref.mounted) state = state.copyWith(busy: false, error: '$error');
    }
  }

  Future<void> care(PetAction action) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(busy: true, clearError: true);
    try {
      await client.pets.care(chatId, action);
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> rename(String name) async {
    final client = ref.read(clientProvider);
    state = state.copyWith(busy: true, clearError: true);
    try {
      await client.pets.rename(chatId, name);
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> accept() async {
    final id = state.record?.id;
    if (id == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await ref.read(clientProvider).pets.accept(id);
      await _load();
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
    } finally {
      if (ref.mounted) state = state.copyWith(busy: false);
    }
  }

  Future<void> decline() async {
    final id = state.record?.id;
    if (id == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await ref.read(clientProvider).pets.decline(id);
      if (ref.mounted) {
        state = state.copyWith(clearRecord: true, busy: false, loading: false);
      }
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
    }
  }

  Future<void> release() async {
    final id = state.record?.id;
    if (id == null) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await ref.read(clientProvider).pets.release(id);
      if (ref.mounted) {
        state = state.copyWith(clearRecord: true, busy: false, loading: false);
      }
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
    }
  }

  Future<void> refresh() => _load();
}

final petProvider = NotifierProvider.family<PetController, PetUiState, String>(
  PetController.new,
);
