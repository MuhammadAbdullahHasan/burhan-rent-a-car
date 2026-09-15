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
