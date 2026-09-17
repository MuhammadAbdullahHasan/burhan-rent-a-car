import 'package:csv/csv.dart' as csv_lib;

import 'mapped_rental_row.dart';
import 'normalizers.dart';

/// The client's real history arrived as an export of their old web system's
/// MySQL database: either the phpMyAdmin SQL dump, or the same tables
/// concatenated into ONE CSV file, each table introduced by its own header
/// row. Three of those tables matter here:
///
///   rentals   -- one row per agreement (the `rentalno` column is the
///                business rental number; `id` is just the old auto-key)
///   vehicles  -- the fleet, keyed by registration number
///   payments  -- a handful of settlement notes, keyed by rentals.id
///
/// [LegacyDump.parse] splits the file into those tables and cleans the
/// rentals rows (see [cleanRentals]); [LegacyDumpMapper] then maps one
/// cleaned rentals row into a [MappedRentalRow], pulling vehicle details from
/// the vehicles table and settlement notes from payments.
class LegacyDump {
  final Map<String, List<Map<String, String>>> tables;

  /// Human-readable notes produced while cleaning -- rows dropped, numbers
  /// that were duplicated in the source, etc. Surfaced in the import report.
  final List<String> notes = [];

  LegacyDump._(this.tables);

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Parses either form of the export: the phpMyAdmin SQL dump (preferred --
  /// it is the database verbatim) or the flat CSV the same tool produces.
  static LegacyDump parse(String content) {
    if (_sqlInsert.hasMatch(content)) return parseSql(content);
    return parseCsv(content);
  }

  static final _sqlInsert =
      RegExp(r'^INSERT INTO `(\w+)` \(([^)]*)\) VALUES', multiLine: true);

  /// The phpMyAdmin dump: one `INSERT INTO \`table\` (cols) VALUES (...),
  /// (...);` statement per table. Only the value tuples are parsed; the
  /// CREATE TABLE statements are skipped.
  static LegacyDump parseSql(String content) {
    final tables = <String, List<Map<String, String>>>{};
    for (final m in _sqlInsert.allMatches(content)) {
      final cols = m
          .group(2)!
          .split(',')
          .map((c) => c.trim().replaceAll('`', ''))
          .toList();
      final table = tables.putIfAbsent(_nameFor(cols), () => []);
      for (final values in _SqlValues(content, m.end).tuples()) {
        final map = <String, String>{};
        for (var i = 0; i < cols.length; i++) {
          map[cols[i]] = i < values.length ? values[i] : '';
        }
        table.add(map);
      }
    }
    return LegacyDump._(tables);
  }

  static LegacyDump parseCsv(String content) {
    final rows = const csv_lib.CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
    ).convert(content);

    final tables = <String, List<Map<String, String>>>{};
    List<String>? header;
    List<Map<String, String>>? current;
    for (final raw in rows) {
      final cells = raw.map((c) => c.toString()).toList();
      if (cells.isEmpty || (cells.length == 1 && cells.first.isEmpty)) {
        continue;
      }
      // A header row is one where every cell is a bare column identifier.
      // Data rows always carry at least one numeric key, date, email or
      // free-text cell, so this never misfires on them.
      final isHeader = cells.every(_identifier.hasMatch);
      if (isHeader) {
        header = cells;
        current = [];
        tables[_nameFor(header)] = current;
        continue;
      }
      if (header == null || current == null) continue;
      final map = <String, String>{};
      for (var i = 0; i < header.length; i++) {
        map[header[i]] = i < cells.length ? cells[i] : '';
      }
      current.add(map);
    }
    return LegacyDump._(tables);
  }

  static String _nameFor(List<String> header) {
    final cols = header.toSet();
    if (cols.contains('rentalno')) return 'rentals';
    if (cols.contains('maker') && cols.contains('registrationno')) {
      return 'vehicles';
    }
    if (cols.contains('rentalid')) return 'payments';
    return header.join(',');
  }

  List<Map<String, String>> get rentals => tables['rentals'] ?? const [];
  List<Map<String, String>> get vehicles => tables['vehicles'] ?? const [];
  List<Map<String, String>> get payments => tables['payments'] ?? const [];

  /// The rentals rows the pipeline should import.
  ///
  /// Two clean-ups, both recorded in [notes]:
  ///
  /// * Rows with no customer, no contact, no CNIC and no vehicle are the old
  ///   system's own gap markers ("N/A" in every field). They're dropped here
  ///   and come back as proper placeholder rows via the pipeline's gap-fill.
  /// * The source repeats a few rental numbers. Identical re-submissions of
  ///   the same agreement (same client, same date) collapse to the most
  ///   recently updated copy. Where two *different* agreements share a
  ///   number, the original (the one whose old `id` equals the number, else
  ///   the earliest created) is kept and the other is dropped with a note
  ///   carrying enough detail for the owner to re-enter it under a fresh
  ///   number -- inventing a number here would shift the owner's next paper
  ///   agreement number.
  List<Map<String, String>> cleanRentals() {
    final byNo = <int, List<Map<String, String>>>{};
    var gapMarkers = 0;
    for (final row in rentals) {
      final no = parseIntOrNull(row['rentalno']);
      if (no == null) {
        notes.add(
          'Dropped source row id=${row['id']}: rental number '
          '"${row['rentalno']}" is not a number.',
        );
        continue;
      }
      if (_isGapMarker(row)) {
        gapMarkers++;
        continue;
      }
      byNo.putIfAbsent(no, () => []).add(row);
    }
    if (gapMarkers > 0) {
      notes.add(
        '$gapMarkers source rows had no customer, contact, CNIC or vehicle '
        '(the old system\'s own gap markers) -- stored as placeholders.',
      );
    }

    final kept = <Map<String, String>>[];
    final nos = byNo.keys.toList()..sort();
    for (final no in nos) {
      final group = byNo[no]!;
      if (group.length == 1) {
        kept.add(group.single);
        continue;
      }
      // Collapse exact re-submissions first.
      final distinct = <String, Map<String, String>>{};
      for (final row in group) {
        final key = '${legacyNullable(row['clientcontactno'])}|'
            '${legacyNullable(row['clientnic'])}|${row['rentaldate']}';
        final prev = distinct[key];
        if (prev == null ||
            (row['updated_at'] ?? '').compareTo(prev['updated_at'] ?? '') >
                0) {
          distinct[key] = row;
        }
      }
      if (distinct.length < group.length) {
        notes.add(
          'Rental #$no appeared ${group.length} times in the source as the '
          'same agreement -- kept the most recently updated copy.',
        );
      }
      final candidates = distinct.values.toList()
        ..sort((a, b) {
          final aOrig = a['id'] == '$no' ? 0 : 1;
          final bOrig = b['id'] == '$no' ? 0 : 1;
          if (aOrig != bOrig) return aOrig - bOrig;
          return (a['created_at'] ?? '').compareTo(b['created_at'] ?? '');
        });
      kept.add(candidates.first);
      for (final dropped in candidates.skip(1)) {
        final reEntered = _reEntryOf(dropped, byNo, no);
        notes.add(
          'Rental #$no was used for two different agreements in the source. '
          'Kept: ${_describe(candidates.first)}. Not imported: '
          '${_describe(dropped)}'
          '${reEntered != null ? ' -- the same client and date is already '
              'on record as Rental #$reEntered, so this looks like a typed '
              'number that was corrected later.' : ' -- please re-enter it '
              'under a new number.'}',
        );
      }
    }
    return kept;
  }

  /// The number under which [row]'s client and date appear elsewhere in the
  /// source, if any: a clerk who typed the wrong number usually re-entered
  /// the agreement correctly right after.
  static int? _reEntryOf(
    Map<String, String> row,
    Map<int, List<Map<String, String>>> byNo,
    int exceptNo,
  ) {
    final date = legacyNullable(row['rentaldate']);
    final phone = normalizeDigits(legacyNullable(row['clientcontactno']));
    final name =
        isCancelledName(row['clientname']) ? null : legacyNullable(row['clientname']);
    if (date == null ||
        date.startsWith('0001') ||
        (phone == null && name == null)) {
      return null;
    }
    for (final entry in byNo.entries) {
      if (entry.key == exceptNo) continue;
      for (final other in entry.value) {
        if (legacyNullable(other['rentaldate']) != date) continue;
        final otherPhone =
            normalizeDigits(legacyNullable(other['clientcontactno']));
        if (phone != null && phone == otherPhone) return entry.key;
        if (sameCustomerName(name, legacyNullable(other['clientname'])) &&
            name != null &&
            legacyNullable(other['clientname']) != null) {
          return entry.key;
        }
      }
    }
    return null;
  }

  static bool _isGapMarker(Map<String, String> row) =>
      legacyNullable(row['clientname']) == null &&
      legacyNullable(row['clientcontactno']) == null &&
      legacyNullable(row['clientnic']) == null &&
      legacyNullable(row['registrationno']) == null &&
      legacyNullable(row['registration_no']) == null &&
      (parseDoubleOrNull(legacyNullable(row['totalrental'])) ?? 0) == 0;

  static String _describe(Map<String, String> row) =>
      '${legacyNullable(row['clientname']) ?? 'no name'}, '
      '${legacyNullable(row['clientcontactno']) ?? 'no contact'}, '
      'vehicle ${legacyNullable(row['registrationno']) ?? 'N/A'}, '
      'date ${legacyNullable(row['rentaldate']) ?? 'N/A'}, '
      'amount ${legacyNullable(row['totalrental']) ?? 'N/A'} '
      '(old id ${row['id']})';
}

/// Reads the `(v, v, ...), (v, v, ...);` tuples that follow one INSERT
/// statement's VALUES keyword. SQL NULL comes out as the text "NULL" so the
/// SQL and CSV forms of the dump look identical downstream.
class _SqlValues {
  final String s;
  int i;
  _SqlValues(this.s, this.i);

  Iterable<List<String>> tuples() sync* {
    while (true) {
      _skipSpace();
      if (i >= s.length || s[i] != '(') return;
      i++;
      final row = <String>[];
      while (true) {
        _skipSpace();
        row.add(s[i] == "'" ? _quoted() : _bare());
        _skipSpace();
        if (s[i] == ',') {
          i++;
          continue;
        }
        if (s[i] == ')') {
          i++;
          break;
        }
        throw FormatException('Unexpected "${s[i]}" in SQL dump at $i');
      }
      yield row;
      _skipSpace();
      if (i < s.length && s[i] == ',') {
        i++;
        continue;
      }
      return; // ';' -- end of this statement
    }
  }

  void _skipSpace() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' ||
        s[i] == '\t')) {
      i++;
    }
  }

  String _bare() {
    final start = i;
    while (s[i] != ',' && s[i] != ')') {
      i++;
    }
    return s.substring(start, i).trim();
  }

  String _quoted() {
    i++; // opening quote
    final buf = StringBuffer();
    while (true) {
      final c = s[i];
      if (c == '\\') {
        final n = s[i + 1];
        buf.write(switch (n) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          '0' => '',
          _ => n,
        });
        i += 2;
        continue;
      }
      if (c == "'") {
        if (i + 1 < s.length && s[i + 1] == "'") {
          buf.write("'");
          i += 2;
          continue;
        }
        i++;
        return buf.toString();
      }
      buf.write(c);
      i++;
    }
  }
}

/// The dump writes SQL NULL as the literal text "NULL", on top of the blank
/// and "N/A" conventions every other source shares. The clerks also typed
/// "Blank", "Blank rental", "NA" or a lone dash into a field they had
/// nothing for, so those read as empty too.
String? legacyNullable(String? raw) {
  final value = normalizeNullable(raw);
  if (value == null) return null;
  final upper = value.toUpperCase();
  if (upper == 'NULL' || upper == 'NA' || upper == 'BLANK' ||
      upper == 'BLANK RENTAL' || RegExp(r'^[-_.]+$').hasMatch(value)) {
    return null;
  }
  return value;
}

/// A client name the old system used to mark a cancelled agreement: the
/// word alone ("Cancel", "CANCELLED") or appended to the name ("Muzammil
/// (cancel)", "Adeel Azhar cancel"). The number stays used; the name, if
/// any, is kept for the remarks.
bool isCancelledName(String? name) {
  final value = legacyNullable(name);
  if (value == null) return false;
  return RegExp(r'\bcancel(l?ed)?\b', caseSensitive: false).hasMatch(value);
}

/// Maps one cleaned `rentals` row from a [LegacyDump].
class LegacyDumpMapper implements RentalCsvMapper {
  final Map<String, Map<String, String>> _vehiclesByReg;
  final Map<String, List<Map<String, String>>> _paymentsByRentalId;
  final DateTime today;

  LegacyDumpMapper(LegacyDump dump, {DateTime? today})
      : _vehiclesByReg = {
          for (final v in dump.vehicles)
            if (normalizeRegistration(v['registrationno']) != null)
              normalizeRegistration(v['registrationno'])!: v,
        },
        _paymentsByRentalId = {},
        today = today ?? DateTime.now() {
    for (final p in dump.payments) {
      _paymentsByRentalId.putIfAbsent(p['rentalid'] ?? '', () => []).add(p);
    }
  }

  @override
  MappedRentalRow map(Map<String, String> raw) {
    final warnings = <String>[];
    final rentalNo = parseIntOrNull(raw['rentalno']);
    if (rentalNo == null) {
      throw RowMappingException(
        'Row has no valid rentalno (raw value: "${raw['rentalno']}")',
      );
    }

    final startDate = _date(raw['rentaldate']);
    if (startDate == null && legacyNullable(raw['rentaldate']) != null) {
      warnings.add(
        'Rental #$rentalNo: unusable rental date "${raw['rentaldate']}"',
      );
    }
    final endDate = _date(raw['receive_date']);

    // The old system had no status; a rental is closed when the car was
    // logged back in, or when its booked period ended long enough ago that
    // it cannot still be out. Anything else stays Open for the owner to
    // close by hand.
    final days = _bookedDays(raw);
    var status = 'Open';
    if (endDate != null) {
      status = 'Closed';
    } else if (startDate != null) {
      final start = DateTime.tryParse(startDate);
      if (start != null &&
          start.add(Duration(days: days ?? 1)).isBefore(
                today.subtract(const Duration(days: 30)),
              )) {
        status = 'Closed';
      }
    }
    final cancelled = isCancelledName(raw['clientname']);
    if (cancelled) status = 'Closed';

    final amount = parseDoubleOrNull(legacyNullable(raw['totalrental']));
    final advance = parseDoubleOrNull(legacyNullable(raw['advance']));
    final balance =
        amount != null ? amount - (advance ?? 0) : null;

    final regRaw = legacyNullable(raw['registrationno']) ??
        legacyNullable(raw['registration_no']);
    final vehicle = _vehiclesByReg[normalizeRegistration(regRaw) ?? ''];
    final maker = legacyNullable(vehicle?['maker']);
    final makerParts = maker?.split(RegExp(r'\s+'));

    return MappedRentalRow(
      rentalNo: rentalNo,
      // A cancelled agreement's name field holds "Cancel" or "<name> cancel";
      // neither is a customer. The name, if there was one, goes to remarks.
      customerName: cancelled ? null : legacyNullable(raw['clientname']),
      customerPhone: cancelled ? null : legacyNullable(raw['clientcontactno']),
      customerCnic: cancelled ? null : legacyNullable(raw['clientnic']),
      customerLicenseNo: _licenseNo(raw['licenseno']),
      customerLicenseCity: legacyNullable(raw['cityofissue']),
      vehicleRegistration: regRaw,
      vehicleChassisNo: legacyNullable(vehicle?['chassisno']),
      vehicleEngineNo: legacyNullable(vehicle?['engineno']),
      vehicleCompany: makerParts?.first,
      vehicleModelName: makerParts != null && makerParts.length > 1
          ? makerParts.sublist(1).join(' ')
          : null,
      vehicleHorsepower: legacyNullable(vehicle?['horsepower']),
      vehicleColor: legacyNullable(vehicle?['color']),
      vehicleRegYear: parseIntOrNull(legacyNullable(vehicle?['registrationyear'])),
      vehicleInsuranceDueOn: _date(vehicle?['insuranceduedate']),
      startDate: startDate,
      startTime: _time(raw['rental_time']),
      endDate: endDate,
      endTime: _time(raw['receive_time']),
      bookDays: days,
      amount: amount,
      balance: balance,
      status: status,
      remarks: _remarks(raw, cancelled: cancelled),
      refName: legacyNullable(raw['referencename']),
      refContact: legacyNullable(raw['referencecontactno']),
      refRelation: legacyNullable(raw['referencerelationship']),
      warnings: warnings,
    );
  }

  /// `rentaldays` is in the unit of `issueterms` (Per Day / Per Week /
  /// Per Month); the app stores plain days.
  int? _bookedDays(Map<String, String> raw) {
    final n = parseIntOrNull(legacyNullable(raw['rentaldays']));
    if (n == null || n <= 0) return null;
    switch (legacyNullable(raw['issueterms'])?.toLowerCase()) {
      case 'per week':
        return n * 7;
      case 'per month':
        return n * 30;
      default:
        return n;
    }
  }

  /// The old system stored "1" as a stand-in for "has a licence, number not
  /// recorded" -- that's not a licence number.
  String? _licenseNo(String? raw) {
    final value = legacyNullable(raw);
    return value == '1' || value == '0' ? null : value;
  }

  static final _isoDateTime = RegExp(r'^(\d{4}-\d{2}-\d{2})');

  String? _date(String? raw) {
    final value = legacyNullable(raw);
    if (value == null) return null;
    final m = _isoDateTime.firstMatch(value);
    final date = m?.group(1);
    if (date == null || date.startsWith('0000') || date.startsWith('0001')) {
      return null;
    }
    return normalizeIsoDate(date);
  }

  /// "15:00:00" / "11:00" -> "03:00 PM" / "11:00 AM", the free-text form the
  /// app's forms already use.
  String? _time(String? raw) {
    final value = legacyNullable(raw);
    if (value == null) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(value);
    if (m == null) return value;
    final h = int.parse(m.group(1)!);
    final mm = m.group(2)!;
    if (h > 23) return value;
    final suffix = h >= 12 ? 'PM' : 'AM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '${h12.toString().padLeft(2, '0')}:$mm $suffix';
  }

  /// Everything the old system recorded that the app has no column for is
  /// preserved here, one "Label: value" per line, so nothing is lost.
  String? _remarks(Map<String, String> raw, {required bool cancelled}) {
    final lines = <String>[];
    void add(String label, String? column) {
      final v = legacyNullable(raw[column]);
      if (v != null) lines.add('$label: $v');
    }

    if (cancelled) {
      final name = legacyNullable(raw['clientname'])
          ?.replaceAll(RegExp(r'[\s(]*cancel(l?ed)?[\s)]*', caseSensitive: false), ' ')
          .trim();
      lines.add(
        name == null || name.isEmpty ? 'Cancelled' : 'Cancelled ($name)',
      );
      add('Contact', 'clientcontactno');
      add('CNIC', 'clientnic');
    }

    add('Father/Husband', 'clientfather_husbandname');
    add('Address', 'clientaddress');
    add('Office address', 'clientofficeaddress');
    add('Residence contact', 'clientresidencecontactno');
    add('Office contact', 'clientofficecontactno');
    add('Passport', 'clientpassport');
    final country = legacyNullable(raw['clientcountry']);
    if (country != null && country.toLowerCase() != 'pakistan') {
      lines.add('Country: $country');
    }
    if (legacyNullable(raw['driver']) == '0') {
      lines.add('Self-drive: no');
    }
    add('Driver', 'drivername');
    add('Driver NIC', 'drivernic');
    add('Meter out', 'meterout');
    add('Meter in', 'meterin');
    final terms = legacyNullable(raw['issueterms']);
    final rate = parseDoubleOrNull(legacyNullable(raw['perdayrental']));
    if (rate != null && rate > 0) {
      lines.add('Rate: ${_money(rate)} ${terms ?? 'Per Day'}');
    }
    final advance = parseDoubleOrNull(legacyNullable(raw['advance']));
    if (advance != null && advance > 0) {
      lines.add('Advance: ${_money(advance)}');
    }
    add('Ref. father/husband', 'referencefather_husbandname');
    add('Ref. NIC', 'referencenic');
    add('Ref. address', 'referenceaddress');
    add('Ref. office address', 'referenceofficeaddress');
    add('Co-signer', 'coname');
    add('Co-signer NIC', 'conicno');

    final checklist = <String>[];
    const items = {
      'backcamera': 'back camera',
      'airpump': 'air pump',
      'sparewheel': 'spare wheel',
      'jackhandle': 'jack handle',
      'safetydevice': 'safety device',
      'wheelcaps': 'wheel caps',
      'alloyrims': 'alloy rims',
      'acon': 'AC',
      'sidemirror': 'side mirror',
      'cng': 'CNG',
      'wheelspanner': 'wheel spanner',
      'radiotaperecorder': 'radio/tape',
      'footmats': 'foot mats',
      'cardocuments': 'car documents',
      'chassisplate': 'chassis plate',
      'noplatesoriginal': 'original number plates',
    };
    items.forEach((col, label) {
      if (raw[col] == '1') checklist.add(label);
    });
    for (var i = 1; i <= 4; i++) {
      if (raw['other$i'] == '1') {
        checklist.add(legacyNullable(raw['other${i}title']) ?? 'other $i');
      }
    }
    if (checklist.isNotEmpty) lines.add('Checklist: ${checklist.join(', ')}');

    for (final p in _paymentsByRentalId[raw['id'] ?? ''] ?? const []) {
      final amt = parseDoubleOrNull(legacyNullable(p['amount']));
      final note = legacyNullable(p['remarks']);
      lines.add(
        'Payment ${legacyNullable(p['date']) ?? ''}'
        '${amt != null ? ': ${_money(amt)}' : ''}'
        '${note != null ? ' -- $note' : ''}',
      );
    }

    return lines.isEmpty ? null : lines.join('\n');
  }

  String _money(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}
