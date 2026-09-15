import 'package:sqflite_common/sqlite_api.dart';

/// Full-data snapshot used by the manual encrypted backup (locked spec §3C)
/// and, structurally, by cloud restore too -- both apply via the same
/// idempotent-upsert-by-id rule the sync engine uses, which is what
/// guarantees a restore can never create a duplicate rental.
///
/// This harness snapshot is plain (unencrypted) JSON-able maps; the real
/// export adds password-based encryption around the same payload shape.
class Snapshot {
  final List<Map<String, Object?>> customers;
  final List<Map<String, Object?>> vehicles;
  final List<Map<String, Object?>> rentals;

  Snapshot({
    required this.customers,
    required this.vehicles,
    required this.rentals,
  });
}

Future<Snapshot> exportSnapshot(DatabaseExecutor db) async {
  return Snapshot(
    customers: await db.query('customers'),
    vehicles: await db.query('vehicles'),
    rentals: await db.query('rentals'),
  );
}

/// Applies a snapshot by primary-key (id) upsert -- restoring the same
/// snapshot twice, or restoring onto a database that already has some of
/// these rows, never creates a duplicate.
Future<void> restoreSnapshot(Database db, Snapshot snapshot) async {
  await db.transaction((txn) async {
    for (final row in snapshot.customers) {
      await txn.insert(
        'customers',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final row in snapshot.vehicles) {
      await txn.insert(
        'vehicles',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    for (final row in snapshot.rentals) {
      await txn.insert(
        'rentals',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  });
}
