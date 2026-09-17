import 'dart:io';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:burhan_rent_a_car_data/src/db/ffi_database.dart';

/// Runs a historical import against a CSV and prints the reconciliation
/// report -- the same report the app's Import screen will show the owner.
///
///   dart run bin/import_report.dart [csvPath] [dbPath]
///
/// Accepts either the flat test CSV (`Rental#,Date,...`) or the client's
/// legacy multi-table database dump (see LegacyDump); the format is detected
/// from the first line. Defaults to the temporary test CSV and a throwaway
/// database.
Future<void> main(List<String> args) async {
  final csvPath = args.isNotEmpty
      ? args[0]
      : 'test_data/burhan_rent_a_car_temporary_test.csv';
  // Absolute: the FFI factory would otherwise tuck a relative path under
  // .dart_tool/sqflite_common_ffi/databases/, and the delete below would
  // miss it.
  final dbPath = File(args.length > 1 ? args[1] : 'build/import_report.db')
      .absolute
      .path;

  final dbFile = File(dbPath);
  await dbFile.parent.create(recursive: true);
  if (dbFile.existsSync()) await dbFile.delete();

  final content = await File(csvPath).readAsString();
  final firstLine = content.split('\n').first;

  final db = await openAppDatabaseFfi(dbPath);
  final ReconciliationReport report;
  if (firstLine.contains('Rental#')) {
    report = await ImportPipeline(mapper: TestCsvMapper())
        .importCsvString(db, content);
  } else {
    final dump = LegacyDump.parse(content);
    stdout.writeln(
      'Legacy dump: ${dump.rentals.length} rentals, '
      '${dump.vehicles.length} vehicles, ${dump.payments.length} payments',
    );
    final rows = dump.cleanRentals();
    report = await ImportPipeline(mapper: LegacyDumpMapper(dump))
        .importRows(db, rows);
    report.warnings.insertAll(0, dump.notes);
  }

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
      (SELECT COUNT(*) FROM rentals WHERE is_placeholder = 1) AS placeholders,
      (SELECT COUNT(*) FROM rentals WHERE status = 'Open') AS open_rentals
  ''');
  stdout.writeln('  stored: ${counts.first}');

  await db.close();
}
