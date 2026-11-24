/// Sanitizes text before passing it to pdf_text_shaper with the bundled Arabic font.
/// The font does not include the ASCII hyphen-minus; strip all dash variants so
/// dynamically generated invoice identifiers/negative values cannot crash shaping.
String sanitizePdfText(String value) => value
    .replaceAll(RegExp(r'[\u002D\u2010-\u2015\u2212\uFE58\uFE63\uFF0D]'), ' ')
    .replaceAll('•', '،');
