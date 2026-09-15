import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:test/test.dart';

import 'package:burhan_rent_a_car_data/src/db/ffi_database.dart';
import 'package:burhan_rent_a_car_data/src/import/import_pipeline.dart';
import 'package:burhan_rent_a_car_data/src/import/test_csv_mapper.dart';
import 'package:burhan_rent_a_car_data/src/search/universal_search.dart';
import 'package:burhan_rent_a_car_data/src/sync/local_sync_engine.dart';
import 'package:burhan_rent_a_car_data/src/util/display.dart';

const _testCsvPath = 'test_data/burhan_rent_a_car_temporary_test.csv';

void main() {
  late Directory tempDir;
  late Database db;
  final search = UniversalSearchService();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('burhan_search_test_');
    db = await openAppDatabaseFfi(p.join(tempDir.path, 'search.db'));
    await ImportPipeline(mapper: TestCsvMapper()).importFile(db, _testCsvPath);
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  group('universal search: one box, no category selector', () {
    test('exact rental number returns that rental, ranked first', () async {
      final results = await search.search(db, '23');
      expect(results.first.type, SearchResultType.rental);
      expect(results.first.title, 'Rental #23');
      expect(results.first.isExactMatch, isTrue);
    });

    test('partial name matches mid-name', () async {
      final results = await search.search(db, 'Billa');
      expect(results, hasLength(1));
      expect(results.single.type, SearchResultType.customer);
      expect(results.single.title, 'Billa Khan');
    });

    test('exact phone returns the customer as an exact match', () async {
      final results = await search.search(db, '03001234567');
      final exact = results.where((r) => r.isExactMatch).toList();
      expect(exact, hasLength(1));
      expect(exact.single.type, SearchResultType.customer);
      expect(exact.single.title, 'Billa Khan');
    });

    test('exact CNIC returns the customer', () async {
      final results = await search.search(db, '42201-1234567-1');
      expect(results.first.type, SearchResultType.customer);
      expect(results.first.title, 'Billa Khan');
      expect(results.first.isExactMatch, isTrue);
    });

    test('vehicle registration matches regardless of separators', () async {
      for (final query in ['KHI-123', 'khi123', 'KHI 123']) {
        final results = await search.search(db, query);
        expect(
          results.first.type,
          SearchResultType.vehicle,
          reason: 'query "$query" should find the vehicle',
        );
        expect(results.first.title, 'KHI-123');
        expect(results.first.isExactMatch, isTrue);
      }
    });

    test('partial registration still finds the vehicle', () async {
      final results = await search.search(db, '654');
      final vehicles =
          results.where((r) => r.type == SearchResultType.vehicle).toList();
      expect(vehicles, hasLength(1));
      expect(vehicles.single.title, 'KHI-654');
    });

    test('exact matches sort above partial ones', () async {
      final results = await search.search(db, '1');
      // Rental #1 exists, so it must lead despite many partial phone hits.
      expect(results.first.isExactMatch, isTrue);
      expect(results.first.title, 'Rental #1');
      expect(results.length, greaterThan(1));
    });

    test('a placeholder rental is findable and labelled', () async {
      final results = await search.search(db, '4');
      final rental =
          results.firstWhere((r) => r.type == SearchResultType.rental);
      expect(rental.title, 'Rental #4');
      expect(rental.subtitle, noPreviousRecordAvailable);
    });

    test('soleExactMatch drives submit-to-open only when unambiguous', () async {
      final unambiguous = await search.search(db, 'KHI-789');
      expect(search.soleExactMatch(unambiguous), isNotNull);

      final partialOnly = await search.search(db, 'Ahmed');
      expect(search.soleExactMatch(partialOnly), isNull);
    });

    test('empty query returns nothing', () async {
      expect(await search.search(db, '   '), isEmpty);
    });

    test('a pending offline rental is excluded from number search but kept',
        () async {
      final engine = LocalSyncEngine();
      final id = await engine.createPendingRental(db, status: 'Open');
      // It has no number yet, so no number search can match it...
      final results = await search.search(db, '61');
      expect(results.where((r) => r.id == id), isEmpty);
      // ...but it exists and displays as Pending.
      final row = await engine.rentals.getById(db, id);
      expect(rentalDisplayNumber(row!), startsWith('Pending #'));
    });
  });
}
