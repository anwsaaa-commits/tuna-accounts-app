import 'package:flutter_test/flutter_test.dart';
import 'package:tuna_sales_ledger/main.dart';

void main() {
  group('Tuna Plus batch accounting', () {
    test('batch net-kilo cost includes purchase expenses in capital', () {
      // 50 kg × 3,000 YER + 27,000 YER batch expenses, divided by 39 net kg.
      expect(batchUnitCost(150000, 27000, 39), closeTo(4538.461538, 0.0001));
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

    test('allocation gaps are detected even if migration warning is absent', () {
      expect(unallocatedSaleKg(10, 8, 0), closeTo(2, 0.00001));
    });

    test('migration warning is not double counted against calculated gap', () {
      expect(unallocatedSaleKg(10, 8, 2), closeTo(2, 0.00001));
      expect(unallocatedSaleKg(10, 8, 3), closeTo(3, 0.00001));
    });

    test('allocation-gap helper rejects invalid values', () {
      expect(unallocatedSaleKg(double.nan, 0, 0), 0);
      expect(unallocatedSaleKg(5, -1, 0), 0);
      expect(unallocatedSaleKg(5, 6, 0), 0);
    });

    test('zero net weight never divides by zero', () {
      expect(batchUnitCost(150000, 27000, 0), 0);
    });
  });
}
