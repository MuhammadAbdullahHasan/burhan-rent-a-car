import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_services.dart';
import 'backup_codec.dart';

const _bucket = 'backups';
const _lastBackupKey = 'cloud_backup_at';
const _keep = 7;

/// A daily snapshot of every record, kept in a private bucket that only
/// the signed-in owner can read -- an independent copy in case rows are
/// ever deleted or damaged in the live tables. The last [_keep] are
/// retained. Agreement photos are left out (they would exhaust the storage
/// quota within months); they stay in the live tables and in the
/// password-protected file backup.
class CloudBackup {
  final SupabaseClient client;
  final Database db;

  CloudBackup({required this.client, required this.db});

  String get _folder => client.auth.currentUser!.id;

  Future<DateTime?> lastBackupAt() async {
    final rows = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [_lastBackupKey],
    );
    return rows.isEmpty
        ? null
        : DateTime.tryParse(rows.first['value'] as String);
  }

  /// Uploads a snapshot now. Returns the object name.
  Future<String> backupNow() async {
    final snapshot = await exportSnapshot(db, includeAttachments: false);
    final bytes = await BackupCodec.encodeSnapshot(snapshot);
    final stamp = DateTime.now().toUtc();
    final name =
        'backup-${stamp.toIso8601String().replaceAll(':', '-')}.json.gz';
    await client.storage.from(_bucket).uploadBinary(
          '$_folder/$name',
          bytes,
          fileOptions: const FileOptions(
            contentType: 'application/gzip',
            upsert: true,
          ),
        );
    await db.insert(
      'app_meta',
      {'key': _lastBackupKey, 'value': stamp.toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _prune();
    return name;
  }

  /// Runs [backupNow] if the last one is older than a day.
  Future<void> maybeBackup() async {
    final last = await lastBackupAt();
    if (last != null &&
        DateTime.now().difference(last) < const Duration(hours: 24)) {
      return;
    }
    await backupNow();
  }

  Future<List<CloudBackupEntry>> list() async {
    final objects = await client.storage.from(_bucket).list(
          path: _folder,
          searchOptions: const SearchOptions(
            sortBy: SortBy(column: 'name', order: 'desc'),
          ),
        );
    return [
      for (final o in objects)
        if (o.name.endsWith('.json.gz'))
          CloudBackupEntry(
            name: o.name,
            createdAt: DateTime.tryParse(o.createdAt ?? '') ??
                DateTime.tryParse(o.updatedAt ?? ''),
            size: (o.metadata?['size'] as num?)?.toInt(),
          ),
    ];
  }

  Future<Snapshot> download(String name) async {
    final Uint8List bytes =
        await client.storage.from(_bucket).download('$_folder/$name');
    return BackupCodec.decodeSnapshot(bytes);
  }

  Future<void> _prune() async {
    final entries = await list();
    if (entries.length <= _keep) return;
    final stale = entries.skip(_keep).map((e) => '$_folder/${e.name}').toList();
    await client.storage.from(_bucket).remove(stale);
  }
}

class CloudBackupEntry {
  final String name;
  final DateTime? createdAt;
  final int? size;
  const CloudBackupEntry({required this.name, this.createdAt, this.size});
}

/// Fire-and-forget daily backup after a clean sync. Never throws into the
/// sync path; a failed backup simply tries again on the next pass.
void maybeCloudBackup(AppServices services) {
  final backup = services.cloudBackup;
  if (backup == null) return;
  backup.maybeBackup().catchError((_) {});
}

/// Applies a snapshot to this device and the cloud:
///  * locally by id (a row present in both takes the backup's values);
///  * to the cloud as "fill what is missing" -- rows the cloud already has
///    are left as they are, so a stale backup can never overwrite live
///    records -- after which a full pull brings this device back in line
///    with the cloud.
/// Restoring twice, or over existing data, never duplicates a record.
Future<void> restoreIntoApp(AppServices services, Snapshot snapshot) async {
  await restoreSnapshot(services.db, snapshot);
  final outbox = Outbox();
  Future<void> queue(String type, List<Map<String, Object?>> rows) =>
      outbox.enqueueAll(
        services.db,
        entityType: type,
        entityIds: rows.map((r) => r['id'] as String),
        operation: 'restore',
      );
  await queue('customer', snapshot.customers);
  await queue('vehicle', snapshot.vehicles);
  await queue('rental', snapshot.rentals);
  await queue('attachment', snapshot.attachments);
  await services.cloudSync?.forceFullPull();
  services.dataChanged.value++;
  services.cloudSync?.requestSync();
}
