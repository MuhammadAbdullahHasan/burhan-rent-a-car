import 'package:sqflite_common/sqlite_api.dart';

import 'schema.dart';

/// Opens (and creates, if needed) the local SQLite database.
///
/// The [DatabaseFactory] is injected rather than hard-coded so the exact
/// same schema/repositories/pipeline run in three places unchanged: the
/// Android app (plain `sqflite`'s `databaseFactory`), this package's tests
/// and CLI (`sqflite_common_ffi`'s `databaseFactoryFfi`), and later any
/// desktop build. Nothing below the factory knows the difference.
Future<Database> openAppDatabase(
  DatabaseFactory factory,
  String path,
) {
  return factory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: schemaVersion,
      onCreate: (db, version) async {
        for (final statement in createTableStatements) {
          await db.execute(statement);
        }
      },
      // Additive only: an existing device database keeps every row it has.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          for (final statement in attachmentsTableStatements) {
            await db.execute(statement);
          }
        }
        if (oldVersion < 3) {
          for (final statement in syncConflictsTableStatements) {
            await db.execute(statement);
          }
        }
        if (oldVersion < 4) {
          await _addColumns(db, 'vehicles', vehicleInFleetStatements);
          // Until the cloud says otherwise, keep what the app showed
          // before: a vehicle rented in the last two years, or one the
          // owner has described, is in the fleet.
          await db.execute('''
            UPDATE vehicles SET in_fleet = 0
            WHERE COALESCE(company, '') = ''
              AND COALESCE(model_name, '') = ''
              AND COALESCE(chassis_no, '') = ''
              AND COALESCE(engine_no, '') = ''
              AND COALESCE(insurance_due_on, '') = ''
              AND id NOT IN (
                SELECT vehicle_id FROM rentals
                WHERE vehicle_id IS NOT NULL AND is_deleted = 0
                  AND COALESCE(start_date, '') >= date('now', '-2 years')
              )
          ''');
        }
        if (oldVersion < 5) {
          await _addColumns(db, 'attachments', attachmentStoragePathStatements);
        }
      },
    ),
  );
}

/// Runs "ALTER TABLE ... ADD COLUMN" statements that may already have been
/// applied. A step that creates a table uses the schema as it stands
/// today, so a database upgrading across several versions can arrive at a
/// later step with the column already in place -- adding it again is an
/// error, and skipping it silently is what the step meant anyway.
Future<void> _addColumns(
  Database db,
  String table,
  List<String> statements,
) async {
  final existing = {
    for (final row in await db.rawQuery('PRAGMA table_info($table)'))
      (row['name'] as String).toLowerCase(),
  };
  for (final statement in statements) {
    final match = RegExp(r'ADD COLUMN\s+(\w+)', caseSensitive: false)
        .firstMatch(statement);
    final column = match?.group(1)?.toLowerCase();
    if (column != null && existing.contains(column)) continue;
    await db.execute(statement);
  }
}
