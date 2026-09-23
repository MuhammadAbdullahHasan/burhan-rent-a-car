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

/// The import keeps everything the old system recorded that the app has no
/// column for as "Label: value" lines in `remarks` (see
/// `import/legacy_dump.dart`). [remarksValue] reads one of those labels
/// back out, and [remarksWithout] returns what is left, so a label can be
/// shown in its own row without also appearing in the Remarks text.
///
/// Matching is case-insensitive and ignores surrounding space; a label
/// only counts at the start of a line, so a mention inside a sentence is
/// never mistaken for a field. Remarks typed by the owner have no labels
/// and are returned untouched.
String? remarksValue(Object? remarks, String label) {
  final target = label.toLowerCase();
  for (final line in _remarkLines(remarks)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    if (line.substring(0, colon).trim().toLowerCase() != target) continue;
    final value = line.substring(colon + 1).trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// [remarks] with every "Label: value" line for [labels] removed. Null when
/// nothing is left, so the field shows as N/A rather than as a blank row.
String? remarksWithout(Object? remarks, List<String> labels) {
  final targets = labels.map((l) => l.toLowerCase()).toSet();
  final kept = <String>[];
  for (final line in _remarkLines(remarks)) {
    final colon = line.indexOf(':');
    final label =
        colon <= 0 ? null : line.substring(0, colon).trim().toLowerCase();
    if (label != null && targets.contains(label)) continue;
    kept.add(line);
  }
  final text = kept.join('\n').trim();
  return text.isEmpty ? null : text;
}

List<String> _remarkLines(Object? remarks) {
  final text = remarks?.toString() ?? '';
  if (text.trim().isEmpty) return const [];
  return text.split('\n');
}
