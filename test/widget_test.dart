import 'package:flutter_test/flutter_test.dart';
import 'package:tuna_sales_ledger/main.dart';

void main() {
  testWidgets('Tuna Plus app starts and displays home', (tester) async {
    await tester.pumpWidget(const TunaApp());
    await tester.pumpAndSettle();
    expect(find.text('تونة بلس'), findsWidgets);
    expect(find.text('بيع جديد'), findsOneWidget);
  });
}
