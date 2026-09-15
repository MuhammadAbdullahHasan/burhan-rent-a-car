import 'package:sqflite_common/sqlite_api.dart';

import '../import/normalizers.dart';

enum SearchResultType { rental, customer, vehicle }

/// Which field a scoped search runs against. Each maps to exactly one of
/// the lookups below, so a category field only ever returns that kind of
/// match.
enum SearchScope { rentalNo, customerName, phone, cnic, vehicle }

/// One row in the result list the user sees.
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

  /// Why this row matched -- shown as a small chip.
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

/// Local search over the SQLite indexes -- never depends on connectivity.
///
/// [search] runs every lookup against one query and merges the results
/// (exact identifier matches first). [searchScoped] runs a single lookup,
/// for a UI with one field per category.
class UniversalSearchService {
  /// Partial matches are capped so a very short query (e.g. "1") can't try
  /// to render thousands of rows; exact matches are never capped away.
  static const int partialLimit = 50;

  Future<List<SearchResult>> search(DatabaseExecutor db, String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return const [];

    final results = <SearchResult>[];
    final seen = <String>{};
    void addAll(Iterable<SearchResult> rows) {
      for (final r in rows) {
        if (seen.add('${r.type}:${r.id}')) results.add(r);
      }
    }

    // Exact identifier matches first, in priority order, then partials.
    // A pure-digit query may be a rental number *and* part of a phone
    // number, so nothing short-circuits -- ordering does the ranking.
    addAll(await _byRentalNo(db, query));
    addAll((await _byVehicle(db, query)).where((r) => r.isExactMatch));
    addAll((await _byPhone(db, query)).where((r) => r.isExactMatch));
    addAll((await _byCnic(db, query)).where((r) => r.isExactMatch));
    addAll(await _byName(db, query));
    addAll(await _byPhone(db, query));
    addAll(await _byCnic(db, query));
    addAll(await _byVehicle(db, query));
    return results;
  }

  Future<List<SearchResult>> searchScoped(
    DatabaseExecutor db,
    String rawQuery,
    SearchScope scope,
  ) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return const [];
    return switch (scope) {
      SearchScope.rentalNo => _byRentalNo(db, query),
      SearchScope.customerName => _byName(db, query),
      SearchScope.phone => _byPhone(db, query),
      SearchScope.cnic => _byCnic(db, query),
      SearchScope.vehicle => _byVehicle(db, query),
    };
  }

  /// The single exact match to open directly on submit, if there is exactly
  /// one. Null when the query is ambiguous or purely partial.
  SearchResult? soleExactMatch(List<SearchResult> results) {
    final exact = results.where((r) => r.isExactMatch).toList();
    return exact.length == 1 ? exact.first : null;
  }

  // ---- one lookup per category -------------------------------------------

  /// Exact rental number only -- "exact rental number returns that rental".
  Future<List<SearchResult>> _byRentalNo(DatabaseExecutor db, String query) async {
    final asInt = int.tryParse(query);
    if (asInt == null) return const [];
    final rows = await db.query(
      'rentals',
      where: 'rental_no = ? AND is_deleted = 0',
      whereArgs: [asInt],
      limit: 1,
    );
    return [
      for (final row in rows)
        _rentalResult(row, isExact: true, matchedOn: 'Rental #'),
    ];
  }

  Future<List<SearchResult>> _byName(DatabaseExecutor db, String query) async {
    final rows = await db.query(
      'customers',
      where: 'full_name LIKE ? COLLATE NOCASE AND is_deleted = 0',
      whereArgs: ['%$query%'],
      limit: partialLimit,
    );
    return [
      for (final row in rows)
        _customerResult(row, isExact: false, matchedOn: 'Name'),
    ];
  }

  /// Exact normalized phone first, then partial.
  Future<List<SearchResult>> _byPhone(DatabaseExecutor db, String query) async {
    final digits = normalizeDigits(query);
    if (digits == null) return const [];
    return _customersByDigits(db, 'phone_normalized', digits, 'Phone');
  }

  Future<List<SearchResult>> _byCnic(DatabaseExecutor db, String query) async {
    final digits = normalizeDigits(query);
    if (digits == null) return const [];
    return _customersByDigits(db, 'cnic_normalized', digits, 'CNIC');
  }

  Future<List<SearchResult>> _customersByDigits(
    DatabaseExecutor db,
    String column,
    String digits,
    String matchedOn,
  ) async {
    final results = <SearchResult>[];
    final seen = <String>{};

    final exact = await db.query(
      'customers',
      where: '$column = ? AND is_deleted = 0',
      whereArgs: [digits],
      limit: 1,
    );
    for (final row in exact) {
      seen.add(row['id'] as String);
      results.add(_customerResult(row, isExact: true, matchedOn: matchedOn));
    }

    final partial = await db.query(
      'customers',
      where: '$column LIKE ? AND is_deleted = 0',
      whereArgs: ['%$digits%'],
      limit: partialLimit,
    );
    for (final row in partial) {
      if (seen.add(row['id'] as String)) {
        results.add(_customerResult(row, isExact: false, matchedOn: matchedOn));
      }
    }
    return results;
  }

  /// Exact normalized registration first, then partial.
  Future<List<SearchResult>> _byVehicle(DatabaseExecutor db, String query) async {
    final regNorm = normalizeRegistration(query);
    if (regNorm == null) return const [];
    final results = <SearchResult>[];
    final seen = <String>{};

    final exact = await db.query(
      'vehicles',
      where: 'registration_norm = ? AND is_deleted = 0',
      whereArgs: [regNorm],
      limit: 1,
    );
    for (final row in exact) {
      seen.add(row['id'] as String);
      results.add(_vehicleResult(row, isExact: true, matchedOn: 'Registration'));
    }

    final partial = await db.query(
      'vehicles',
      where: 'registration_norm LIKE ? AND is_deleted = 0',
      whereArgs: ['%$regNorm%'],
      limit: partialLimit,
    );
    for (final row in partial) {
      if (seen.add(row['id'] as String)) {
        results.add(
          _vehicleResult(row, isExact: false, matchedOn: 'Registration'),
        );
      }
    }
    return results;
  }

  // ---- row -> result -------------------------------------------------------

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
