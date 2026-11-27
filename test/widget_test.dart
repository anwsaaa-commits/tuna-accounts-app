import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tuna_sales_ledger/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('Tuna Plus dashboard renders its home screen', (tester) async {
    await tester.pumpWidget(const TunaApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('تونة بلس'), findsWidgets);
    expect(find.text('إدارة مبيعات التونة بالكيلو'), findsOneWidget);
    expect(find.text('الرئيسية'), findsWidgets);
  });
}

  group('Financial allocation integrity scenarios', () {
    test('one invoice split across two purchase batches preserves full revenue', () {
      const invoiceTotal = 32500;
      const invoiceKg = 5.0;
      const batchAkg = 3.0;
      const batchBkg = 2.0;
      final shareA = allocationRevenueShare(invoiceTotal, invoiceKg, batchAkg);
      final shareB = allocationRevenueShare(invoiceTotal, invoiceKg, batchBkg);
      expect(saleAllocationsMatchInvoice(invoiceKg, [batchAkg, batchBkg]), isTrue);
      expect(shareA, 19500.0);
      expect(shareB, 13000.0);
      expect(shareA + shareB, invoiceTotal.toDouble());
    });

    test('proportional shares across uneven fractional allocations sum to invoice', () {
      const total = 50000;
      const kg = 7.0;
      final allocations = [1.333, 2.667, 3.0];
      final shares = allocations.map((a) => allocationRevenueShare(total, kg, a)).toList();
      expect(saleAllocationsMatchInvoice(kg, allocations), isTrue);
      expect(shares.fold<double>(0, (sum, value) => sum + value), closeTo(total, 0.000001));
    });

    test('partial or excess invoice allocation is not reconciled', () {
      expect(saleAllocationsMatchInvoice(5, [3, 1.9]), isFalse);
      expect(saleAllocationsMatchInvoice(5, [3, 2.1]), isFalse);
      expect(saleAllocationMismatch(5, 4.9), isTrue);
      expect(saleAllocationMismatch(5, 5.1), isTrue);
    });

    test('allocation cannot exceed invoice quantity and invalid values fail', () {
      expect(allocationRevenueShareAllowed(32500, 5, 5.0002), isFalse);
      expect(allocationRevenueShareAllowed(32500, 5, 0), isFalse);
      expect(allocationRevenueShareAllowed(32500, 5, double.nan), isFalse);
    });

    test('batch over-allocation blocks integrity and reliable final profit', () {
      expect(batchAllocationOverage(10.0002, 10), isTrue);
      expect(batchAllocationOverage(10, 10), isFalse);
      expect(globalProfitFinalAllowed(2, 0, 0, false), isFalse);
      expect(globalProfitFinalAllowed(2, 0, 0, true), isTrue);
    });
  });
