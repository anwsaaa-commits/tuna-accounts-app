// Regression coverage for the PDF font's missing ASCII hyphen and real PDF rendering.
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_text_shaper/pdf_text_shaper.dart';
import '../lib/pdf_text_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Arabic font supports Arabic labels and digits', () async {
    final data = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final font = ShapedFont.fromBytes(bytes, name: 'Noto Naskh Arabic');
    try {
      const sample = 'السلام عليكم فاتورة 12345 ريال';
      final diagnostics = ShapedFontDiagnostics(font);
      expect(diagnostics.supports(sample), isTrue, reason: diagnostics.report(sample));
    } finally {
      font.dispose();
    }
  });

  test('sanitizer removes ASCII hyphen and dash variants from dynamic invoice text', () {
    const source = 'فاتورة TP-123 / 2026-11-25: 12345 • ريال';
    final cleaned = sanitizePdfText(source);
    expect(cleaned.runes, isNot(contains(0x002D)));
    expect(cleaned, contains('123'));
    expect(cleaned, contains('،'));
  });

  test('sanitized Arabic invoice/report text can be shaped and saved as PDF', () async {
    final data = await rootBundle.load('assets/fonts/NotoNaskhArabic-Regular.ttf');
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final font = ShapedFont.fromBytes(bytes, name: 'Noto Naskh Arabic');
    try {
      const source = 'فاتورة TP-123 / 2026-11-25: 12345 • ريال';
      final cleaned = sanitizePdfText(source);
      final diagnostics = ShapedFontDiagnostics(font);
      expect(diagnostics.supports(cleaned), isTrue, reason: diagnostics.report(cleaned));

      final document = pw.Document();
      document.addPage(pw.Page(build: (_) => pw.Column(children: [
        ShapedText(cleaned, style: ShapedTextStyle(font: font, fontSize: 12, preserveUnicodeText: false)),
        ShapedText(sanitizePdfText('التقرير - إجمالي البيع 2500 ر.ي'), style: ShapedTextStyle(font: font, fontSize: 12, preserveUnicodeText: false)),
      ])));
      final output = await document.save();
      expect(output, isNotEmpty);
      expect(output.length, greaterThan(500));
    } finally {
      font.dispose();
    }
  });
}
