/// Public surface of the local data layer. Intended to be imported by the
/// future Flutter app (and, until then, by this package's own tests).
library burhan_rent_a_car_data;

export 'package:sqflite_common/sqlite_api.dart' show ConflictAlgorithm, Database, DatabaseExecutor, DatabaseFactory;

export 'src/backup/snapshot.dart';
export 'src/db/database.dart';
export 'src/db/schema.dart';
export 'src/import/normalizers.dart';
export 'src/search/universal_search.dart';
export 'src/import/import_pipeline.dart';
export 'src/import/mapped_rental_row.dart';
export 'src/import/reconciliation_report.dart';
export 'src/import/test_csv_mapper.dart';
export 'src/import/legacy_dump.dart';
export 'src/repositories/attachment_repository.dart';
export 'src/repositories/customer_repository.dart';
export 'src/repositories/rental_repository.dart';
export 'src/repositories/vehicle_repository.dart';
export 'src/sync/local_sync_engine.dart';
export 'src/sync/outbox.dart';
export 'src/sync/rental_number_allocator.dart';
export 'src/util/display.dart';
