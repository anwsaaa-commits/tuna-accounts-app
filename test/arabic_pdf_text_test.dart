// Regression coverage for Arabic shaping, mixed Latin glyph fallback, and actual PDF saving.
import 'package:flutter/services.dart'' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf_text_shaper/pdf_text_shaper.dart';
import '../lib/pdf_text_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ShapedFont> loadFont(String asset, String name) async {
    final data = await rootBundle.load(asset);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    return ShapedFont.fromBytes(bytes, name: name);
  }

  test('Arabic font supports Arabic labels and digits', () async {
    final font = await loadFont('assets/fonts/NotoNaskhArabic-Regular.ttf', 'Noto Naskh Arabic');
    try {
      const sample = 'السلام عليكم فاتورة 12345 ريال';
      final diagnostics = ShapedFontDiagnostics(font);
      expect(diagnostics.supports(sample), isTrue, reason: diagnostics.report(sample));
    } finally {
      font.dispose();
    }
  });

  test('preserves mixed-language invoice identifiers and punctuation', () {
    const source = 'فاتورة TP-123 / 2026-11-25: 12345 • ريال';
    final cleaned = sanitizePdfText(source);
    expect(cleaned, contains('TP-123'));
    expect(cleaned, contains('/'));
    expect(cleaned, contains('2026-11-25'));
    expect(cleaned, contains('12345'));
    expect(cleaned, contains('،'));
  });

  test('mixed Arabic and Latin text shapes with fallback and saves a real PDF', () async {
    final arabic = await loadFont('assets/fonts/NotoNaskhArabic-Regular.ttf', 'Noto Naskh Arabic');
    final latin = await loadFont('assets/fonts/NotoSans-Regular.ttf', 'Noto Sans Latin');
    try {
      const sample = 'فاتورة TP-123 / 2026-11-25: 12345 • ريال';
      final arabicDiagnostics = ShapedFontDiagnostics(arabic);
      final latinDiagnostics = ShapedFontDiagnostics(latin);
      expect(arabicDiagnostics.supports('فاتورة ريال'), isTrue, reason: arabicDiagnostics.report('فاتورة ريال'));
      expect(latinDiagnostics.supports('TP-123 / 2026-11-25: 12345'), isTrue, reason: latinDiagnostics.report('TP-123 / 2026-11-25: 12345'));

      final document = pw.Document();
      document.addPage(pw.Page(build: (_) => pw.Column(children: [
        ShapedText(sanitizePdfText(sample), style: ShapedTextStyle(font: arabic, fallbackFonts: [latin], fontSize: 12, preserveUnicodeText: false)),
        ShapedText(sanitizePdfText('التقرير - إجمالي البيع 2500 ر.ي'), style: ShapedTextStyle(font: arabic, fallbackFonts: [latin], fontSize: 12, preserveUnicodeText: false)),
      ])));
      final output = await document.save();
      expect(output, isNotEmpty);
      expect(output.length, greaterThan(500));
      expect(String.fromCharCodes(output.take(5)), startsWith('%PDF-'));
    } finally {
      arabic.dispose();
      latin.dispose();
    }
  });
}
