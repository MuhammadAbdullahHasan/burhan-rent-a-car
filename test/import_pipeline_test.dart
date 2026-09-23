import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:test/test.dart';

import 'package:burhan_rent_a_car_data/src/backup/snapshot.dart';
import 'package:burhan_rent_a_car_data/src/db/ffi_database.dart';
import 'package:burhan_rent_a_car_data/src/import/import_pipeline.dart';
import 'package:burhan_rent_a_car_data/src/import/test_csv_mapper.dart';
import 'package:burhan_rent_a_car_data/src/import/reconciliation_report.dart';
import 'package:burhan_rent_a_car_data/src/repositories/customer_repository.dart';
import 'package:burhan_rent_a_car_data/src/repositories/rental_repository.dart';
import 'package:burhan_rent_a_car_data/src/repositories/vehicle_repository.dart';
import 'package:burhan_rent_a_car_data/src/sync/local_sync_engine.dart';
import 'package:burhan_rent_a_car_data/src/util/display.dart';

const _testCsvPath = 'test_data/burhan_rent_a_car_temporary_test.csv';

final _customers = CustomerRepository();
final _vehicles = VehicleRepository();
final _rentals = RentalRepository();

/// Every test gets its own on-disk temp SQLite file (not a shared
/// ':memory:' path, which sqflite would otherwise cache as one instance
/// across tests) so cases are fully isolated from each other.
Future<Database> _freshDb(String tempDir) async {
  final path = p.join(tempDir, 'test_${DateTime.now().microsecondsSinceEpoch}.db');
  return openAppDatabaseFfi(path);
}

Future<ReconciliationReport> _importTestCsv(Database db) {
  final pipeline = ImportPipeline(mapper: TestCsvMapper());
  return pipeline.importFile(db, _testCsvPath);
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('burhan_rent_a_car_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('14 test cases (docs/test_data_analysis.md §6)', () {
    late Database db;
    late ReconciliationReport report;

    setUp(() async {
      db = await _freshDb(tempDir.path);
      report = await _importTestCsv(db);
    });

    tearDown(() async => db.close());

    test('import itself succeeds cleanly', () {
      expect(report.success, isTrue);
      expect(report.errors, isEmpty);
      expect(report.rowsRead, 55);
      expect(report.rentalsInserted, 55);
      expect(report.placeholdersInserted, 5);
    });

    test('1. exact rental search "23" -> only Rental #23', () async {
      final rental = await _rentals.findByRentalNo(db, 23);
      expect(rental, isNotNull);
      final customer = await _customers.getById(db, rental!['customer_id'] as String);
      final vehicle = await _vehicles.getById(db, rental['vehicle_id'] as String);
      expect(customer!['full_name'], 'Billa Khan');
      expect(vehicle!['registration_norm'], 'KHI654');
      expect(rental['status'], 'Open');
    });

    test('2. customer history search "Billa" -> 9 rentals', () async {
      final matches = await _customers.searchByName(db, 'Billa');
      expect(matches, hasLength(1));
      final rentalsForCustomer = await _rentals.findByCustomerId(
        db,
        matches.first['id'] as String,
      );
      expect(rentalsForCustomer, hasLength(9));
      final nos = rentalsForCustomer.map((r) => r['rental_no']).toSet();
      expect(nos, {1, 12, 13, 23, 27, 34, 43, 45, 56});
    });

    test('3. vehicle history search "KHI-123" -> 22 rentals', () async {
      final vehicle = await _vehicles.findByRegistrationNorm(db, 'KHI123');
      expect(vehicle, isNotNull);
      final rentalsForVehicle = await _rentals.findByVehicleId(
        db,
        vehicle!['id'] as String,
      );
      expect(rentalsForVehicle, hasLength(22));
    });

    test('4. repeated customer collapses to one customer row', () async {
      final rows = await db.query(
        'customers',
        where: 'phone_normalized = ?',
        whereArgs: ['03001234567'],
      );
      expect(rows, hasLength(1));
    });

    test('5. repeated vehicle collapses to one vehicle row', () async {
      final rows = await db.query(
        'vehicles',
        where: 'registration_norm = ?',
        whereArgs: ['KHI123'],
      );
      expect(rows, hasLength(1));
    });

    test('6. missing historical numbers show as placeholders', () async {
      for (final gap in [4, 11, 25, 40, 55]) {
        final rental = await _rentals.findByRentalNo(db, gap);
        expect(rental, isNotNull, reason: 'rental #$gap must still exist as a row');
        expect(rental!['is_placeholder'], 1);
        expect(rental['customer_id'], isNull);
        expect(rental['vehicle_id'], isNull);
      }
    });

    test('7. blank field displays as N/A', () async {
      final rental24 = await _rentals.findByRentalNo(db, 24);
      expect(displayOrNA(rental24!['remarks']), 'N/A');

      // Rental #18's source row had a blank CNIC, but Fahad Khan is the
      // same customer as other rows where it was present -- the merged
      // customer profile is still complete.
      final rental18 = await _rentals.findByRentalNo(db, 18);
      final customer = await _customers.getById(db, rental18!['customer_id'] as String);
      expect(customer!['full_name'], 'Fahad Khan');
      expect(customer['cnic'], isNotNull);
    });

    test('8. create new rental offline shows Pending', () async {
      final engine = LocalSyncEngine();
      final id = await engine.createPendingRental(db, status: 'Open');
      final rental = await _rentals.getById(db, id);
      expect(rental!['rental_no'], isNull);

      final pending = await db.query(
        'sync_queue',
        where: "entity_type = 'rental' AND entity_id = ? AND status = 'pending'",
        whereArgs: [id],
      );
      expect(pending, hasLength(1));
    });

    test('9. sync assigns the next real number (61)', () async {
      final engine = LocalSyncEngine();
      final id = await engine.createPendingRental(db, status: 'Open');
      await engine.syncPending(db);
      final rental = await _rentals.getById(db, id);
      expect(rental!['rental_no'], 61);
    });

    test('10. edit offline then sync: no duplicate row, version bumped', () async {
      final engine = LocalSyncEngine();
      final before = await _rentals.findByRentalNo(db, 58);
      await engine.queueUpdate(db, before!['id'] as String, {'balance': 999.0});
      await engine.syncPending(db);

      final matches = await db.query('rentals', where: 'rental_no = ?', whereArgs: [58]);
      expect(matches, hasLength(1));
      expect(matches.first['balance'], 999.0);
      expect(matches.first['version'], (before['version'] as int) + 1);
    });

    test('11. soft-delete then sync: number retired, never reused', () async {
      final engine = LocalSyncEngine();
      final rental10 = await _rentals.findByRentalNo(db, 10);
      await engine.queueSoftDelete(db, rental10!['id'] as String);
      await engine.syncPending(db);

      final deleted = await _rentals.findByRentalNo(db, 10);
      expect(deleted!['is_deleted'], 1);
      expect(deleted['rental_no'], 10); // number itself never changes

      final newId = await engine.createPendingRental(db, status: 'Open');
      await engine.syncPending(db);
      final newRental = await _rentals.getById(db, newId);
      expect(newRental!['rental_no'], 61); // continues from max real, not 10
    });

    test('vehicle soft-delete: hidden from listings and search, its '
        'history untouched, and re-typing the plate makes a new vehicle',
        () async {
      final engine = LocalSyncEngine();
      final before = await _vehicles.findByRegistrationNorm(db, 'KHI123');
      final vehicleId = before!['id'] as String;
      final rentalsBefore =
          await _rentals.findByVehicleId(db, vehicleId);
      expect(rentalsBefore, isNotEmpty);

      await engine.queueSoftDeleteVehicle(db, vehicleId);
      await engine.syncPending(db);

      final deleted = await _vehicles.getById(db, vehicleId);
      expect(deleted!['is_deleted'], 1);
      // Findable directly and by its rentals, but not by a fresh lookup.
      expect(await _vehicles.findByRegistrationNorm(db, 'KHI123'), isNull);
      final stats = await _vehicles.listWithStats(db);
      expect(stats.where((v) => v['id'] == vehicleId), isEmpty);
      final rentalsAfter = await _rentals.findByVehicleId(db, vehicleId);
      expect(rentalsAfter, hasLength(rentalsBefore.length));

      // The same registration typed again is a new vehicle, not a revival.
      final newId = await _vehicles.insert(
        db,
        registrationNo: 'KHI-123',
        registrationNorm: 'KHI123',
      );
      expect(newId, isNot(vehicleId));
    });

    test('12. backup export produces expected counts', () async {
      final snapshot = await exportSnapshot(db);
      expect(snapshot.customers, hasLength(10));
      expect(snapshot.vehicles, hasLength(3));
      expect(snapshot.rentals, hasLength(60)); // 55 real + 5 placeholders
    });

    test('13. restore is idempotent (no duplicates)', () async {
      final snapshot = await exportSnapshot(db);

      final restoreDb = await _freshDb(tempDir.path);
      await restoreSnapshot(restoreDb, snapshot);
      var counts = await Future.wait([
        restoreDb.query('customers'),
        restoreDb.query('vehicles'),
        restoreDb.query('rentals'),
      ]);
      expect(counts[0], hasLength(10));
      expect(counts[1], hasLength(3));
      expect(counts[2], hasLength(60));

      // Restore the same snapshot a second time onto already-populated data.
      await restoreSnapshot(restoreDb, snapshot);
      counts = await Future.wait([
        restoreDb.query('customers'),
        restoreDb.query('vehicles'),
        restoreDb.query('rentals'),
      ]);
      expect(counts[0], hasLength(10));
      expect(counts[1], hasLength(3));
      expect(counts[2], hasLength(60));

      await restoreDb.close();
    });

    test('14. app restart while unsynced: outbox survives', () async {
      final path = p.join(tempDir.path, 'restart_test.db');
      final restartDb = await openAppDatabaseFfi(path);
      await _importTestCsv(restartDb);

      final engine = LocalSyncEngine();
      final id = await engine.createPendingRental(restartDb, status: 'Open');
      await restartDb.close(); // simulate app kill before sync ran

      final reopened = await openAppDatabaseFfi(path);
      final pending = await reopened.query(
        'sync_queue',
        where: "entity_type = 'rental' AND entity_id = ? AND status = 'pending'",
        whereArgs: [id],
      );
      expect(pending, hasLength(1));
      final rental = await _rentals.getById(reopened, id);
      expect(rental!['rental_no'], isNull);

      await engine.syncPending(reopened);
      final synced = await _rentals.getById(reopened, id);
      expect(synced!['rental_no'], 61);
      await reopened.close();
    });
  });

  group('validation: duplicate / malformed / invalid data', () {
    late Database db;

    setUp(() async {
      db = await _freshDb(tempDir.path);
    });

    tearDown(() async => db.close());

    test('duplicate Rental# in source aborts the whole import', () async {
      const csvContent = 'Rental#,Name\n5,Test A\n5,Test B\n';
      final pipeline = ImportPipeline(mapper: TestCsvMapper());
      final report = await pipeline.importCsvString(db, csvContent);

      expect(report.success, isFalse);
      expect(report.errors.single, contains('Duplicate Rental# 5'));
      final rows = await db.query('rentals');
      expect(rows, isEmpty, reason: 'a fatal error must leave no partial rows');
    });

    test('non-numeric Rental# aborts the whole import', () async {
      const csvContent = 'Rental#,Name\nabc,Test A\n';
      final pipeline = ImportPipeline(mapper: TestCsvMapper());
      final report = await pipeline.importCsvString(db, csvContent);

      expect(report.success, isFalse);
      expect(report.errors.single, contains('no valid Rental#'));
      final rows = await db.query('rentals');
      expect(rows, isEmpty);
    });

    test('malformed date is a warning, not an abort -- row is still imported', () async {
      const csvContent = 'Rental#,Date,Name\n1,not-a-date,Test Person\n';
      final pipeline = ImportPipeline(mapper: TestCsvMapper());
      final report = await pipeline.importCsvString(db, csvContent);

      expect(report.success, isTrue);
      expect(report.rentalsInserted, 1);
      expect(report.warnings, contains(contains('unparseable Date')));

      final rental = await _rentals.findByRentalNo(db, 1);
      expect(rental!['start_date'], isNull);
    });
  });

  group('repository-level: customer backfill mechanism', () {
    late Database db;

    setUp(() async => db = await _freshDb(tempDir.path));
    tearDown(() async => db.close());

    test('backfill fills a null field without overwriting existing ones', () async {
      final id = await _customers.insert(
        db,
        fullName: 'Backfill Test',
        phone: '03000000000',
        phoneNormalized: '03000000000',
        cnic: null,
        cnicNormalized: null,
      );
      final existing = await _customers.getById(db, id);

      await _customers.backfill(
        db,
        existing!,
        phone: '09999999999', // must NOT overwrite the existing phone
        phoneNormalized: '09999999999',
        cnic: '42201-9999999-9', // SHOULD fill, was null
        cnicNormalized: '4220199999999',
      );

      final updated = await _customers.getById(db, id);
      expect(updated!['phone'], '03000000000');
      expect(updated['cnic'], '42201-9999999-9');
      expect(updated['version'], 2);
    });
  });
}
