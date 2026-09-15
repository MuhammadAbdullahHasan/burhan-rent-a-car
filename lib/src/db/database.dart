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
    ),
  );
}
