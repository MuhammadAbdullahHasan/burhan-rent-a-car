import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class VehicleRepository {
  Future<Map<String, Object?>?> findByRegistrationNorm(
    DatabaseExecutor db,
    String registrationNorm,
  ) async {
    final rows = await db.query(
      'vehicles',
      where: 'registration_norm = ? AND is_deleted = 0',
      whereArgs: [registrationNorm],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, Object?>?> getById(DatabaseExecutor db, String id) async {
    final rows = await db.query('vehicles', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<String> insert(
    DatabaseExecutor db, {
    String? registrationNo,
    String? registrationNorm,
    String? chassisNo,
    String? engineNo,
    String? company,
    String? modelName,
    String? trim,
    String? horsepower,
    String? color,
    int? regYear,
    String? insuranceDueOn,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('vehicles', {
      'id': id,
      'registration_no': registrationNo,
      'registration_norm': registrationNorm,
      'chassis_no': chassisNo,
      'engine_no': engineNo,
      'company': company,
      'model_name': modelName,
      'trim': trim,
      'horsepower': horsepower,
      'color': color,
      'reg_year': regYear,
      'insurance_due_on': insuranceDueOn,
      'is_deleted': 0,
      'version': 1,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  /// The Library (vehicle inventory) listing: one row per *distinct*
  /// vehicle, with its rental and distinct-customer counts computed in a
  /// single grouped query rather than a per-card follow-up query.
  Future<List<Map<String, Object?>>> listWithStats(DatabaseExecutor db) {
    return db.rawQuery('''
      SELECT v.*,
             COUNT(r.id) AS rental_count,
             COUNT(DISTINCT r.customer_id) AS customer_count,
             MAX(r.start_date) AS last_rental_on
      FROM vehicles v
      LEFT JOIN rentals r
        ON r.vehicle_id = v.id AND r.is_deleted = 0 AND r.is_placeholder = 0
      WHERE v.is_deleted = 0
      GROUP BY v.id
      ORDER BY v.registration_no COLLATE NOCASE ASC
    ''');
  }

  /// Whether a vehicle is part of the working fleet. The owner decides
  /// this per vehicle ([setInFleet]); everything else is a plate that only
  /// appears in the old records, which the Library keeps behind "Show past
  /// vehicles". A row from before the column existed counts as in-fleet.
  static bool isInFleet(Map<String, Object?> row) =>
      (row['in_fleet'] as int? ?? 1) == 1;

  /// Moves a vehicle into the fleet or out to the past records. Nothing
  /// about its rentals changes either way.
  Future<void> setInFleet(
    DatabaseExecutor db,
    String id,
    bool inFleet,
    int currentVersion,
  ) async {
    await db.update(
      'vehicles',
      {
        'in_fleet': inFleet ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'version': currentVersion + 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Distinct customers who have rented this vehicle, each with how many
  /// times they rented *this* vehicle.
  Future<List<Map<String, Object?>>> customersFor(
    DatabaseExecutor db,
    String vehicleId,
  ) {
    return db.rawQuery('''
      SELECT c.*, COUNT(r.id) AS rental_count
      FROM customers c
      JOIN rentals r ON r.customer_id = c.id
      WHERE r.vehicle_id = ? AND r.is_deleted = 0 AND c.is_deleted = 0
      GROUP BY c.id
      ORDER BY rental_count DESC, c.full_name COLLATE NOCASE ASC
    ''', [vehicleId]);
  }

  /// Vehicles whose insurance is already due or falls due within [withinDays].
  Future<List<Map<String, Object?>>> insuranceDue(
    DatabaseExecutor db, {
    int withinDays = 60,
  }) {
    final cutoff = DateTime.now().add(Duration(days: withinDays));
    final cutoffIso = cutoff.toIso8601String().split('T').first;
    return db.query(
      'vehicles',
      where: 'is_deleted = 0 AND insurance_due_on IS NOT NULL '
          'AND insurance_due_on <= ?',
      whereArgs: [cutoffIso],
      orderBy: 'insurance_due_on ASC',
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
    await db.update('vehicles', updates, where: 'id = ?', whereArgs: [id]);
  }

  /// Hidden from lists and search, but never erased: its own record (and
  /// every rental that references it) can still be opened directly.
  /// `registration_norm` is cleared -- the column is unique, and a null
  /// there is never a match for another row's, so the plate frees up for a
  /// fresh vehicle immediately rather than being stuck on the deleted one.
  /// `registration_no` is untouched, so the deleted record still displays
  /// correctly wherever it's reached.
  Future<void> softDelete(
    DatabaseExecutor db,
    String id,
    int currentVersion,
  ) async {
    await db.update(
      'vehicles',
      {
        'is_deleted': 1,
        'registration_norm': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'version': currentVersion + 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Compares a newly seen row's attributes against the stored vehicle and
  /// returns a human-readable mismatch description, or null if consistent.
  /// Never mutates -- the import pipeline logs this as a warning for manual
  /// review rather than silently changing vehicle specs mid-import.
  String? describeAttributeMismatch(
    Map<String, Object?> existing, {
    String? chassisNo,
    String? engineNo,
    String? company,
    String? modelName,
    String? trim,
    String? horsepower,
    String? color,
    int? regYear,
  }) {
    final mismatches = <String>[];
    void check(String label, Object? stored, Object? incoming) {
      if (incoming != null && stored != null && stored != incoming) {
        mismatches.add('$label: stored="$stored" vs incoming="$incoming"');
      }
    }

    check('chassis_no', existing['chassis_no'], chassisNo);
    check('engine_no', existing['engine_no'], engineNo);
    check('company', existing['company'], company);
    check('model_name', existing['model_name'], modelName);
    check('trim', existing['trim'], trim);
    check('horsepower', existing['horsepower'], horsepower);
    check('color', existing['color'], color);
    check('reg_year', existing['reg_year'], regYear);

    if (mismatches.isEmpty) return null;
    return mismatches.join(', ');
  }
}
