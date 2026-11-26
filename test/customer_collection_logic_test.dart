import 'package:flutter_test/flutter_test.dart';
import 'package:tuna_sales_ledger/main.dart';

void main() {
  group('invoice financial validation guard', () {
    test('cash invoice must be fully paid', () {
      expect(saleFinancialValuesAllowed(10000, 10000, 'نقدي', false), isTrue);
      expect(saleFinancialValuesAllowed(10000, 9999, 'نقدي', true), isFalse);
    });
    test('credit invoice needs customer and paid cannot exceed total', () {
      expect(saleFinancialValuesAllowed(10000, 3000, 'آجل', true), isTrue);
      expect(saleFinancialValuesAllowed(10000, 3000, 'آجل', false), isFalse);
      expect(saleFinancialValuesAllowed(10000, 10001, 'آجل', true), isFalse);
    });
    test('rejects zero, negative, non-finite, and unknown type values', () {
      expect(saleFinancialValuesAllowed(0, 0, 'نقدي', false), isFalse);
      expect(saleFinancialValuesAllowed(10000, -1, 'آجل', true), isFalse);
      expect(saleFinancialValuesAllowed(double.nan, 0, 'آجل', true), isFalse);
      expect(saleFinancialValuesAllowed(10000, double.infinity, 'آجل', true), isFalse);
      expect(saleFinancialValuesAllowed(10000, 0, 'شيء آخر', true), isFalse);
    });
  });


  group('invoice deletion protection with pooled customer receipts', () {
    test('allows deletion when no receipts would be orphaned', () {
      expect(invoiceDeletionAllowed(12000, 7000, 5000), isTrue);
      expect(invoiceDeletionAllowed(12000, 7000, 4000), isTrue);
    });
    test('blocks deletion when pooled receipts exceed remaining invoices debt', () {
      expect(invoiceDeletionAllowed(12000, 7000, 5001), isFalse);
    });
    test('allows deleting fully paid invoice with pooled receipts', () {
      expect(invoiceDeletionAllowed(8000, 0, 8000), isTrue);
    });
    test('rejects invalid or inconsistent deletion balances', () {
      expect(invoiceDeletionAllowed(-1, 0, 0), isFalse);
      expect(invoiceDeletionAllowed(100, 101, 10), isFalse);
      expect(invoiceDeletionAllowed(100, 10, -1), isFalse);
      expect(invoiceDeletionAllowed(double.nan, 10, 5), isFalse);
    });
  });

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
