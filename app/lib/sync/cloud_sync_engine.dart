import 'dart:convert';
import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What one sync pass did, for the UI to report.
class SyncSummary {
  final int pushed;
  final int pulled;
  final int failed;
  final String? error;

  const SyncSummary({
    required this.pushed,
    required this.pulled,
    this.failed = 0,
    this.error,
  });

  bool get hasError => error != null || failed > 0;
  bool get changedAnything => pushed > 0 || pulled > 0;
}

const _watermarkKey = 'cloud_last_synced_at';
const _hydratedKey = 'cloud_hydrated';
const _epoch = '1970-01-01T00:00:00.000Z';

/// Pushes queued local changes to Postgres, then pulls anything changed
/// remotely since this device's last successful sync -- the actual network
/// half of the outbox/sync_queue design the local data layer already has.
///
/// Every read/write the rest of the app does still goes to local SQLite
/// (offline-first, unchanged); this engine is the only thing that talks to
/// Supabase, and it only ever updates local rows to match. Push always runs
/// before pull in the same pass, so a pull can never clobber a change this
/// device hasn't sent yet -- and as a second guard, pull skips any row
/// still sitting in the outbox as pending.
///
/// The cloud is the single source of the dataset: a device starts empty and
/// is filled by its first pull ("hydration"). Devices from before that rule
/// existed hold their own private copy of the test dataset instead; the
/// first sync on such a device replaces that copy with the cloud's and
/// re-sends whatever the owner created or edited on it -- see [_hydrate].
class CloudSyncEngine {
  final SupabaseClient client;
  final Database db;
  final Outbox _outbox = Outbox();
  Future<SyncSummary>? _inFlight;

  CloudSyncEngine({required this.client, required this.db});

  /// True once this device's local data has been taken from the cloud
  /// rather than seeded locally.
  static Future<bool> isHydrated(DatabaseExecutor db) async {
    final rows = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [_hydratedKey],
    );
    return rows.isNotEmpty;
  }

  /// Overlapping calls (launch, connectivity, a "Sync Now" tap) share one
  /// pass: two passes at once could ask the server for a rental number
  /// twice for the same rental.
  Future<SyncSummary> syncNow() {
    return _inFlight ??= _run().whenComplete(() => _inFlight = null);
  }

  Future<SyncSummary> _run() async {
    if (!await isHydrated(db)) {
      try {
        await _hydrate();
      } catch (e) {
        return SyncSummary(pushed: 0, pulled: 0, error: e.toString());
      }
    }

    var pushed = 0;
    var failed = 0;
    String? error;
    try {
      final result = await _push();
      pushed = result.pushed;
      failed = result.failed;
      error = result.firstError;
    } catch (e) {
      error = e.toString();
    }
    var pulled = 0;
    try {
      pulled = await _pull();
    } catch (e) {
      error ??= e.toString();
    }
    return SyncSummary(
      pushed: pushed,
      pulled: pulled,
      failed: failed,
      error: error,
    );
  }

  // ---- push ------------------------------------------------------------

  Future<({int pushed, int failed, String? firstError})> _push() async {
    var pushed = 0;
    var failed = 0;
    String? firstError;
    for (final item in await _outbox.pending(db)) {
      final id = item['id'] as String;
      final entityType = item['entity_type'] as String;
      final entityId = item['entity_id'] as String;
      try {
        switch (entityType) {
          case 'customer':
            await _pushSimple('customers', entityId, _customerToRemote);
          case 'vehicle':
            await _pushSimple('vehicles', entityId, _vehicleToRemote);
          case 'rental':
            await _pushRental(entityId);
          case 'attachment':
            await _pushAttachment(entityId);
          default:
            // Unknown entity type from a future version; nothing to do,
            // but don't leave it stuck retrying forever.
            break;
        }
        await _outbox.markDone(db, id);
        pushed++;
      } catch (e) {
        failed++;
        firstError ??= e.toString();
        await _outbox.markFailed(db, id, e.toString());
      }
    }
    return (pushed: pushed, failed: failed, firstError: firstError);
  }

  Future<void> _pushSimple(
    String table,
    String id,
    Map<String, Object?> Function(Map<String, Object?>) toRemote,
  ) async {
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return; // locally deleted before it ever synced
    await client.from(table).upsert(toRemote(rows.first));
  }

  /// The one entity with server-owned state: a rental created offline has
  /// no permanent number yet. Ask Postgres for one (atomic, via
  /// allocate_rental_no()) before pushing, exactly once -- if this item is
  /// retried after a partial failure, rental_no is already set locally, so
  /// it's never asked for twice.
  Future<void> _pushRental(String id) async {
    final rows = await db.query('rentals', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    var row = rows.first;

    await _ensureRemote(
      'customers',
      row['customer_id'] as String?,
      _customerToRemote,
    );
    await _ensureRemote(
      'vehicles',
      row['vehicle_id'] as String?,
      _vehicleToRemote,
    );

    if (row['rental_no'] == null) {
      row = {...row, 'rental_no': await _allocateNumber(id)};
    }

    try {
      await client.from('rentals').upsert(_rentalToRemote(row));
    } on PostgrestException catch (e) {
      // A number this device held without the server ever storing it
      // (assigned by the pre-cloud local stand-in, or allocated but then
      // refused for another reason) has since been taken. It was never a
      // confirmed number, so the server issues the real one now.
      final numberTaken = e.code == '23505' && e.message.contains('rental_no');
      if (!numberTaken || !await _createdLocally('rental', id)) rethrow;
      row = {...row, 'rental_no': await _allocateNumber(id)};
      await client.from('rentals').upsert(_rentalToRemote(row));
    }
  }

  Future<int> _allocateNumber(String rentalId) async {
    final response = await client.rpc('allocate_rental_no');
    final rentalNo = (response as num).toInt();
    await db.update(
      'rentals',
      {'rental_no': rentalNo},
      where: 'id = ?',
      whereArgs: [rentalId],
    );
    return rentalNo;
  }

  /// A rental's customer/vehicle must exist on the server before the
  /// rental can (foreign keys). Normally the outbox order guarantees that;
  /// this covers a parent that exists only locally for any other reason.
  /// Insert-if-missing only -- never overwrite a server copy that might be
  /// newer than ours.
  Future<void> _ensureRemote(
    String table,
    String? id,
    Map<String, Object?> Function(Map<String, Object?>) toRemote,
  ) async {
    if (id == null) return;
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    await client
        .from(table)
        .upsert(toRemote(rows.first), ignoreDuplicates: true);
  }

  Future<void> _pushAttachment(String id) async {
    final rows =
        await db.query('attachments', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final row = rows.first;
    final thumb = row['thumbnail'] as Uint8List?;
    await client.from('attachments').upsert({
      'id': row['id'],
      'entity_type': row['entity_type'],
      'entity_id': row['entity_id'],
      'kind': row['kind'],
      'mime_type': row['mime_type'],
      'image_base64': base64Encode(row['image'] as Uint8List),
      'thumbnail_base64': thumb == null ? null : base64Encode(thumb),
      'is_deleted': _asBool(row['is_deleted']),
      'version': row['version'],
      'created_at': row['created_at'],
      'updated_at': row['updated_at'],
    });
  }

  // ---- pull --------------------------------------------------------------

  Future<int> _pull() async {
    final since = await _watermark();
    final startedAt = DateTime.now().toUtc().toIso8601String();
    final pulled = await _pullAll(since);
    await _setWatermark(startedAt);
    return pulled.values.fold<int>(0, (sum, ids) => sum + ids.length);
  }

  /// Pulls every table; returns the ids applied per table.
  Future<Map<String, Set<String>>> _pullAll(String since) async {
    return {
      'customers': await _pullTable(
        'customers',
        since,
        await _pendingIdsFor('customer'),
        _applyCustomer,
      ),
      'vehicles': await _pullTable(
        'vehicles',
        since,
        await _pendingIdsFor('vehicle'),
        _applyVehicle,
      ),
      'rentals': await _pullTable(
        'rentals',
        since,
        await _pendingIdsFor('rental'),
        _applyRental,
      ),
      'attachments': await _pullTable(
        'attachments',
        since,
        await _pendingIdsFor('attachment'),
        _applyAttachment,
      ),
    };
  }

  Future<Set<String>> _pullTable(
    String table,
    String since,
    Set<String> skipIds,
    Future<void> Function(Map<String, Object?>) apply,
  ) async {
    final rows = await client.from(table).select().gt('updated_at', since);
    final applied = <String>{};
    for (final row in rows) {
      final id = row['id'] as String;
      if (skipIds.contains(id)) continue; // has an unpushed local change
      await apply(row);
      applied.add(id);
    }
    return applied;
  }

  Future<Set<String>> _pendingIdsFor(String entityType) async {
    final rows = await db.query(
      'sync_queue',
      columns: ['entity_id'],
      where: "entity_type = ? AND status = 'pending'",
      whereArgs: [entityType],
    );
    return rows.map((r) => r['entity_id'] as String).toSet();
  }

  Future<void> _applyCustomer(Map<String, Object?> r) => db.insert(
        'customers',
        {
          'id': r['id'],
          'full_name': r['full_name'],
          'phone': r['phone'],
          'phone_normalized': r['phone_normalized'],
          'cnic': r['cnic'],
          'cnic_normalized': r['cnic_normalized'],
          'license_no': r['license_no'],
          'license_city': r['license_city'],
          'possible_duplicate': _asInt(r['possible_duplicate']),
          'is_deleted': _asInt(r['is_deleted']),
          'version': r['version'],
          'created_at': r['created_at'],
          'updated_at': r['updated_at'],
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> _applyVehicle(Map<String, Object?> r) => db.insert(
        'vehicles',
        {
          'id': r['id'],
          'registration_no': r['registration_no'],
          'registration_norm': r['registration_norm'],
          'chassis_no': r['chassis_no'],
          'engine_no': r['engine_no'],
          'company': r['company'],
          'model_name': r['model_name'],
          'trim': r['trim'],
          'horsepower': r['horsepower'],
          'color': r['color'],
          'reg_year': r['reg_year'],
          'insurance_due_on': r['insurance_due_on'],
          'is_deleted': _asInt(r['is_deleted']),
          'version': r['version'],
          'created_at': r['created_at'],
          'updated_at': r['updated_at'],
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// The server's number is authoritative. If a *locally created* rental
  /// already carries the incoming number (assigned by the pre-cloud local
  /// stand-in), it goes back to Pending and is renumbered when pushed; a
  /// stale copy of a cloud row simply gets replaced.
  Future<void> _applyRental(Map<String, Object?> r) async {
    final rentalNo = r['rental_no'];
    if (rentalNo != null) {
      final clash = await db.query(
        'rentals',
        columns: ['id'],
        where: 'rental_no = ? AND id != ?',
        whereArgs: [rentalNo, r['id']],
      );
      for (final row in clash) {
        final id = row['id'] as String;
        if (await _createdLocally('rental', id)) {
          await db.update(
            'rentals',
            {'rental_no': null},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      }
    }
    await db.insert(
      'rentals',
      {
        'id': r['id'],
        'rental_no': rentalNo,
        'is_placeholder': _asInt(r['is_placeholder']),
        'customer_id': r['customer_id'],
        'vehicle_id': r['vehicle_id'],
        'start_date': r['start_date'],
        'start_time': r['start_time'],
        'end_date': r['end_date'],
        'end_time': r['end_time'],
        'book_days': r['book_days'],
        'amount': r['amount'],
        'balance': r['balance'],
        'status': r['status'],
        'remarks': r['remarks'],
        'ref_name': r['ref_name'],
        'ref_contact': r['ref_contact'],
        'ref_relation': r['ref_relation'],
        'is_deleted': _asInt(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _applyAttachment(Map<String, Object?> r) async {
    final thumb = r['thumbnail_base64'] as String?;
    await db.insert(
      'attachments',
      {
        'id': r['id'],
        'entity_type': r['entity_type'],
        'entity_id': r['entity_id'],
        'kind': r['kind'],
        'mime_type': r['mime_type'],
        'image': base64Decode(r['image_base64'] as String),
        'thumbnail': thumb == null ? null : base64Decode(thumb),
        'is_deleted': _asInt(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---- hydration ------------------------------------------------------------

  /// First-ever cloud sync on this device. On a device that started empty
  /// this is just a full pull. On a device that still holds its own
  /// locally-seeded copy of the dataset, every row the owner never touched
  /// is a duplicate of a cloud row under a different id, so:
  ///
  ///  1. Seeded rows the owner *edited* here have their edits copied onto
  ///     the matching cloud row (same phone/CNIC, registration number or
  ///     rental number) and that row is queued as an update.
  ///  2. Rows the owner *created* here are kept and re-queued; references
  ///     from them to seeded customers/vehicles are re-pointed at the cloud
  ///     twin the same way.
  ///  3. Every other seeded row is dropped in favour of the cloud's copy.
  ///
  /// A local record whose twin can't be found is kept and sent up as new
  /// -- nothing the owner entered is ever discarded.
  Future<void> _hydrate() async {
    final startedAt = DateTime.now().toUtc().toIso8601String();
    final touched = await _touchedIds();
    final created = await _createdIds();

    // Snapshot BEFORE the pull: REPLACE on rental_no / registration_norm
    // deletes the seeded copies as their cloud twins arrive.
    final before = <String, Map<String, Map<String, Object?>>>{
      for (final table in _tables)
        table: {
          for (final r in await db.query(table)) r['id'] as String: r,
        },
    };

    // Anything still pending is re-queued below in dependency order.
    await db.update(
      'sync_queue',
      {'status': 'done'},
      where: "status = 'pending'",
    );

    final pulled = await _pullAll(_epoch);
    final twin = {for (final table in _tables) table: <String, String>{}};
    final keep = {
      for (final table in _tables) table: {...created[_typeOf(table)]!},
    };

    /// The cloud id a local reference should point at, or null when the
    /// referenced row has no twin (it is then kept and sent up as new).
    Future<String?> resolve(String table, String id) async {
      // A row created here keeps its id -- unless the pull already replaced
      // it with a cloud row carrying the same registration / number, in
      // which case that cloud row is its twin.
      if (created[_typeOf(table)]!.contains(id) &&
          await _rowById(table, id) != null) {
        return id;
      }
      final mapped = twin[table]![id];
      if (mapped != null) return mapped;
      final row = before[table]![id];
      return row == null ? null : _match(table, row, pulled[table]!);
    }

    Future<String> resolveOrKeep(String table, String id) async {
      final target = await resolve(table, id);
      if (target != null) return target;
      keep[table]!.add(id);
      return id;
    }

    // 1. Edits to seeded rows -> onto the cloud twin. Customers and
    //    vehicles first so rentals can resolve through them.
    for (final table in _tables) {
      final type = _typeOf(table);
      for (final id in touched[type]!.difference(created[type]!)) {
        final row = before[table]![id];
        if (row == null) continue;
        final target = await _match(table, row, pulled[table]!);
        if (target == null) {
          keep[table]!.add(id);
          continue;
        }
        final cloud = await _rowById(table, target);
        final merged = Map<String, Object?>.from(row)
          ..remove('id')
          ..remove('created_at')
          ..remove('rental_no')
          ..remove('registration_norm');
        if (table == 'rentals') {
          for (final (column, parent) in _rentalParents) {
            final ref = row[column] as String?;
            if (ref != null) merged[column] = await resolveOrKeep(parent, ref);
          }
        }
        merged['version'] = ((cloud?['version'] as int?) ?? 0) + 1;
        merged['updated_at'] = DateTime.now().toUtc().toIso8601String();
        await db.update(table, merged, where: 'id = ?', whereArgs: [target]);
        twin[table]![id] = target;
      }
    }

    // 2. Rentals created here -> point at cloud customers/vehicles. One the
    //    server does not hold yet also gives up any number it carries: that
    //    number was never confirmed (pre-cloud stand-in, or allocated but
    //    then refused), and the server issues the real one on push. A
    //    rental the server already stores keeps its number, untouched.
    for (final id in created['rental']!) {
      final row = await _rowById('rentals', id);
      if (row == null) continue;
      final updates = <String, Object?>{};
      if (!pulled['rentals']!.contains(id) && row['rental_no'] != null) {
        updates['rental_no'] = null;
      }
      for (final (column, parent) in _rentalParents) {
        final ref = row[column] as String?;
        if (ref == null) continue;
        final target = await resolveOrKeep(parent, ref);
        if (target != ref) updates[column] = target;
      }
      if (updates.isNotEmpty) {
        await db.update('rentals', updates, where: 'id = ?', whereArgs: [id]);
      }
    }

    // 3. Photos follow their rental to its cloud id.
    for (final id in touched['attachment']!) {
      final row = await _rowById('attachments', id);
      if (row == null) continue;
      final rentalId = row['entity_id'] as String;
      final target = await resolveOrKeep('rentals', rentalId);
      if (target != rentalId) {
        await db.update(
          'attachments',
          {'entity_id': target},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }

    // 4. Drop the device's private seeded copies that now have a cloud twin.
    for (final table in _tables) {
      await _dropExcept(table, {...pulled[table]!, ...keep[table]!});
    }

    // 5. Re-queue in dependency order so parents reach the server first.
    for (final table in _tables) {
      for (final id in keep[table]!) {
        await _outbox.enqueue(
          db,
          entityType: _typeOf(table),
          entityId: id,
          operation: 'insert',
        );
      }
      for (final id in twin[table]!.values) {
        await _outbox.enqueue(
          db,
          entityType: _typeOf(table),
          entityId: id,
          operation: 'update',
        );
      }
    }
    for (final id in touched['attachment']!) {
      await _outbox.enqueue(
        db,
        entityType: 'attachment',
        entityId: id,
        operation: 'insert',
      );
    }

    await _setWatermark(startedAt);
    await db.insert(
      'app_meta',
      {'key': _hydratedKey, 'value': startedAt},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static const _tables = ['customers', 'vehicles', 'rentals'];
  static const _rentalParents = [
    ('customer_id', 'customers'),
    ('vehicle_id', 'vehicles'),
  ];

  /// Entity ids by type that have ever been through the outbox -- i.e.
  /// everything the owner created or edited on this device.
  Future<Map<String, Set<String>>> _touchedIds() => _queueIds();

  Future<Map<String, Set<String>>> _createdIds() =>
      _queueIds(where: "operation = 'insert'");

  Future<Map<String, Set<String>>> _queueIds({String? where}) async {
    final rows = await db.query(
      'sync_queue',
      columns: ['entity_type', 'entity_id'],
      where: where,
    );
    final result = {
      'customer': <String>{},
      'vehicle': <String>{},
      'rental': <String>{},
      'attachment': <String>{},
    };
    for (final r in rows) {
      result[r['entity_type']]?.add(r['entity_id'] as String);
    }
    return result;
  }

  Future<bool> _createdLocally(String entityType, String id) async {
    final rows = await db.query(
      'sync_queue',
      columns: ['id'],
      where: "entity_type = ? AND entity_id = ? AND operation = 'insert'",
      whereArgs: [entityType, id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The cloud twin of a seeded row among the rows just pulled: customers
  /// by normalized phone, then CNIC (never by name); vehicles by normalized
  /// registration; rentals by rental number.
  Future<String?> _match(
    String table,
    Map<String, Object?> row,
    Set<String> pulled,
  ) async {
    if (pulled.isEmpty) return null;
    final String where;
    final List<Object?> args;
    switch (table) {
      case 'customers':
        final phone = row['phone_normalized'] as String?;
        final cnic = row['cnic_normalized'] as String?;
        if (phone == null && cnic == null) return null;
        where = '((? IS NOT NULL AND phone_normalized = ?) OR '
            '(? IS NOT NULL AND cnic_normalized = ?))';
        args = [phone, phone, cnic, cnic];
      case 'vehicles':
        final norm = row['registration_norm'];
        if (norm == null) return null;
        where = 'registration_norm = ?';
        args = [norm];
      default:
        final rentalNo = row['rental_no'];
        if (rentalNo == null) return null;
        where = 'rental_no = ?';
        args = [rentalNo];
    }
    final placeholders = List.filled(pulled.length, '?').join(',');
    final rows = await db.query(
      table,
      columns: ['id'],
      where: 'id IN ($placeholders) AND $where',
      whereArgs: [...pulled, ...args],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<void> _dropExcept(String table, Set<String> survivors) async {
    if (survivors.isEmpty) {
      await db.delete(table);
      return;
    }
    await db.delete(
      table,
      where: 'id NOT IN (${List.filled(survivors.length, '?').join(',')})',
      whereArgs: survivors.toList(),
    );
  }

  Future<Map<String, Object?>?> _rowById(String table, String id) async {
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  String _typeOf(String table) => switch (table) {
        'customers' => 'customer',
        'vehicles' => 'vehicle',
        'rentals' => 'rental',
        _ => 'attachment',
      };

  // ---- watermark -----------------------------------------------------------

  Future<String> _watermark() async {
    final rows = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [_watermarkKey],
    );
    return rows.isEmpty ? _epoch : rows.first['value'] as String;
  }

  Future<void> _setWatermark(String iso) => db.insert(
        'app_meta',
        {'key': _watermarkKey, 'value': iso},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  // ---- row shape: local -> remote -------------------------------------------

  Map<String, Object?> _customerToRemote(Map<String, Object?> r) => {
        'id': r['id'],
        'full_name': r['full_name'],
        'phone': r['phone'],
        'phone_normalized': r['phone_normalized'],
        'cnic': r['cnic'],
        'cnic_normalized': r['cnic_normalized'],
        'license_no': r['license_no'],
        'license_city': r['license_city'],
        'possible_duplicate': _asBool(r['possible_duplicate']),
        'is_deleted': _asBool(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };

  Map<String, Object?> _vehicleToRemote(Map<String, Object?> r) => {
        'id': r['id'],
        'registration_no': r['registration_no'],
        'registration_norm': r['registration_norm'],
        'chassis_no': r['chassis_no'],
        'engine_no': r['engine_no'],
        'company': r['company'],
        'model_name': r['model_name'],
        'trim': r['trim'],
        'horsepower': r['horsepower'],
        'color': r['color'],
        'reg_year': r['reg_year'],
        'insurance_due_on': r['insurance_due_on'],
        'is_deleted': _asBool(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };

  Map<String, Object?> _rentalToRemote(Map<String, Object?> r) => {
        'id': r['id'],
        'rental_no': r['rental_no'],
        'is_placeholder': _asBool(r['is_placeholder']),
        'customer_id': r['customer_id'],
        'vehicle_id': r['vehicle_id'],
        'start_date': r['start_date'],
        'start_time': r['start_time'],
        'end_date': r['end_date'],
        'end_time': r['end_time'],
        'book_days': r['book_days'],
        'amount': r['amount'],
        'balance': r['balance'],
        'status': r['status'],
        'remarks': r['remarks'],
        'ref_name': r['ref_name'],
        'ref_contact': r['ref_contact'],
        'ref_relation': r['ref_relation'],
        'is_deleted': _asBool(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };
}

bool _asBool(Object? sqliteInt) => sqliteInt == 1;
int _asInt(Object? remoteBool) => remoteBool == true ? 1 : 0;
