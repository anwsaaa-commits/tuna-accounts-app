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
