import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// The persistent outbox (sync_queue table). Every local mutation is
/// appended here in the same transaction as the entity write, so it
/// survives app restart/connectivity loss by construction (it's just a
/// durable SQLite row, not in-memory state).
class Outbox {
  Future<String> enqueue(
    DatabaseExecutor db, {
    required String entityType,
    required String entityId,
    required String operation,
    Map<String, Object?>? payload,
  }) async {
    final id = _uuid.v4();
    await db.insert('sync_queue', {
      'id': id,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation,
      'payload': payload == null ? null : jsonEncode(payload),
      'status': 'pending',
      'retry_count': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    return id;
  }

  /// Queues many rows of one type at once (restore, migration).
  Future<void> enqueueAll(
    DatabaseExecutor db, {
    required String entityType,
    required Iterable<String> entityIds,
    required String operation,
  }) async {
    final batch = db.batch();
    final now = DateTime.now().toUtc().toIso8601String();
    for (final entityId in entityIds) {
      batch.insert('sync_queue', {
        'id': _uuid.v4(),
        'entity_type': entityType,
        'entity_id': entityId,
        'operation': operation,
        'payload': null,
        'status': 'pending',
        'retry_count': 0,
        'created_at': now,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<int> pendingCount(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM sync_queue WHERE status = 'pending'",
    );
    return rows.first['c'] as int;
  }

  Future<List<Map<String, Object?>>> pending(DatabaseExecutor db) {
    return db.query(
      'sync_queue',
      where: "status = 'pending'",
      orderBy: 'created_at ASC, rowid ASC',
    );
  }

  /// Every waiting change with what the owner needs to judge it: what it
  /// is, how many times it has been tried and the last error the server or
  /// the network gave. Oldest first, like [pending].
  Future<List<Map<String, Object?>>> pendingDetails(DatabaseExecutor db) {
    return db.rawQuery('''
      SELECT q.id, q.entity_type, q.entity_id, q.operation, q.retry_count,
             q.last_error, q.created_at,
             r.rental_no, r.is_placeholder,
             c.full_name AS customer_name,
             v.registration_no AS vehicle_registration,
             ar.rental_no AS attachment_rental_no
      FROM sync_queue q
      LEFT JOIN rentals r ON q.entity_type = 'rental' AND r.id = q.entity_id
      LEFT JOIN customers c ON q.entity_type = 'customer' AND c.id = q.entity_id
      LEFT JOIN vehicles v ON q.entity_type = 'vehicle' AND v.id = q.entity_id
      LEFT JOIN attachments a ON q.entity_type = 'attachment' AND a.id = q.entity_id
      LEFT JOIN rentals ar ON ar.id = a.entity_id
      WHERE q.status = 'pending'
      ORDER BY q.created_at ASC, q.rowid ASC
    ''');
  }

  /// Gives up on one waiting change: the local row keeps whatever the owner
  /// typed, but it will no longer be sent, and the next pull brings the
  /// cloud's version back over it. For a change the server rejects every
  /// time -- the owner's explicit call, never automatic.
  Future<void> discard(DatabaseExecutor db, String id) {
    return db.update(
      'sync_queue',
      {'status': 'discarded'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markDone(DatabaseExecutor db, String id) {
    return db.update(
      'sync_queue',
      {'status': 'done'},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(DatabaseExecutor db, String id, String error) async {
    final rows = await db.query('sync_queue', where: 'id = ?', whereArgs: [id]);
    final retryCount = (rows.first['retry_count'] as int) + 1;
    await db.update(
      'sync_queue',
      {'status': 'pending', 'retry_count': retryCount, 'last_error': error},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
