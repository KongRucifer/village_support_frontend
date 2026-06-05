import 'dart:convert';

/// Parsed identity from a scanned QR: must carry vbCode + bankbookNumber.
/// `accNumber` is optional but strongly recommended for precise matching.
///
/// Accepted formats:
///   1. JSON  → {"vbCode":"0101001","bankbookNumber":"00001","accNumber":"010100100000001"}
///   2. JSON  → {"vbCode":"0101001","bankbookNumber":"00001"}  (no accNumber)
///   3. key=value → vbCode=0101001;bankbookNumber=00001;accNumber=010100100000001
///   4. delimited → 0101001|00001|010100100000001  (7-char=vbCode, 5-char=bankbook, 15-char=acc)
class QrPayload {
  final String vbCode;
  final String bankbookNumber;
  final String? accNumber; // optional — used for precise account matching

  QrPayload({
    required this.vbCode,
    required this.bankbookNumber,
    this.accNumber,
  });

  /// Triple check: vbCode + bankbookNumber + accNumber (if both sides have it).
  bool matches({
    required String vbCode,
    required String bankbookNumber,
    String? accNumber,
  }) {
    if (this.vbCode.trim() != vbCode.trim()) return false;
    if (this.bankbookNumber.trim() != bankbookNumber.trim()) return false;
    // If the QR carries an accNumber AND the expected accNumber is provided, they must match.
    if (accNumber != null && this.accNumber != null) {
      return this.accNumber!.trim() == accNumber.trim();
    }
    return true;
  }

  /// Canonical JSON. Include accNumber when you have it for strongest matching.
  static String encode({
    required String vbCode,
    required String bankbookNumber,
    String? accNumber,
  }) {
    final m = <String, String>{
      'vbCode': vbCode.trim(),
      'bankbookNumber': bankbookNumber.trim(),
    };
    if (accNumber != null && accNumber.trim().isNotEmpty) {
      m['accNumber'] = accNumber.trim();
    }
    return jsonEncode(m);
  }

  /// Returns null if the string doesn't contain at least vbCode + bankbookNumber.
  static QrPayload? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    // 1. JSON
    if (text.startsWith('{')) {
      try {
        final map = jsonDecode(text);
        if (map is Map) {
          final vb = _pick(map, ['vbCode', 'vbcode', 'vb_code', 'vb']);
          final bb = _pick(map, ['bankbookNumber', 'bankbooknumber', 'bankbook_number', 'bankbook', 'bb']);
          final acc = _pick(map, ['accNumber', 'accnumber', 'acc_number', 'acc']);
          if (vb != null && bb != null) {
            return QrPayload(vbCode: vb, bankbookNumber: bb, accNumber: acc);
          }
        }
      } catch (_) {}
    }

    // 2. key=value or plain delimited tokens
    final tokens = text.split(RegExp(r'[;&,|/ \t\n]+')).where((t) => t.isNotEmpty);
    String? vb;
    String? bb;
    String? acc;
    for (final tok in tokens) {
      final kv = tok.split('=');
      if (kv.length == 2) {
        final key = kv[0].toLowerCase().trim();
        final val = kv[1].trim();
        if (key.contains('acc') && !key.contains('bankbook')) {
          acc = val;
        } else if (key.contains('vb') && !key.contains('bankbook')) {
          vb = val;
        } else if (key.contains('bankbook') || key == 'bb') {
          bb = val;
        }
        continue;
      }
      final t = tok.trim();
      if (vb == null && t.length == 7)   { vb = t; continue; }
      if (bb == null && t.length == 5)   { bb = t; continue; }
      if (acc == null && t.length == 15) { acc = t; continue; }
    }
    if (vb != null && bb != null) {
      return QrPayload(vbCode: vb, bankbookNumber: bb, accNumber: acc);
    }
    return null;
  }

  static String? _pick(Map map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
    }
    return null;
  }
}
