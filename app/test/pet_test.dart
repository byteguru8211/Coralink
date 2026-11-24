import 'package:coralink/domain/models.dart';
import 'package:coralink/domain/pet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final born = DateTime(2026, 1, 1, 12);

  PetState newPet({PetSpecies species = PetSpecies.coral}) => PetState.adopt(
    chatId: 'chat-1',
    species: species,
    name: 'Reef',
    adopterId: 'alice',
    now: born,
  );

  group('shared Tamagotchi', () {
    test('adoption starts young, cared for and with one caretaker', () {
      final pet = newPet();
      expect(pet.stage, PetStage.seed);
      expect(pet.hunger, 72);
      expect(pet.joy, 82);
      expect(pet.energy, 92);
      expect(pet.caretakers, {'alice': 0});
      expect(pet.level, 1);
    });

    test('feeding raises fullness and experience but costs energy', () {
      final pet = newPet();
      final fed = pet.care(
        PetAction.feed,
        'alice',
        born.add(const Duration(minutes: 1)),
      );
      expect(fed.hunger, greaterThan(pet.hunger));
      expect(fed.energy, lessThan(pet.energy));
      expect(fed.xp, 3);
      expect(fed.caretakers['alice'], 1);
      expect(
        fed.revision,
        born.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      );
    });

    test('cooldown blocks a second action inside the window', () {
      final pet = newPet();
      final fed = pet.care(
        PetAction.feed,
        'alice',
        born.add(const Duration(minutes: 1)),
      );
      final again = fed.care(
        PetAction.feed,
        'alice',
        born.add(const Duration(minutes: 2)),
      );
      expect(identical(again, fed), isTrue);
      expect(
        again.cooldownLeft(
          PetAction.feed,
          born.add(const Duration(minutes: 2)),
        ),
        const Duration(minutes: 4),
      );
    });

    test('two participants grow the same pet', () {
      var pet = newPet();
      pet = pet.care(
        PetAction.feed,
        'alice',
        born.add(const Duration(minutes: 1)),
      );
      pet = pet.care(
        PetAction.play,
        'bob',
        born.add(const Duration(minutes: 4)),
      );
      expect(pet.caretakers.keys, containsAll(['alice', 'bob']));
      expect(pet.xp, 8);
    });

    test('decay is lazy and time based', () {
      final pet = newPet();
      final later = pet.tick(born.add(const Duration(hours: 6)));
      expect(later.hunger, lessThan(pet.hunger));
      expect(later.joy, lessThan(pet.joy));
      expect(later.energy, lessThan(pet.energy));
      expect(later.revision, pet.revision);
    });

    test('stages follow experience', () {
      expect(petStageForXp(0), PetStage.seed);
      expect(petStageForXp(29), PetStage.seed);
      expect(petStageForXp(30), PetStage.sprout);
      expect(petStageForXp(90), PetStage.young);
      expect(petStageForXp(200), PetStage.adult);
    });

    test('state survives a JSON round trip', () {
      final pet = newPet(
        species: PetSpecies.turtle,
      ).care(PetAction.play, 'bob', born.add(const Duration(minutes: 5)));
      final restored = PetState.fromJson(pet.toJson());
      expect(restored, isNotNull);
      expect(restored!.species, PetSpecies.turtle);
      expect(restored.name, 'Reef');
      expect(restored.xp, pet.xp);
      expect(restored.caretakers, pet.caretakers);
      expect(restored.toJson(), pet.toJson());
    });

    test('newer revisions win, ties prefer more experience', () {
      final pet = newPet();
      final older = pet.care(
        PetAction.care,
        'alice',
        born.add(const Duration(minutes: 2)),
      );
      final newer = older.care(
        PetAction.play,
        'bob',
        born.add(const Duration(minutes: 10)),
      );
      expect(mergePet(newer, older).revision, newer.revision);
      expect(mergePet(older, newer).revision, newer.revision);
      final tie = newer.copyWith(xp: newer.xp + 5);
      expect(mergePet(newer, tie).xp, tie.xp);
    });

    test('care checkpoints decay without applying it twice', () {
      final pet = newPet();
      final first = pet.tick(
        born.add(const Duration(minutes: 17, seconds: 30)),
      );
      expect(first.lastTick, born);
      expect(first.hunger, pet.hunger);
      final second = first.tick(born.add(const Duration(minutes: 18)));
      expect(second.hunger, pet.hunger - 1);
      final cared = second.care(
        PetAction.care,
        'alice',
        born.add(const Duration(minutes: 18, seconds: 20)),
      );
      expect(
        cared.lastTick,
        born.add(const Duration(minutes: 18, seconds: 20)),
      );
      final afterMinute = cared.tick(
        born.add(const Duration(minutes: 19, seconds: 20)),
      );
      expect(afterMinute.hunger, cared.hunger);
    });

    test('malformed state is rejected instead of throwing', () {
      final json = newPet().toJson();
      expect(PetState.fromJson({...json, 'name': 'x' * 25}), isNull);
      expect(PetState.fromJson({...json, 'v': 99}), isNull);
      expect(PetState.fromJson({...json, 'species': 'unknown'}), isNull);
    });

    test('direct pet resolves the local chat id for both participants', () {
      final record = PetRecord(
        id: 'pet-1',
        scope: PetScope.direct,
        chatId: 'direct:a:b',
        ownerId: 'a',
        status: 'active',
        membershipState: 'active',
        role: 'member',
        encryptedSnapshot: '',
        seq: 0,
        members: const [
          PetMember(userId: 'a', role: 'owner', state: 'active', name: 'Alice'),
          PetMember(userId: 'b', role: 'member', state: 'active', name: 'Bob'),
        ],
      );
      expect(record.localChatId('a'), 'b');
      expect(record.localChatId('b'), 'a');
    });

    test('wire kind carries the pet through the message model', () {
      expect(messageKindFromWire('pet'), MessageKind.pet);
      expect(messageKindToWire(MessageKind.pet), 'pet');
      final message = Message(
        id: 'm1',
        chatId: 'chat-1',
        senderId: 'alice',
        kind: MessageKind.pet,
        createdAt: born,
        meta: {'pet': 'feed'},
      );
      expect(message.isPet, isTrue);
      expect(message.isControl, isFalse);
    });
  });
}
