import 'package:sqflite_common/sqlite_api.dart';

const _counterKey = 'rental_no_counter';

/// Stands in for the future Postgres monotonic counter (plan §5 / §2 of the
/// locked spec) while there is no backend yet. Same rule either way: seeded
/// to MAX(rental_no) WHERE NOT is_placeholder, then only ever incremented --
/// placeholders can never leak into future numbering, and because the
/// counter lives in the same durable SQLite file as the data, a
/// close+reopen ("app restart") can never reset it.
///
/// When the real backend exists, this class is replaced by an API call to
/// an atomic Postgres sequence; nothing else in this package needs to
/// change, since callers only ever see [allocateNext].
class RentalNumberAllocator {
  /// Seeds the counter from existing data. Call once, right after the
  /// historical bulk import. Safe to call again -- it never lowers an
  /// already-seeded counter.
  Future<void> seedFromExisting(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      'SELECT MAX(rental_no) as max_no FROM rentals WHERE is_placeholder = 0',
    );
    final maxNo = rows.first['max_no'] as int? ?? 0;

    final existing = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [_counterKey],
    );
    if (existing.isEmpty) {
      await db.insert('app_meta', {
        'key': _counterKey,
        'value': '$maxNo',
      });
    } else {
      final current = int.parse(existing.first['value'] as String);
      if (maxNo > current) {
        await db.update(
          'app_meta',
          {'value': '$maxNo'},
          where: 'key = ?',
          whereArgs: [_counterKey],
        );
      }
    }
  }

  /// Atomically returns the next rental number and persists the increment.
  /// Caller must run this inside a transaction if it needs to be atomic
  /// with the row that will use the number (mirrors how the real backend
  /// allocates inside the same insert transaction).
  Future<int> allocateNext(DatabaseExecutor db) async {
    final rows = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [_counterKey],
    );
    final current = rows.isEmpty ? 0 : int.parse(rows.first['value'] as String);
    final next = current + 1;
    if (rows.isEmpty) {
      await db.insert('app_meta', {'key': _counterKey, 'value': '$next'});
    } else {
      await db.update(
        'app_meta',
        {'value': '$next'},
        where: 'key = ?',
        whereArgs: [_counterKey],
      );
    }
    return next;
  }

  Future<int> peek(DatabaseExecutor db) async {
    final rows = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [_counterKey],
    );
    final current = rows.isEmpty ? 0 : int.parse(rows.first['value'] as String);
    return current + 1;
  }
}
