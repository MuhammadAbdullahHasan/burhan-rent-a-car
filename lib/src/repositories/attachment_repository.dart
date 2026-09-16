import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// The one attachment kind today: a photo of the signed paper agreement.
const kindRentalAgreement = 'rental_agreement';

class AttachmentRepository {
  /// The live agreement photo for a rental, full size, or null.
  Future<Map<String, Object?>?> rentalAgreement(
    DatabaseExecutor db,
    String rentalId,
  ) async {
    final rows = await db.query(
      'attachments',
      where: "entity_type = 'rental' AND entity_id = ? AND kind = ? "
          'AND is_deleted = 0',
      whereArgs: [rentalId, kindRentalAgreement],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Thumbnails only (never the full image) for a set of rentals, keyed by
  /// rental id -- one query for a whole list of tiles.
  Future<Map<String, Uint8List>> agreementThumbnails(
    DatabaseExecutor db,
    Iterable<String> rentalIds,
  ) async {
    final ids = rentalIds.toList();
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'attachments',
      columns: ['entity_id', 'thumbnail'],
      where: "entity_type = 'rental' AND kind = ? AND is_deleted = 0 "
          'AND entity_id IN ($placeholders)',
      whereArgs: [kindRentalAgreement, ...ids],
    );
    return {
      for (final row in rows)
        if (row['thumbnail'] != null)
          row['entity_id'] as String: row['thumbnail'] as Uint8List,
    };
  }

  /// Stores a rental's agreement photo. A rental has at most one live
  /// agreement, so any previous one is retired first (soft-deleted, never
  /// erased -- same rule as every other record).
  Future<String> setRentalAgreement(
    DatabaseExecutor db, {
    required String rentalId,
    required Uint8List image,
    Uint8List? thumbnail,
    String? mimeType,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _retire(db, rentalId, now);
    final id = _uuid.v4();
    await db.insert('attachments', {
      'id': id,
      'entity_type': 'rental',
      'entity_id': rentalId,
      'kind': kindRentalAgreement,
      'mime_type': mimeType,
      'image': image,
      'thumbnail': thumbnail,
      'is_deleted': 0,
      'version': 1,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<void> removeRentalAgreement(
    DatabaseExecutor db,
    String rentalId,
  ) {
    return _retire(db, rentalId, DateTime.now().toUtc().toIso8601String());
  }

  Future<void> _retire(DatabaseExecutor db, String rentalId, String now) {
    return db.rawUpdate(
      'UPDATE attachments SET is_deleted = 1, version = version + 1, '
      "updated_at = ? WHERE entity_type = 'rental' AND entity_id = ? "
      'AND kind = ? AND is_deleted = 0',
      [now, rentalId, kindRentalAgreement],
    );
  }
}
