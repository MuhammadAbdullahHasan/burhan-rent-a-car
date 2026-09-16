import 'dart:convert';
import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// What one sync pass did, for the UI to report.
class SyncSummary {
  final int pushed;
  final int pulled;
  final String? error;

  const SyncSummary({required this.pushed, required this.pulled, this.error});

  bool get hasError => error != null;
  bool get changedAnything => pushed > 0 || pulled > 0;
}

const _watermarkKey = 'cloud_last_synced_at';
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
class CloudSyncEngine {
  final SupabaseClient client;
  final Database db;
  final Outbox _outbox = Outbox();

  CloudSyncEngine({required this.client, required this.db});

  Future<SyncSummary> syncNow() async {
    var pushed = 0;
    String? error;
    try {
      pushed = await _push();
    } catch (e) {
      error = e.toString();
    }
    var pulled = 0;
    try {
      pulled = await _pull();
    } catch (e) {
      error ??= e.toString();
    }
    return SyncSummary(pushed: pushed, pulled: pulled, error: error);
  }

  // ---- push ------------------------------------------------------------

  Future<int> _push() async {
    var count = 0;
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
        count++;
      } catch (e) {
        await _outbox.markFailed(db, id, e.toString());
      }
    }
    return count;
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
  /// no permanent number yet. Ask Postgres for one (atomic, via the
  /// allocate_rental_no() sequence) before pushing, exactly once -- if this
  /// item is retried after a partial failure, rental_no is already set
  /// locally, so it's never asked for twice.
  Future<void> _pushRental(String id) async {
    final rows = await db.query('rentals', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    var row = rows.first;

    if (row['rental_no'] == null) {
      final response = await client.rpc('allocate_rental_no');
      final rentalNo = (response as num).toInt();
      await db.update(
        'rentals',
        {'rental_no': rentalNo},
        where: 'id = ?',
        whereArgs: [id],
      );
      row = {...row, 'rental_no': rentalNo};
    }

    await client.from('rentals').upsert(_rentalToRemote(row));
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

    var count = 0;
    count += await _pullTable(
      'customers',
      since,
      await _pendingIdsFor('customer'),
      _applyCustomer,
    );
    count += await _pullTable(
      'vehicles',
      since,
      await _pendingIdsFor('vehicle'),
      _applyVehicle,
    );
    count += await _pullTable(
      'rentals',
      since,
      await _pendingIdsFor('rental'),
      _applyRental,
    );
    count += await _pullTable(
      'attachments',
      since,
      await _pendingIdsFor('attachment'),
      _applyAttachment,
    );

    await _setWatermark(startedAt);
    return count;
  }

  Future<int> _pullTable(
    String table,
    String since,
    Set<String> skipIds,
    Future<void> Function(Map<String, Object?>) apply,
  ) async {
    final rows = await client.from(table).select().gt('updated_at', since);
    var applied = 0;
    for (final row in rows) {
      final id = row['id'] as String;
      if (skipIds.contains(id)) continue; // has an unpushed local change
      await apply(row);
      applied++;
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

  Future<void> _applyRental(Map<String, Object?> r) => db.insert(
        'rentals',
        {
          'id': r['id'],
          'rental_no': r['rental_no'],
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
