import 'package:coralink/core/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('phone validation', () {
    test('accepts international numbers', () {
      expect(isValidPhone('+79991234567'), isTrue);
      expect(isValidPhone('89991234567'), isTrue);
    });

    test('rejects short numbers', () {
      expect(isValidPhone('123'), isFalse);
      expect(isValidPhone(''), isFalse);
    });

    test('normalizes punctuation', () {
      expect(normalizePhone('+7 (999) 123-45-67'), '+79991234567');
    });

    test('masks the middle of a number', () {
      expect(maskPhone('+79991234567'), '+79 *** ** 67');
    });
  });

  test('initials are generated from a name', () {
    expect(initials('Иван Петров'), 'ИП');
    expect(initials('Анна'), 'А');
  });
}
