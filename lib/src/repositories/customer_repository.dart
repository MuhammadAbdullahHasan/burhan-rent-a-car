import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// CRUD + the two lookups the conservative dedupe rule needs. Takes a
/// [DatabaseExecutor] rather than [Database] so the same calls work whether
/// they run standalone or inside a transaction.
class CustomerRepository {
  Future<Map<String, Object?>?> findByPhoneNormalized(
    DatabaseExecutor db,
    String phoneNormalized,
  ) async {
    final rows = await db.query(
      'customers',
      where: 'phone_normalized = ? AND is_deleted = 0',
      whereArgs: [phoneNormalized],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Every (non-deleted) customer on a phone number, oldest first. Family
  /// members routinely share one number, so a phone alone can map to more
  /// than one person -- see ImportPipeline's name check.
  Future<List<Map<String, Object?>>> findAllByPhoneNormalized(
    DatabaseExecutor db,
    String phoneNormalized,
  ) {
    return db.query(
      'customers',
      where: 'phone_normalized = ? AND is_deleted = 0',
      whereArgs: [phoneNormalized],
      orderBy: 'created_at ASC',
    );
  }

  /// The conservative repeat-customer match: normalized phone first, then
  /// CNIC, never name. Null when neither is given or nothing matches.
  Future<Map<String, Object?>?> findByPhoneOrCnic(
    DatabaseExecutor db, {
    String? phoneNormalized,
    String? cnicNormalized,
  }) async {
    if (phoneNormalized != null) {
      final byPhone = await findByPhoneNormalized(db, phoneNormalized);
      if (byPhone != null) return byPhone;
    }
    if (cnicNormalized != null) {
      return findByCnicNormalized(db, cnicNormalized);
    }
    return null;
  }

  Future<Map<String, Object?>?> findByCnicNormalized(
    DatabaseExecutor db,
    String cnicNormalized,
  ) async {
    final rows = await db.query(
      'customers',
      where: 'cnic_normalized = ? AND is_deleted = 0',
      whereArgs: [cnicNormalized],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> searchByName(
    DatabaseExecutor db,
    String query,
  ) {
    return db.query(
      'customers',
      where: 'full_name LIKE ? COLLATE NOCASE AND is_deleted = 0',
      whereArgs: ['%$query%'],
    );
  }

  Future<Map<String, Object?>?> getById(DatabaseExecutor db, String id) async {
    final rows = await db.query('customers', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> insert(
    DatabaseExecutor db, {
    String? fullName,
    String? phone,
    String? phoneNormalized,
    String? cnic,
    String? cnicNormalized,
    String? licenseNo,
    String? licenseCity,
    bool possibleDuplicate = false,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('customers', {
      'id': id,
      'full_name': fullName,
      'phone': phone,
      'phone_normalized': phoneNormalized,
      'cnic': cnic,
      'cnic_normalized': cnicNormalized,
      'license_no': licenseNo,
      'license_city': licenseCity,
      'possible_duplicate': possibleDuplicate ? 1 : 0,
      'is_deleted': 0,
      'version': 1,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<List<Map<String, Object?>>> listAll(
    DatabaseExecutor db, {
    int? limit,
  }) {
    return db.query(
      'customers',
      where: 'is_deleted = 0',
      orderBy: 'full_name COLLATE NOCASE ASC',
      limit: limit,
    );
  }

  /// The distinct vehicles this customer has rented, with how many times
  /// each -- the "other vehicles" section of the customer profile.
  Future<List<Map<String, Object?>>> vehiclesFor(
    DatabaseExecutor db,
    String customerId,
  ) {
    return db.rawQuery('''
      SELECT v.*, COUNT(r.id) AS rental_count
      FROM vehicles v
      JOIN rentals r ON r.vehicle_id = v.id
      WHERE r.customer_id = ? AND r.is_deleted = 0 AND v.is_deleted = 0
      GROUP BY v.id
      ORDER BY rental_count DESC, v.registration_no COLLATE NOCASE ASC
    ''', [customerId]);
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
    await db.update('customers', updates, where: 'id = ?', whereArgs: [id]);
  }

  /// Fills any currently-NULL column on the existing customer from a newly
  /// seen row's values -- never overwrites a value that's already present.
  Future<void> backfill(
    DatabaseExecutor db,
    Map<String, Object?> existing, {
    String? phone,
    String? phoneNormalized,
    String? cnic,
    String? cnicNormalized,
    String? licenseNo,
    String? licenseCity,
  }) async {
    final updates = <String, Object?>{};
    void maybeSet(String column, Object? incoming) {
      if (existing[column] == null && incoming != null) {
        updates[column] = incoming;
      }
    }

    maybeSet('phone', phone);
    maybeSet('phone_normalized', phoneNormalized);
    maybeSet('cnic', cnic);
    maybeSet('cnic_normalized', cnicNormalized);
    maybeSet('license_no', licenseNo);
    maybeSet('license_city', licenseCity);

    if (updates.isEmpty) return;
    updates['updated_at'] = DateTime.now().toUtc().toIso8601String();
    updates['version'] = (existing['version'] as int) + 1;
    await db.update(
      'customers',
      updates,
      where: 'id = ?',
      whereArgs: [existing['id']],
    );
  }
}
