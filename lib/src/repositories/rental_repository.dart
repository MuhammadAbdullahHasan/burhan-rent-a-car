import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class RentalRepository {
  Future<Map<String, Object?>?> findByRentalNo(
    DatabaseExecutor db,
    int rentalNo,
  ) async {
    final rows = await db.query(
      'rentals',
      where: 'rental_no = ?',
      whereArgs: [rentalNo],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> getById(DatabaseExecutor db, String id) async {
    final rows = await db.query('rentals', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> findByCustomerId(
    DatabaseExecutor db,
    String customerId,
  ) {
    return db.query(
      'rentals',
      where: 'customer_id = ? AND is_deleted = 0',
      whereArgs: [customerId],
      orderBy: 'rental_no ASC',
    );
  }

  Future<List<Map<String, Object?>>> findByVehicleId(
    DatabaseExecutor db,
    String vehicleId,
  ) {
    return db.query(
      'rentals',
      where: 'vehicle_id = ? AND is_deleted = 0',
      whereArgs: [vehicleId],
      orderBy: 'rental_no ASC',
    );
  }

  /// Inserts a real, fully-numbered rental row (used by CSV import, and by
  /// "create rental while online" once a backend exists).
  Future<String> insert(
    DatabaseExecutor db, {
    required int? rentalNo,
    String? customerId,
    String? vehicleId,
    String? startDate,
    String? startTime,
    String? endDate,
    String? endTime,
    int? bookDays,
    double? amount,
    double? balance,
    String? status,
    String? remarks,
    String? refName,
    String? refContact,
    String? refRelation,
    bool isPlaceholder = false,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('rentals', {
      'id': id,
      'rental_no': rentalNo,
      'is_placeholder': isPlaceholder ? 1 : 0,
      'customer_id': customerId,
      'vehicle_id': vehicleId,
      'start_date': startDate,
      'start_time': startTime,
      'end_date': endDate,
      'end_time': endTime,
      'book_days': bookDays,
      'amount': amount,
      'balance': balance,
      'status': status,
      'remarks': remarks,
      'ref_name': refName,
      'ref_contact': refContact,
      'ref_relation': refRelation,
      'is_deleted': 0,
      'version': 1,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  /// Rentals that haven't been closed out. "Unclosed" is deliberately
  /// defined as *not* explicitly closed (so a rental with a missing status
  /// still surfaces) -- for a rental business, wrongly hiding an open
  /// rental is worse than showing one extra. Placeholder rows are excluded:
  /// they are gap markers, not real rentals.
  Future<List<Map<String, Object?>>> unclosed(
    DatabaseExecutor db, {
    int? limit,
  }) {
    return db.query(
      'rentals',
      where: "is_deleted = 0 AND is_placeholder = 0 "
          "AND LOWER(COALESCE(status, '')) != 'closed'",
      orderBy: 'start_date DESC, rental_no DESC',
      limit: limit,
    );
  }

  Future<List<Map<String, Object?>>> recent(
    DatabaseExecutor db, {
    int limit = 10,
  }) {
    return db.query(
      'rentals',
      where: 'is_deleted = 0 AND is_placeholder = 0',
      orderBy: 'start_date DESC, rental_no DESC',
      limit: limit,
    );
  }

  /// The rental carrying the highest number -- what the business is
  /// "on" right now. Rentals still waiting for a number, placeholders and
  /// deleted rows don't count.
  Future<Map<String, Object?>?> latestNumbered(DatabaseExecutor db) async {
    final rows = await db.query(
      'rentals',
      where: 'is_deleted = 0 AND is_placeholder = 0 AND rental_no IS NOT NULL',
      orderBy: 'rental_no DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> countWhere(DatabaseExecutor db, String where) async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM rentals WHERE $where');
    return rows.first['c'] as int? ?? 0;
  }

  /// Every rental of [vehicleId] made by [customerId] -- the deepest level
  /// of the Library drill-down (vehicle -> its customers -> that customer's
  /// history *on this vehicle*).
  Future<List<Map<String, Object?>>> findByCustomerAndVehicle(
    DatabaseExecutor db,
    String customerId,
    String vehicleId,
  ) {
    return db.query(
      'rentals',
      where: 'customer_id = ? AND vehicle_id = ? AND is_deleted = 0',
      whereArgs: [customerId, vehicleId],
      orderBy: 'rental_no ASC',
    );
  }

  Future<void> update(
    DatabaseExecutor db,
    String id,
    Map<String, Object?> fields,
    int currentVersion,
  ) async {
    final updates = Map<String, Object?>.from(fields)
      ..['updated_at'] = DateTime.now().toUtc().toIso8601String()
      ..['version'] = currentVersion + 1;
    await db.update('rentals', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> softDelete(
    DatabaseExecutor db,
    String id,
    int currentVersion,
  ) async {
    await db.update(
      'rentals',
      {
        'is_deleted': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'version': currentVersion + 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
