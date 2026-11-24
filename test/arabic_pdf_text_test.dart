import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_shaper/pdf_text_shaper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled Noto Naskh font supports Arabic PDF labels and digits', () async {
    final data = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final font = ShapedFont.fromBytes(bytes, name: 'Noto Naskh Arabic');

    try {
      const sample = 'السلام عليكم فاتورة 12345 ريال';
      final diagnostics = ShapedFontDiagnostics(font);
      expect(
        diagnostics.supports(sample),
        isTrue,
        reason: diagnostics.report(sample),
      );
    } finally {
      font.dispose();
    }
  });
}
