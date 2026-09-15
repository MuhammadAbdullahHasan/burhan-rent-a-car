import 'dart:io';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:burhan_rent_a_car_data/src/db/ffi_database.dart';

/// Runs a historical import against a CSV and prints the reconciliation
/// report -- the same report the app's Import screen will show the owner.
///
///   dart run bin/import_report.dart [csvPath] [dbPath]
///
/// Defaults to the temporary test CSV and a throwaway database.
Future<void> main(List<String> args) async {
  final csvPath = args.isNotEmpty
      ? args[0]
      : 'test_data/burhan_rent_a_car_temporary_test.csv';
  final dbPath = args.length > 1 ? args[1] : 'build/import_report.db';

  final dbFile = File(dbPath);
  await dbFile.parent.create(recursive: true);
  if (dbFile.existsSync()) await dbFile.delete();

  final db = await openAppDatabaseFfi(dbPath);
  final pipeline = ImportPipeline(mapper: TestCsvMapper());
  final report = await pipeline.importFile(db, csvPath);

  stdout.writeln('Source: $csvPath');
  stdout.writeln('Database: $dbPath');
  stdout.writeln(report);

  final allocator = RentalNumberAllocator();
  stdout.writeln('  next new rental number: #${await allocator.peek(db)}');

  final counts = await db.rawQuery('''
    SELECT
      (SELECT COUNT(*) FROM customers) AS customers,
      (SELECT COUNT(*) FROM vehicles) AS vehicles,
      (SELECT COUNT(*) FROM rentals) AS rentals,
      (SELECT COUNT(*) FROM rentals WHERE is_placeholder = 1) AS placeholders
  ''');
  stdout.writeln('  stored: ${counts.first}');

  await db.close();
}
