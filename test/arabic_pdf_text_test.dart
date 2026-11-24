import 'package:arabic_reshaper/arabic_reshaper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Arabic PDF text shaping', () {
    test('converts Arabic letters to connected presentation forms', () {
      const source = 'السلام عليكم';
      final shaped = ArabicReshaper.instance.reshape(source);
      expect(shaped, isNot(source));
      expect(shaped, contains('ﻟ'));
    });

    test('keeps invoice digits intact while shaping Arabic labels', () {
      final shaped = ArabicReshaper.instance.reshape('فاتورة 12345');
      expect(shaped, contains('12345'));
      expect(shaped, isNot('فاتورة 12345'));
    });
  });
}
