import 'package:sqflite_common/sqlite_api.dart';

import '../import/normalizers.dart';

enum SearchResultType { rental, customer, vehicle }

/// One row in the single, undifferentiated result list the user sees.
class SearchResult {
  final SearchResultType type;

  /// Entity UUID -- what the detail screens navigate by.
  final String id;
  final String title;
  final String subtitle;

  /// True when the query matched a unique identifier exactly (rental
  /// number, full registration, full phone, full CNIC). Exact matches sort
  /// first, and a lone exact match is what the search screen opens directly
  /// when the user submits the query.
  final bool isExactMatch;

  /// Why this row matched -- shown as a small chip so the single search box
  /// stays self-explanatory without a category selector.
  final String matchedOn;

  const SearchResult({
    required this.type,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.isExactMatch,
    required this.matchedOn,
  });
}

/// The one search box. No category selector: the query is classified, every
/// applicable lookup runs against the local SQLite indexes, and results are
/// merged with exact identifier matches ranked above partial ones.
///
/// Entirely local -- search never depends on connectivity.
class UniversalSearchService {
  /// Partial matches are capped so a very short query (e.g. "1") can't try
  /// to render thousands of rows; exact matches are never capped away.
  static const int partialLimit = 50;

  Future<List<SearchResult>> search(DatabaseExecutor db, String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return const [];

    final digits = normalizeDigits(query);
    final regNorm = normalizeRegistration(query);
    final results = <SearchResult>[];
    final seen = <String>{};

    void add(SearchResult r) {
      final key = '${r.type}:${r.id}';
      if (seen.add(key)) results.add(r);
    }

    // 1. Exact rental number. A pure-digit query may *also* be part of a
    // phone number, so this doesn't short-circuit the rest -- it just ranks
    // first.
    final asInt = int.tryParse(query);
    if (asInt != null) {
      final rows = await db.query(
        'rentals',
        where: 'rental_no = ? AND is_deleted = 0',
        whereArgs: [asInt],
        limit: 1,
      );
      for (final row in rows) {
        add(_rentalResult(row, isExact: true, matchedOn: 'Rental #'));
      }
    }

    // 2. Exact vehicle registration.
    if (regNorm != null) {
      final rows = await db.query(
        'vehicles',
        where: 'registration_norm = ? AND is_deleted = 0',
        whereArgs: [regNorm],
        limit: 1,
      );
      for (final row in rows) {
        add(_vehicleResult(row, isExact: true, matchedOn: 'Registration'));
      }
    }

    // 3/4. Exact phone, then exact CNIC.
    if (digits != null) {
      final byPhone = await db.query(
        'customers',
        where: 'phone_normalized = ? AND is_deleted = 0',
        whereArgs: [digits],
        limit: 1,
      );
      for (final row in byPhone) {
        add(_customerResult(row, isExact: true, matchedOn: 'Phone'));
      }

      final byCnic = await db.query(
        'customers',
        where: 'cnic_normalized = ? AND is_deleted = 0',
        whereArgs: [digits],
        limit: 1,
      );
      for (final row in byCnic) {
        add(_customerResult(row, isExact: true, matchedOn: 'CNIC'));
      }
    }

    // 5. Partial customer name.
    final byName = await db.query(
      'customers',
      where: 'full_name LIKE ? COLLATE NOCASE AND is_deleted = 0',
      whereArgs: ['%$query%'],
      limit: partialLimit,
    );
    for (final row in byName) {
      add(_customerResult(row, isExact: false, matchedOn: 'Name'));
    }

    // 6. Partial phone / CNIC.
    if (digits != null) {
      final partialCustomers = await db.query(
        'customers',
        where: '(phone_normalized LIKE ? OR cnic_normalized LIKE ?) '
            'AND is_deleted = 0',
        whereArgs: ['%$digits%', '%$digits%'],
        limit: partialLimit,
      );
      for (final row in partialCustomers) {
        add(_customerResult(row, isExact: false, matchedOn: 'Phone / CNIC'));
      }
    }

    // 7. Partial vehicle registration.
    if (regNorm != null) {
      final partialVehicles = await db.query(
        'vehicles',
        where: 'registration_norm LIKE ? AND is_deleted = 0',
        whereArgs: ['%$regNorm%'],
        limit: partialLimit,
      );
      for (final row in partialVehicles) {
        add(_vehicleResult(row, isExact: false, matchedOn: 'Registration'));
      }
    }

    return results;
  }

  /// The single exact match to open directly on submit, if there is exactly
  /// one. Returns null when the query is ambiguous (several exact matches)
  /// or purely partial -- in which case the list is shown instead.
  SearchResult? soleExactMatch(List<SearchResult> results) {
    final exact = results.where((r) => r.isExactMatch).toList();
    return exact.length == 1 ? exact.first : null;
  }

  SearchResult _rentalResult(
    Map<String, Object?> row, {
    required bool isExact,
    required String matchedOn,
  }) {
    final isPlaceholder = (row['is_placeholder'] as int? ?? 0) == 1;
    return SearchResult(
      type: SearchResultType.rental,
      id: row['id'] as String,
      title: 'Rental #${row['rental_no']}',
      subtitle: isPlaceholder
          ? 'No previous record available'
          : [row['start_date'], row['status']]
              .where((v) => v != null)
              .join('  ·  '),
      isExactMatch: isExact,
      matchedOn: matchedOn,
    );
  }

  SearchResult _customerResult(
    Map<String, Object?> row, {
    required bool isExact,
    required String matchedOn,
  }) {
    return SearchResult(
      type: SearchResultType.customer,
      id: row['id'] as String,
      title: (row['full_name'] as String?) ?? 'Unnamed customer',
      subtitle: [row['phone'], row['cnic']]
          .where((v) => v != null)
          .join('  ·  '),
      isExactMatch: isExact,
      matchedOn: matchedOn,
    );
  }

  SearchResult _vehicleResult(
    Map<String, Object?> row, {
    required bool isExact,
    required String matchedOn,
  }) {
    return SearchResult(
      type: SearchResultType.vehicle,
      id: row['id'] as String,
      title: (row['registration_no'] as String?) ?? 'Unregistered vehicle',
      subtitle: [row['company'], row['model_name'], row['trim']]
          .where((v) => v != null)
          .join(' '),
      isExactMatch: isExact,
      matchedOn: matchedOn,
    );
  }
}
