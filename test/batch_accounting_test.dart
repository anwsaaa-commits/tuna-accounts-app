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

    test('zero net weight never divides by zero', () {
      expect(batchUnitCost(150000, 27000, 0), 0);
    });
  });
}
