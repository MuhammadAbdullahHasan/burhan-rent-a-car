/// Single shared rendering rule for the whole app: any missing individual
/// field displays as "N/A" (never a blank space) -- see the locked spec's
/// data-integrity requirement. Placeholder *rows* (whole missing historical
/// records) are a separate, row-level concept -- see
/// `rentals.is_placeholder` and [noPreviousRecordAvailable].
String displayOrNA(Object? value) {
  if (value == null) return 'N/A';
  final s = value.toString();
  return s.trim().isEmpty ? 'N/A' : s;
}

const String noPreviousRecordAvailable = 'No previous record available';

/// How a rental identifies itself everywhere in the UI.
///
/// A historical or already-synced rental shows its permanent number
/// ("#23"). A rental created offline has no permanent number yet -- the
/// backend assigns it on sync -- so it shows "Pending #<id prefix>" rather
/// than a guessed number that could collide or be reused.
String rentalDisplayNumber(Map<String, Object?> rental) {
  final no = rental['rental_no'] as int?;
  if (no != null) return '#$no';
  final id = rental['id'] as String? ?? '';
  final prefix = id.length >= 6 ? id.substring(0, 6) : id;
  return 'Pending #$prefix';
}

bool isPlaceholderRental(Map<String, Object?> rental) =>
    (rental['is_placeholder'] as int? ?? 0) == 1;

bool isPendingRental(Map<String, Object?> rental) =>
    rental['rental_no'] == null;
