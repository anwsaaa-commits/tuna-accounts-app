import 'package:flutter_test/flutter_test.dart';
import 'package:tuna_sales_ledger/main.dart';

void main() {
  group('Tuna Plus batch accounting', () {
    test('purchase batch and its expense rows must be financially valid', () {
      expect(batchFinancialInputsAllowed(50, 39, 3000, 150000, [27000]), isTrue);
      expect(batchFinancialInputsAllowed(50, 51, 3000, 150000, [27000]), isFalse);
      expect(batchFinancialInputsAllowed(50, 39, 3000, 149999, [27000]), isFalse);
      expect(batchFinancialInputsAllowed(50, 39, 0, 150000, [27000]), isFalse);
      expect(batchFinancialInputsAllowed(50, 39, 3000, 150000, [double.nan]), isFalse);
      expect(batchFinancialInputsAllowed(50, 39, 3000, 150000, [-1]), isFalse);
      expect(batchFinancialInputsAllowed(50, 39, 3000, 150000, [0]), isFalse);
    });

    test('multi-batch invoice revenue is proportionally attributed to each allocation', () {
      const saleTotal=25000, saleKg=5.0;
      final firstBatchRevenue=allocationRevenueShare(saleTotal,saleKg,2.0);
      final secondBatchRevenue=allocationRevenueShare(saleTotal,saleKg,3.0);
      expect(firstBatchRevenue,closeTo(10000,0.0001));
      expect(secondBatchRevenue,closeTo(15000,0.0001));
      expect(firstBatchRevenue+secondBatchRevenue,closeTo(saleTotal,0.0001));
    });
    test('multi-batch revenue share rejects invalid or excessive allocation weights', () {
      expect(allocationRevenueShareAllowed(25000,5,2),isTrue);
      expect(allocationRevenueShareAllowed(25000,5,5.01),isFalse);
      expect(allocationRevenueShareAllowed(25000,0,2),isFalse);
      expect(allocationRevenueShareAllowed(double.nan,5,2),isFalse);
      expect(allocationRevenueShare(25000,5,6),0);
    });
    test('sale allocation rows must sum to invoice weight across batches', () {
      expect(saleAllocationsMatchInvoice(5,[2,3]),isTrue);
      expect(saleAllocationsMatchInvoice(5,[1.99995,3]),isTrue);
      expect(saleAllocationsMatchInvoice(5,[2,2.5]),isFalse);
      expect(saleAllocationsMatchInvoice(5,[5.1]),isFalse);
      expect(saleAllocationsMatchInvoice(5,[2,double.nan]),isFalse);
      expect(saleAllocationsMatchInvoice(0,[0]),isFalse);
    });

    test('batch net-kilo cost includes purchase expenses in capital', () {
      // 50 kg × 3,000 YER + 27,000 YER batch expenses, divided by 39 net kg.
      expect(batchUnitCost(150000, 27000, 39), closeTo(4538.461538, 0.0001));
    });

    test('batch statement profit reliability rejects invalid costs and stock mismatch', () {
      expect(batchStatementIntegrityAllowed(10, 50000, 1000, 10, 60000, 0, true), isTrue);
      expect(batchStatementIntegrityAllowed(10, 50000, 1000, 10.2, 60000, 0, true), isFalse);
      expect(batchStatementIntegrityAllowed(10, 50000, 1000, 5, 30000, 0.2, true), isFalse);
      expect(batchStatementIntegrityAllowed(10, -1, 1000, 5, 30000, 0, true), isFalse);
      expect(batchStatementIntegrityAllowed(10, 50000, double.nan, 5, 30000, 0, true), isFalse);
      expect(batchStatementIntegrityAllowed(0, 50000, 1000, 5, 30000, 0, true), isFalse);
      expect(batchStatementIntegrityAllowed(10, 50000, 1000, 5, 30000, 0, false), isFalse);
    });

    test('sale profit is calculated from batch unit cost, not average stock cost', () {
      final unitCost = batchUnitCost(150000, 27000, 39);
      expect(batchNetProfit(13000, 2, unitCost), closeTo(3923.076923, 0.001));
    });

    test('invalid negative or non-finite inputs are safely rejected', () {
      expect(batchUnitCost(-150000, 0, 39), 0);
      expect(batchUnitCost(150000, -27000, 39), 0);
      expect(batchUnitCost(150000, 27000, double.nan), 0);
      expect(batchNetProfit(13000, -2, 4500), 0);
      expect(batchNetProfit(double.infinity, 2, 4500), 0);
    });

    test('allocation discrepancies in either direction are detected without migration warning', () {
      expect(unallocatedSaleKg(10, 8, 0), closeTo(2, 0.00001));
      expect(unallocatedSaleKg(10, 12, 0), closeTo(2, 0.00001));
    });

    test('stale migration warning does not override the current sales-allocation gap', () {
      expect(unallocatedSaleKg(10, 8, 2), closeTo(2, 0.00001));
      expect(unallocatedSaleKg(10, 8, 3), closeTo(2, 0.00001));
      // After deleting an unallocated legacy sale, the current gap is zero.
      expect(unallocatedSaleKg(0, 0, 3), closeTo(0, 0.00001));
      // If part of the gap is resolved, only the remaining gap blocks profit.
      expect(unallocatedSaleKg(5, 4, 3), closeTo(1, 0.00001));
    });

    test('allocation-discrepancy helper rejects invalid values', () {
      expect(unallocatedSaleKg(double.nan, 0, 0), 0);
      expect(unallocatedSaleKg(5, -1, 0), 0);
      expect(unallocatedSaleKg(5, 6, 0), 1);
    });

    test('invoice deletion requires exact valid allocations to existing batches', () {
      expect(saleDeletionAllocationIntegrityOk(3, 3, true, true), isTrue);
      expect(saleDeletionAllocationIntegrityOk(3, 2.5, true, true), isFalse);
      expect(saleDeletionAllocationIntegrityOk(3, 3, false, true), isFalse);
      expect(saleDeletionAllocationIntegrityOk(3, 3, true, false), isFalse);
      expect(saleDeletionAllocationIntegrityOk(0, 0, true, true), isFalse);
      expect(saleDeletionAllocationIntegrityOk(3, double.nan, true, true), isFalse);
    });
    test('invoice allocation mismatch in either direction is flagged', () {
      expect(saleAllocationMismatch(4, 3.5), isTrue);
      expect(saleAllocationMismatch(4, 4), isFalse);
      expect(saleAllocationMismatch(4, 4.00001), isFalse);
    });

    test('batch stock allocation overage is flagged while valid allocation passes', () {
      expect(batchAllocationOverage(12, 10), isTrue);
      expect(batchAllocationOverage(10, 10), isFalse);
      expect(batchAllocationOverage(8, 10), isFalse);
    });

    test('offsetting batch over-allocation cannot be hidden by equal global totals', () {
      // Batch A: 10 kg stock, 12 kg allocated. Batch B: 10 kg stock, 8 kg allocated.
      expect((12 + 8) == (10 + 10), isTrue);
      expect(batchAllocationOverage(12, 10), isTrue);
      expect(batchAllocationOverage(8, 10), isFalse);
    });

    test('purchase financial values are locked after sales allocations', () {
      expect(batchFinancialEditAllowed(0, 50, 3000, 40, 48, 3200, 39), isTrue);
      expect(batchFinancialEditAllowed(2, 50, 3000, 40, 50, 3000, 40), isTrue);
      expect(batchFinancialEditAllowed(2, 50, 3000, 40, 50, 3500, 40), isFalse);
      expect(batchFinancialEditAllowed(2, 50, 3000, 40, 49, 3000, 40), isFalse);
      expect(batchFinancialEditAllowed(2, 50, 3000, 40, 50, 3000, 39), isFalse);
      expect(batchFinancialEditAllowed(double.nan, 50, 3000, 40, 50, 3000, 40), isFalse);
    });
    test('batch expense financial edits lock after allocations while note-only edits remain allowed', () {
      expect(batchExpenseFinancialEditAllowed(0), isTrue);
      expect(batchExpenseFinancialEditAllowed(0.00005), isTrue);
      expect(batchExpenseFinancialEditAllowed(1), isFalse);
      expect(batchExpenseFinancialEditAllowed(-1), isFalse);
      expect(batchExpenseFinancialEditAllowed(double.nan), isFalse);
      expect(batchExpenseFinancialEditAllowed(double.infinity), isFalse);
    });
    test('allocation rows must be positive finite weights', () {
      expect(allocationRowValid(0), isFalse);
      expect(allocationRowValid(-0.25), isFalse);
      expect(allocationRowValid(double.nan), isFalse);
      expect(allocationRowValid(double.infinity), isFalse);
      expect(allocationRowValid(0.001), isTrue);
    });

    test('invalid integrity helper inputs are treated as unreliable', () {
      expect(saleAllocationMismatch(double.nan, 0), isTrue);
      expect(batchAllocationOverage(5, double.infinity), isTrue);
    });

    test('global net profit deducts general expenses separately from batch cost', () {
      // Batch cost already includes batch expenses; only general expenses are deducted here.
      expect(globalNetProfit(200000, 120000, 15000), 65000);
    });

    test('global profit cannot be final with no purchase batches', () {
      expect(globalProfitFinalAllowed(0, 0, 0, true), isFalse);
    });
    test('global profit is final only when all inventory and allocations reconcile', () {
      expect(globalProfitFinalAllowed(2, 0, 0, true), isTrue);
      expect(globalProfitFinalAllowed(2, 0.5, 0, true), isFalse);
      expect(globalProfitFinalAllowed(2, 0, 1, true), isFalse);
      expect(globalProfitFinalAllowed(2, 0, 0, false), isFalse);
    });
    test('global profit helper rejects invalid values', () {
      expect(globalNetProfit(double.nan, 120000, 15000), 0);
      expect(globalNetProfit(200000, -1, 15000), 0);
      expect(globalNetProfit(200000, 120000, double.infinity), 0);
    });

    test('zero net weight never divides by zero', () {
      expect(batchUnitCost(150000, 27000, 0), 0);
    });

    test('odd invoice totals remain conserved across fractional multi-batch splits', () {
      const invoiceTotal = 12345;
      const invoiceKg = 7.3;
      final shares = [1.1, 2.2, 4.0]
          .map((kg) => allocationRevenueShare(invoiceTotal, invoiceKg, kg))
          .toList();
      expect(shares.reduce((a, b) => a + b), closeTo(invoiceTotal, 0.0001));
    });

    test('batch profit subtracts purchase expense through unit cost for fractional kilograms', () {
      final costPerKg = batchUnitCost(100000, 12500, 22.5);
      expect(costPerKg, closeTo(5000, 0.0001));
      expect(batchNetProfit(18750, 3.25, costPerKg), closeTo(2500, 0.0001));
    });

    test('partial batch remains non-final even when sold allocations reconcile', () {
      expect(batchStatementIntegrityAllowed(20, 90000, 5000, 19.5, 97500, 0, true), isTrue);
      expect(globalProfitFinalAllowed(1, 0.5, 0, true), isFalse);
    });
  });
}
