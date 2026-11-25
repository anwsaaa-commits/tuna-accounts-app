/// Keep invoice identifiers and punctuation intact; use a fallback font for Latin glyphs.
String sanitizePdfText(String value) => value.replaceAll('•', '،');
