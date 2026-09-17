/// Field-normalization helpers shared by every CSV mapper (temp or real).
///
/// These encode two rules confirmed against the temp CSV
/// (docs/test_data_analysis.md §3): a blank string and the literal "N/A"
/// (any case) mean the same thing and both become `null`; and identifiers
/// used for search/dedupe (phone, CNIC, vehicle registration) get a second,
/// normalized column alongside the original as-typed value.
library;

/// Blank string or literal "N/A" (any case) -> null. Otherwise, trimmed.
String? normalizeNullable(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.toUpperCase() == 'N/A') return null;
  return trimmed;
}

/// Digits-only normalization for phone numbers and CNICs, used for
/// exact/partial search matching regardless of how the source formatted
/// separators (dashes, spaces).
String? normalizeDigits(String? raw) {
  final value = normalizeNullable(raw);
  if (value == null) return null;
  final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
  return digits.isEmpty ? null : digits;
}

/// Uppercase, separator-stripped normalization for vehicle registrations,
/// e.g. "khi-123" and "KHI 123" both normalize to "KHI123".
String? normalizeRegistration(String? raw) {
  final value = normalizeNullable(raw);
  if (value == null) return null;
  final norm = value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return norm.isEmpty ? null : norm;
}

/// Parses an integer field, returning null (not throwing) on anything that
/// doesn't look like a plain integer -- malformed numeric fields are treated
/// like missing fields (-> "N/A" at display time), not fatal errors, except
/// where the caller specifically needs a required value (e.g. rental_no).
int? parseIntOrNull(String? raw) {
  final value = normalizeNullable(raw);
  if (value == null) return null;
  return int.tryParse(value);
}

double? parseDoubleOrNull(String? raw) {
  final value = normalizeNullable(raw);
  if (value == null) return null;
  return double.tryParse(value);
}

final RegExp _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Validates (does not reparse/reformat) an ISO `YYYY-MM-DD` date string.
/// Returns null for anything that doesn't match, logging is the caller's
/// responsibility (see MappedRentalRow.warnings).
String? normalizeIsoDate(String? raw) {
  final value = normalizeNullable(raw);
  if (value == null) return null;
  return _isoDate.hasMatch(value) ? value : null;
}

const _honorifics = {
  'mr', 'mrs', 'ms', 'dr', 'syed', 'syeda', 'sayed', 'haji', 'hafiz',
  'muhammad', 'mohammad', 'mohammed', 'mohd', 'md', 'sheikh', 'shaikh',
  'malik', 'mian', 'chaudhry', 'ch', 'khawaja', 'engr', 'prof',
};

/// Whether two customer names plausibly belong to the same person: the
/// first "real" name token (honorifics such as Syed/Muhammad/Haji dropped)
/// is the same or within a couple of letters -- enough to absorb the
/// Naseer/Nasir, Tarique/Tariq spelling drift in hand-typed history, while
/// keeping Danish and Shahzad apart. A missing name on either side is
/// treated as compatible (nothing to contradict).
bool sameCustomerName(String? a, String? b) {
  final ta = _nameTokens(a);
  final tb = _nameTokens(b);
  if (ta.isEmpty || tb.isEmpty) return true;
  if (ta.first == tb.first) return true;
  if (ta.contains(tb.first) || tb.contains(ta.first)) return true;
  return _editDistance(ta.first, tb.first) <= 2 &&
      ta.first.length >= 4 &&
      tb.first.length >= 4;
}

List<String> _nameTokens(String? name) {
  final value = normalizeNullable(name);
  if (value == null) return const [];
  final tokens = value
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((t) => t.isNotEmpty)
      .toList();
  final real = tokens.where((t) => !_honorifics.contains(t)).toList();
  return real.isEmpty ? tokens : real;
}

int _editDistance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost]
          .reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}
