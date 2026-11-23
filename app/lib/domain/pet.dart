import 'dart:math' as math;

/// Coralink Tamagotchi: one little reef companion per conversation.
///
/// The pet is a shared, event-sourced creature. Every care action travels as an
/// end-to-end encrypted `pet` message that carries the resulting state, so both
/// people in a chat — and everybody in a group — grow the same companion
/// without the relay ever learning anything about it. State is deterministic:
/// given the same care events, every device reaches the same pet.
enum PetSpecies { coral, lotus, seaweed, turtle, fish, crab }

extension PetSpeciesInfo on PetSpecies {
  bool get isPlant => index < PetSpecies.turtle.index;

  String get id => name;

  /// Message key for the species name, e.g. `petSpeciesCoral`.
  String get nameKey => 'petSpecies${name[0].toUpperCase()}${name.substring(1)}';
}

PetSpecies? petSpeciesFromId(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final species in PetSpecies.values) {
    if (species.name == id) return species;
  }
  return null;
}

enum PetAction { feed, play, care, sleep }

PetAction? petActionFromId(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final action in PetAction.values) {
    if (action.name == id) return action;
  }
  return null;
}

/// Care actions are labelled differently for a plant and an animal, while the
/// underlying mechanics stay identical.
String petActionKey(PetAction action, PetSpecies species) {
  final kind = species.isPlant ? 'Plant' : 'Animal';
  final suffix = switch (action) {
    PetAction.feed => 'Feed',
    PetAction.play => 'Play',
    PetAction.care => 'Care',
    PetAction.sleep => 'Sleep',
  };
  return 'pet$kind$suffix';
}

String petActionIcon(PetAction action) => switch (action) {
      PetAction.feed => 'water_drop',
      PetAction.play => 'toys',
      PetAction.care => 'favorite',
      PetAction.sleep => 'bedtime',
    };

enum PetStage { seed, sprout, young, adult }

PetStage petStageForXp(int xp) {
  if (xp >= 200) return PetStage.adult;
  if (xp >= 90) return PetStage.young;
  if (xp >= 30) return PetStage.sprout;
  return PetStage.seed;
}

String petStageKey(PetStage stage, PetSpecies species) {
  final kind = species.isPlant ? 'Plant' : 'Animal';
  final suffix = switch (stage) {
    PetStage.seed => 'Seed',
    PetStage.sprout => 'Sprout',
    PetStage.young => 'Young',
    PetStage.adult => 'Adult',
  };
  return 'petStage$kind$suffix';
}

const Map<PetAction, Duration> kPetCooldowns = {
  PetAction.feed: Duration(minutes: 5),
  PetAction.play: Duration(minutes: 3),
  PetAction.care: Duration(minutes: 2),
  PetAction.sleep: Duration(minutes: 60),
};

/// A care action only reaches its full effect when the companion is actually
/// due for it: over-feeding a full pet wastes the action's experience.
class PetState {
  const PetState({
    required this.chatId,
    required this.species,
    required this.name,
    required this.bornAt,
    required this.xp,
    required this.hunger,
    required this.joy,
    required this.energy,
    required this.lastTick,
    required this.revision,
    required this.adopterId,
    this.actions = const {},
    this.caretakers = const {},
  });

  final String chatId;
  final PetSpecies species;
  final String name;
  final DateTime bornAt;
  final int xp;
  final int hunger;
  final int joy;
  final int energy;

  /// Last moment decay was folded into the stats. Decay is applied lazily, so a
  /// pet left alone for a day greets you a little hungry, not frozen in time.
  final DateTime lastTick;

  /// Monotonic version of this pet, in epoch milliseconds of the last change.
  /// Devices merge by it, so a late copy never rolls a grown pet back.
  final int revision;

  final String adopterId;

  /// Last time each action was used, to enforce cooldowns across devices.
  final Map<String, int> actions;

  /// How many care actions each participant contributed — the "growing
  /// together" counter on the pet card.
  final Map<String, int> caretakers;

  PetStage get stage => petStageForXp(xp);

  int get level => math.min(20, 1 + xp ~/ 50);

  int get nextStageXp => switch (stage) {
        PetStage.seed => 30,
        PetStage.sprout => 90,
        PetStage.young => 200,
        PetStage.adult => 200,
      };

  double get stageProgress {
    final floorXp = switch (stage) {
      PetStage.seed => 0,
      PetStage.sprout => 30,
      PetStage.young => 90,
      PetStage.adult => 200,
    };
    if (stage == PetStage.adult) return 1;
    return ((xp - floorXp) / (nextStageXp - floorXp)).clamp(0.0, 1.0);
  }

  int get wellbeing => ((hunger + joy + energy) / 3).round();

  bool get isHappy => wellbeing >= 70;
  bool get isSad => wellbeing < 35;

  bool get isNeglected => hunger < 20 || joy < 20;

  DateTime get lastActionAt {
    var latest = 0;
    for (final value in actions.values) {
      if (value > latest) latest = value;
    }
    return DateTime.fromMillisecondsSinceEpoch(latest);
  }

  static PetState adopt({
    required String chatId,
    required PetSpecies species,
    required String name,
    required String adopterId,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return PetState(
      chatId: chatId,
      species: species,
      name: name.trim().isEmpty ? 'Coral' : name.trim(),
      bornAt: at,
      xp: 0,
      hunger: 72,
      joy: 82,
      energy: 92,
      lastTick: at,
      revision: at.millisecondsSinceEpoch,
      adopterId: adopterId,
      caretakers: {adopterId: 0},
    );
  }

  /// Folds elapsed time into the stats. Hunger falls fastest, energy slowest.
  PetState tick(DateTime now) {
    final minutes = now.difference(lastTick).inMinutes;
    if (minutes <= 0) return this;
    return copyWith(
      hunger: clampStat(hunger - minutes ~/ 18),
      joy: clampStat(joy - minutes ~/ 22),
      energy: clampStat(energy - minutes ~/ 30),
      lastTick: now,
      revision: revision,
    );
  }

  Duration cooldownLeft(PetAction action, DateTime now) {
    final last = actions[action.name];
    if (last == null) return Duration.zero;
    final elapsed = now.difference(DateTime.fromMillisecondsSinceEpoch(last));
    final remaining = kPetCooldowns[action]! - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// True when the action would still do something meaningful.
  bool actionWouldHelp(PetAction action) => switch (action) {
        PetAction.feed => hunger < 96,
        PetAction.play => energy > 12 && joy < 98,
        PetAction.care => joy < 98,
        PetAction.sleep => energy < 96,
      };

  /// Applies one care action. Returns the same state when the cooldown has not
  /// elapsed, so duplicate taps and replayed messages are harmless.
  PetState care(PetAction action, String userId, DateTime now) {
    if (cooldownLeft(action, now) > Duration.zero) return this;
    final before = tick(now);
    final helpful = before.actionWouldHelp(action);
    var h = before.hunger;
    var j = before.joy;
    var e = before.energy;
    var gainedXp = 0;
    switch (action) {
      case PetAction.feed:
        h += helpful ? 22 : 4;
        j += 3;
        e -= 4;
        gainedXp = helpful ? 3 : 1;
      case PetAction.play:
        j += helpful ? 18 : 3;
        e -= helpful ? 10 : 2;
        h -= 3;
        gainedXp = helpful ? 5 : 1;
      case PetAction.care:
        j += helpful ? 10 : 2;
        e += 2;
        gainedXp = helpful ? 2 : 1;
      case PetAction.sleep:
        e = 100;
        j += 2;
        gainedXp = 2;
    }
    final caretakers = Map<String, int>.from(before.caretakers);
    caretakers[userId] = (caretakers[userId] ?? 0) + 1;
    return PetState(
      chatId: before.chatId,
      species: before.species,
      name: before.name,
      bornAt: before.bornAt,
      xp: before.xp + gainedXp,
      hunger: clampStat(h),
      joy: clampStat(j),
      energy: clampStat(e),
      lastTick: now,
      revision: now.millisecondsSinceEpoch,
      adopterId: before.adopterId,
      actions: {...before.actions, action.name: now.millisecondsSinceEpoch},
      caretakers: caretakers,
    );
  }

  PetState rename(String newName, DateTime now) => copyWith(
        name: newName.trim(),
        revision: now.millisecondsSinceEpoch,
      );

  PetState copyWith({
    String? name,
    int? xp,
    int? hunger,
    int? joy,
    int? energy,
    DateTime? lastTick,
    int? revision,
    Map<String, int>? actions,
    Map<String, int>? caretakers,
  }) =>
      PetState(
        chatId: chatId,
        species: species,
        name: name ?? this.name,
        bornAt: bornAt,
        xp: xp ?? this.xp,
        hunger: hunger ?? this.hunger,
        joy: joy ?? this.joy,
        energy: energy ?? this.energy,
        lastTick: lastTick ?? this.lastTick,
        revision: revision ?? this.revision,
        adopterId: adopterId,
        actions: actions ?? this.actions,
        caretakers: caretakers ?? this.caretakers,
      );

  /// Compact, wire-friendly form carried inside the encrypted pet message.
  Map<String, dynamic> toJson() => {
        'v': 1,
        'chatId': chatId,
        'species': species.id,
        'name': name,
        'bornAt': bornAt.millisecondsSinceEpoch,
        'xp': xp,
        'hunger': hunger,
        'joy': joy,
        'energy': energy,
        'lastTick': lastTick.millisecondsSinceEpoch,
        'revision': revision,
        'adopter': adopterId,
        'actions': actions,
        'caretakers': caretakers,
      };

  static PetState? fromJson(Map<String, dynamic> json) {
    final species = petSpeciesFromId(json['species'] as String?);
    final chatId = json['chatId'] as String?;
    if (species == null || chatId == null || chatId.isEmpty) return null;
    int stamp(Object? value, int fallback) =>
        value is num ? value.toInt() : fallback;
    final now = DateTime.now().millisecondsSinceEpoch;
    return PetState(
      chatId: chatId,
      species: species,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? json['name'] as String
          : 'Coral',
      bornAt: DateTime.fromMillisecondsSinceEpoch(stamp(json['bornAt'], now)),
      xp: math.max(0, stamp(json['xp'], 0)),
      hunger: clampStat(stamp(json['hunger'], 60)),
      joy: clampStat(stamp(json['joy'], 60)),
      energy: clampStat(stamp(json['energy'], 60)),
      lastTick: DateTime.fromMillisecondsSinceEpoch(
        stamp(json['lastTick'], now),
      ),
      revision: stamp(json['revision'], now),
      adopterId: (json['adopter'] as String?) ?? '',
      actions: _intMap(json['actions']),
      caretakers: _intMap(json['caretakers']),
    );
  }

  static Map<String, int> _intMap(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, int>{};
    raw.forEach((key, value) {
      if (key is String && value is num) result[key] = value.toInt();
    });
    return result;
  }
}

int clampStat(int value) => value.clamp(0, 100);

/// Merges a state received from another device. The newer revision wins; ties
/// are broken by the higher experience so concurrent care never downgrades.
PetState mergePet(PetState? current, PetState incoming) {
  if (current == null) return incoming;
  if (incoming.revision > current.revision) return incoming;
  if (incoming.revision == current.revision && incoming.xp > current.xp) {
    return incoming;
  }
  return current;
}
