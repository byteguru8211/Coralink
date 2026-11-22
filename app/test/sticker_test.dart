import 'package:coralink/domain/models.dart';
import 'package:coralink/presentation/widgets/stickers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sticker messages round-trip through the wire kind', () {
    expect(messageKindToWire(MessageKind.sticker), 'sticker');
    expect(messageKindFromWire('sticker'), MessageKind.sticker);

    final message = Message(
      id: 'm1',
      chatId: 'c1',
      senderId: 'u1',
      kind: MessageKind.sticker,
      createdAt: DateTime(2026),
      meta: const {'sticker': 'wave'},
    );
    expect(message.isSticker, isTrue);
    expect(message.isImage, isFalse);
    expect(message.isControl, isFalse);
    expect(message.toRow()['kind'], 'sticker');
  });

  test('every sticker has a stable id and a localised name key', () {
    expect(kCoralStickers, hasLength(CoralSticker.values.length));
    for (final spec in kCoralStickers) {
      expect(stickerIdOf(spec.id), spec.id.name);
      expect(stickerFromId(spec.id.name), spec.id);
      expect(spec.nameKey, startsWith('sticker'));
    }
    expect(stickerFromId('unknown'), isNull);
    expect(stickerFromId(null), isNull);
  });
}
