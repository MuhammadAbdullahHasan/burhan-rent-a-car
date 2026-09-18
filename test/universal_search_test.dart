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

    test('soleExactMatch drives submit-to-open only when unambiguous',
        () async {
      final unambiguous = await search.search(db, 'KHI-789');
      expect(search.soleExactMatch(unambiguous), isNotNull);

      final partialOnly = await search.search(db, 'Ahmed');
      expect(search.soleExactMatch(partialOnly), isNull);
    });

    test('empty query returns nothing', () async {
      expect(await search.search(db, '   '), isEmpty);
    });
  });

  group('scoped search: one category per field', () {
    test('rental-number field matches the exact number only', () async {
      final results = await search.searchScoped(db, '23', SearchScope.rentalNo);
      expect(results, hasLength(1));
      expect(results.single.title, 'Rental #23');
      // Digits that only occur inside phone numbers find nothing here.
      final none = await search.searchScoped(db, '1234', SearchScope.rentalNo);
      expect(none, isEmpty);
    });

    test(
        'reference field finds every rental the reference vouched for, '
        'by name or by number', () async {
      final byName =
          await search.searchScoped(db, 'ali r', SearchScope.reference);
      expect(byName, hasLength(14));
      expect(byName.every((r) => r.type == SearchResultType.rental), isTrue);
      expect(byName.every((r) => r.matchedOn == 'Reference'), isTrue);
      expect(byName.first.subtitle, startsWith('Ref: Ali R.'));
      // Newest first, so the owner sees the latest agreement at the top.
      expect(byName.first.title, 'Rental #58');

      final byNumber =
          await search.searchScoped(db, '0300-999 0001', SearchScope.reference);
      expect(
          byNumber.map((r) => r.id).toSet(), byName.map((r) => r.id).toSet());

      // A short digit run isn't enough to match a contact; only names.
      final none = await search.searchScoped(db, '99', SearchScope.reference);
      expect(none, isEmpty);
    });

    test('the All box also finds rentals by their reference', () async {
      final results = await search.search(db, 'Noman S');
      expect(results.where((r) => r.matchedOn == 'Reference'), isNotEmpty);
    });

    test('name field never returns rentals or vehicles', () async {
      final results =
          await search.searchScoped(db, 'Khan', SearchScope.customerName);
      expect(results, isNotEmpty);
      expect(results.every((r) => r.type == SearchResultType.customer), isTrue);
      expect(results.map((r) => r.title), contains('Billa Khan'));
    });

    test('mobile field: exact match ranks first, partial digits still match',
        () async {
      final exact =
          await search.searchScoped(db, '03001234567', SearchScope.phone);
      expect(exact.first.isExactMatch, isTrue);
      expect(exact.first.title, 'Billa Khan');

      final partial =
          await search.searchScoped(db, '1234567', SearchScope.phone);
      expect(partial.length, greaterThan(1));
      expect(partial.every((r) => r.type == SearchResultType.customer), isTrue);
      // A digit string is not treated as a rental number in this field.
      expect(partial.where((r) => r.type == SearchResultType.rental), isEmpty);
    });

    test('CNIC field matches with or without dashes', () async {
      for (final q in ['42201-1234567-1', '4220112345671']) {
        final results = await search.searchScoped(db, q, SearchScope.cnic);
        expect(results.first.title, 'Billa Khan', reason: q);
        expect(results.first.isExactMatch, isTrue);
      }
    });

    test('vehicle field ignores separators and case', () async {
      final results =
          await search.searchScoped(db, 'khi 123', SearchScope.vehicle);
      expect(results.first.title, 'KHI-123');
      expect(results.first.isExactMatch, isTrue);
      expect(results.every((r) => r.type == SearchResultType.vehicle), isTrue);
    });

    test('empty query returns nothing in every scope', () async {
      for (final scope in SearchScope.values) {
        expect(await search.searchScoped(db, '  ', scope), isEmpty);
      }
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
