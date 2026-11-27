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

  group('Invoice edit financial validation scenarios', () {
    test('editing invoice totals and paid amounts obey cash and credit rules', () {
      expect(saleFinancialEditAllowed(12000, 12000, 'نقدي', false), isTrue);
      expect(saleFinancialEditAllowed(12000, 11000, 'نقدي', false), isFalse);
      expect(saleFinancialEditAllowed(12000, 0, 'آجل', true), isTrue);
      expect(saleFinancialEditAllowed(12000, 5000, 'آجل', true), isTrue);
      expect(saleFinancialEditAllowed(12000, 12001, 'آجل', true), isFalse);
      expect(saleFinancialEditAllowed(12000, 0, 'آجل', false), isFalse);
      expect(saleFinancialEditAllowed(0, 0, 'نقدي', false), isFalse);
      expect(saleFinancialEditAllowed(-100, 0, 'آجل', true), isFalse);
    });
  });

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
    test('invoice deletion preserves pooled customer collection coverage', () {
      expect(invoiceDeletionAllowed(10000, 4000, 5000), isTrue);
      expect(invoiceDeletionAllowed(10000, 6000, 5000), isFalse);
      expect(invoiceDeletionAllowed(10000, 4000, 7000), isFalse);
    });

    test('purchase financial values stay protected after sales attach', () {
      expect(batchFinancialEditAllowed(0, 10, 5000, 8, 12, 6000, 9), isTrue);
      expect(batchFinancialEditAllowed(2, 10, 5000, 8, 10, 5000, 8), isTrue);
      expect(batchFinancialEditAllowed(2, 10, 5000, 8, 11, 5000, 8), isFalse);
      expect(batchFinancialEditAllowed(2, 10, 5000, 8, 10, 5001, 8), isFalse);
      expect(batchFinancialEditAllowed(2, 10, 5000, 8, 10, 5000, 7.9), isFalse);
      expect(batchFinancialEditAllowed(double.nan, 10, 5000, 8, 10, 5000, 8), isFalse);
    });

    test('batch expense amount changes are blocked after allocated sales', () {
      expect(batchExpenseFinancialEditAllowed(0), isTrue);
      expect(batchExpenseFinancialEditAllowed(0.00005), isTrue);
      expect(batchExpenseFinancialEditAllowed(1), isFalse);
      expect(batchExpenseFinancialEditAllowed(-1), isFalse);
      expect(batchExpenseFinancialEditAllowed(double.nan), isFalse);
    });

    test('invoice edits preserve pooled customer collection coverage', () {
      expect(customerInvoiceEditCollectionCoverageAllowed(10000, 4000, 5000, 4000), isTrue);
      expect(customerInvoiceEditCollectionCoverageAllowed(10000, 4000, 5000, 0), isTrue);
      expect(customerInvoiceEditCollectionCoverageAllowed(10000, 4000, 8000, 1000), isFalse);
      expect(customerInvoiceEditCollectionCoverageAllowed(10000, 4000, 7000, 0), isFalse);
      expect(customerInvoiceEditCollectionCoverageAllowed(10000, 4000, 5000, -1), isFalse);
      expect(customerInvoiceEditCollectionCoverageAllowed(10000, 12000, 5000, 1000), isFalse);
    });

    test('customer ledger rejects invalid receipts and receipts above debt', () {
      expect(customerCollectionLedgerIntegrityAllowed([10000, 5000], [0, 0], [15000]), isTrue);
      expect(customerCollectionLedgerIntegrityAllowed([10000], [2000], [9000]), isFalse);
      expect(customerCollectionLedgerIntegrityAllowed([10000], [11000], []), isFalse);
      expect(collectionAmountAllowed(5000, 5000), isTrue);
      expect(collectionAmountAllowed(5000, 5001), isFalse);
      expect(collectionAmountAllowed(5000, 0), isFalse);
    });

    test('customer pooled ledger handles empty, fractional and overflow balances safely', () {
      expect(customerCollectionLedgerIntegrityAllowed([], [], []), isTrue);
      expect(customerCollectionLedgerIntegrityAllowed([], [], [1]), isFalse);
      expect(customerCollectionLedgerIntegrityAllowed([10.5, 20.25], [2.5, 5.25], [23]), isTrue);
      expect(customerCollectionLedgerIntegrityAllowed([10.5, 20.25], [2.5, 5.25], [23.001]), isFalse);
      expect(customerCollectionLedgerIntegrityAllowed([double.maxFinite, double.maxFinite], [0, 0], []), isFalse);
      expect(customerCollectionLedgerIntegrityAllowed([100], [0], [double.infinity]), isFalse);
      expect(customerCollectionLedgerIntegrityAllowed([100], [0], [-0.01]), isFalse);
    });

    test('invoice deletion requires complete valid batch allocation references', () {
      expect(saleDeletionAllocationIntegrityOk(5, 5, true, true), isTrue);
      expect(saleDeletionAllocationIntegrityOk(5, 4.9, true, true), isFalse);
      expect(saleDeletionAllocationIntegrityOk(5, 5, false, true), isFalse);
      expect(saleDeletionAllocationIntegrityOk(5, 5, true, false), isFalse);
    });

    test('batch profit reliability requires reconciled allocations', () {
      expect(batchStatementIntegrityAllowed(10, 20000, 500, 10, 26000, 0, true), isTrue);
      expect(batchStatementIntegrityAllowed(10, 20000, 500, 10, 26000, 0.1, true), isFalse);
      expect(batchStatementIntegrityAllowed(10, 20000, 500, 10, 26000, 0, false), isFalse);
      // Sold weight and revenue must agree: no revenue without a sale, and
      // no sold stock without its corresponding allocated revenue.
      expect(batchStatementIntegrityAllowed(10, 20000, 500, 0, 26000, 0, true), isFalse);
      expect(batchStatementIntegrityAllowed(10, 20000, 500, 2, 0, 0, true), isFalse);
      expect(batchStatementIntegrityAllowed(10, 20000, 500, 0, 0, 0, true), isTrue);
      expect(batchStatementIntegrityAllowed(10, 20000, 500, 11, 26000, 0, true), isFalse);
      expect(globalNetProfit(26000, 20500, 500), 5000);
    });

  });
  test('pooled receipt coverage across multiple invoice deletions', () {
    expect(invoiceDeletionAllowed(15000, 5000, 12000), isFalse);
    expect(invoiceDeletionAllowed(15000, 3000, 12000), isTrue);
    expect(invoiceDeletionAllowed(15000, 3000, 12000.0001), isFalse);
  });

  test('invoice deletion rejects nonfinite and invalid balances', () {
    expect(invoiceDeletionAllowed(double.nan, 1, 0), isFalse);
    expect(invoiceDeletionAllowed(100, double.infinity, 0), isFalse);
    expect(invoiceDeletionAllowed(100, -1, 0), isFalse);
    expect(invoiceDeletionAllowed(100, 101, 0), isFalse);
    expect(invoiceDeletionAllowed(100, 0, -1), isFalse);
  });

  test('invoice edit pooled coverage protects collected amounts', () {
    expect(customerInvoiceEditCollectionCoverageAllowed(20000, 8000, 12000, 8000), isTrue);
    expect(customerInvoiceEditCollectionCoverageAllowed(20000, 0, 12000, 0), isTrue);
    expect(customerInvoiceEditCollectionCoverageAllowed(20000, 8000, 12000, 0), isFalse);
    expect(customerInvoiceEditCollectionCoverageAllowed(20000, 8000, 12000, 1000), isTrue);
    expect(customerInvoiceEditCollectionCoverageAllowed(20000, 8000, 12000, 1.0001), isTrue);
  });

}
