import 'package:flutter_test/flutter_test.dart';
import 'package:tuna_sales_ledger/main.dart';

void main() {
  group('customer collection amount validation', () {
    test('accepts collection equal to outstanding balance', () {
      expect(collectionAmountAllowed(5000, 5000), isTrue);
    });
    test('accepts partial collection within outstanding balance', () {
      expect(collectionAmountAllowed(10000, 4000), isTrue);
    });
    test('rejects collection above outstanding balance', () {
      expect(collectionAmountAllowed(5000, 5001), isFalse);
    });
    test('rejects zero, negative, and invalid outstanding balances', () {
      expect(collectionAmountAllowed(5000, 0), isFalse);
      expect(collectionAmountAllowed(5000, -1), isFalse);
      expect(collectionAmountAllowed(-100, 10), isFalse);
      expect(collectionAmountAllowed(double.nan, 10), isFalse);
      expect(collectionAmountAllowed(100, double.infinity), isFalse);
    });
  });
}
