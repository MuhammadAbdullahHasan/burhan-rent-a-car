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

  Future<List<Map<String, Object?>>> pending(DatabaseExecutor db) {
    return db.query(
      'sync_queue',
      where: "status = 'pending'",
      orderBy: 'created_at ASC',
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
