import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:test/test.dart';

import 'package:burhan_rent_a_car_data/src/db/ffi_database.dart';
import 'package:burhan_rent_a_car_data/src/import/import_pipeline.dart';
import 'package:burhan_rent_a_car_data/src/import/legacy_dump.dart';

/// A cut-down phpMyAdmin dump in the shape of the client's real export:
/// the rentals table with its 75 columns collapsed to the ones that matter,
/// plus a vehicle and a payment.
///
///   #1  gap marker ("N/A" everywhere)          -> placeholder
///   #2  ordinary agreement, car logged back in  -> Closed, customer
///   #3  "Blank" with no contact                 -> placeholder
///   #4  "Cancel"                                -> Closed, no customer
///   #5  "Test Customer Three cancel" with a phone       -> Closed, no customer, name in remarks
///   #6  same client + date as the #2 typo below -> keeps #6
///   #2  typed again for #6's agreement (id 9)   -> dropped with a note naming #6
///   #8  ordinary, still out                     -> Open
///   (#7 never used)                              -> placeholder
const _dump = r'''
-- phpMyAdmin SQL Dump
CREATE TABLE `car_details` (
  `id` bigint(20) UNSIGNED NOT NULL
) ENGINE=InnoDB;

INSERT INTO `car_details` (`id`, `maker`, `registrationno`, `color`, `chassisno`, `engineno`, `horsepower`, `model`, `insuranceduedate`, `registrationyear`) VALUES
(1, 'Toyota Corolla GLI', 'TST-001', 'White', 'CH-000001', 'EN-000001', '1300cc', 'Test Insurance', '2023-03-21', 2017);

INSERT INTO `receipts` (`id`, `date`, `remarks`, `amount`, `rentalid`) VALUES
(10, '2022-01-14', 'All clear (front bumper have to paint)', 65000.00, 2);

INSERT INTO `rentals` (`id`, `rentalno`, `registrationno`, `rentaldate`, `rental_time`, `clientname`, `clientfather_husbandname`, `clientaddress`, `clientcontactno`, `clientnic`, `receive_date`, `receive_time`, `perdayrental`, `issueterms`, `rentaldays`, `totalrental`, `advance`, `created_at`, `updated_at`, `registration_no`, `sparewheel`) VALUES
(1, 1, 'N/A', '2006-06-01', '15:00:00', 'N/A', 'N/A', 'N/A', 'N/A', 'N/A', '', '', 0.00, 'Per Day', 0, 0.00, 0.00, '2006-06-01 04:00:00', '2006-06-01 04:00:00', 'N/A', 0),
(2, 2, 'TST-001', '2022-01-10', '11:00:00', 'Test Customer One', 'N/A', 'House No. 1, O\'Test Road, Testville', '03000000001', '00000-0000000-1', '2022-01-14', '18:30', 3000.00, 'Per Day', 4, 12000.00, 5000.00, '2022-01-10 04:00:00', '2022-01-10 04:00:00', 'TST-001', 1),
(3, 3, 'N/A', '2022-02-01', '15:00:00', 'Blank', 'N/A', 'N/A', 'N/A', 'N/A', '', '', 0.00, 'Per Day', 0, 0.00, 0.00, NULL, NULL, 'N/A', 0),
(4, 4, 'TST-001', '0001-01-01', '00:00:00', 'Cancel', 'Cancel', 'Cancel', 'Cancel', 'Cancel', NULL, NULL, 0.00, 'Per Day', 0, 0.00, 0.00, NULL, NULL, 'TST-001', 0),
(5, 5, 'TST-001', '2022-03-01', '10:00:00', 'Test Customer Three cancel', 'N/A', 'N/A', '03000000003', 'N/A', NULL, NULL, 0.00, 'Per Day', 0, 0.00, 0.00, NULL, NULL, 'TST-001', 0),
(6, 6, 'TST-001', '2022-04-22', '10:00:00', 'Test Customer Two', 'N/A', 'N/A', '03000000002', 'N/A', NULL, NULL, 2000.00, 'Per Day', 4, 8000.00, 0.00, '2022-04-22 08:27:26', '2022-04-22 08:27:26', 'TST-001', 0),
(9, 2, 'TST-001', '2022-04-22', '10:00:00', 'Test Customer Tow', 'N/A', 'N/A', '03000000002', 'N/A', NULL, NULL, 2000.00, 'Per Day', 4, 8000.00, 0.00, '2022-04-22 08:25:05', '2022-04-22 08:25:05', 'TST-001', 0),
(10, 8, 'TST-001', '2099-01-01', '10:00:00', 'Still Out', 'N/A', 'N/A', '03009999999', 'N/A', NULL, NULL, 2000.00, 'Per Week', 1, 14000.00, 0.00, NULL, NULL, 'TST-001', 0);

ALTER TABLE `rentals` ADD PRIMARY KEY (`id`);
''';

Future<Database> _freshDb(String tempDir) async {
  final path =
      p.join(tempDir, 'test_${DateTime.now().microsecondsSinceEpoch}.db');
  return openAppDatabaseFfi(path);
}

void main() {
  late Directory tempDir;
  late Database db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('legacy_dump_test_');
    db = await _freshDb(tempDir.path);
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  group('parsing the SQL dump', () {
    test('splits the statements into the three tables', () {
      final dump = LegacyDump.parse(_dump);
      expect(dump.rentals, hasLength(8));
      expect(dump.vehicles, hasLength(1));
      expect(dump.payments, hasLength(1));
      expect(dump.vehicles.single['maker'], 'Toyota Corolla GLI');
    });

    test('unescapes quotes and reads NULL as text NULL', () {
      final dump = LegacyDump.parse(_dump);
      final r2 = dump.rentals.firstWhere((r) => r['id'] == '2');
      expect(r2['clientaddress'], "House No. 1, O'Test Road, Testville");
      final r3 = dump.rentals.firstWhere((r) => r['id'] == '3');
      expect(r3['created_at'], 'NULL');
      expect(legacyNullable(r3['created_at']), isNull);
    });

    test('the CSV form of the same export parses the same way', () {
      const csv = 'id,rentalno,registrationno,rentaldate,clientname,'
          'clientcontactno,clientnic\n'
          '1,1,N/A,2006-06-01,N/A,N/A,N/A\n'
          '2,2,TST-001,2022-01-10,Test Customer One,03000000001,00000-0000000-1\n'
          'id,maker,registrationno\n'
          '1,Toyota Corolla,TST-001\n';
      final dump = LegacyDump.parse(csv);
      expect(dump.rentals, hasLength(2));
      expect(dump.vehicles, hasLength(1));
    });
  });

  group('cleaning and importing', () {
    late LegacyDump dump;
    late List<Map<String, String>> cleaned;

    setUp(() async {
      dump = LegacyDump.parse(_dump);
      cleaned = dump.cleanRentals();
      final report = await ImportPipeline(
        mapper: LegacyDumpMapper(dump, today: DateTime(2026, 9, 17)),
      ).importRows(db, cleaned);
      expect(report.success, isTrue, reason: report.errors.join("; "));
    });

    Future<Map<String, Object?>> rental(int no) async {
      final rows = await db.query('rentals',
          where: 'rental_no = ?', whereArgs: [no]);
      expect(rows, hasLength(1), reason: 'rental #$no');
      return rows.single;
    }

    test('gap markers, "Blank" rows and unused numbers are placeholders',
        () async {
      for (final no in [1, 3, 7]) {
        expect((await rental(no))['is_placeholder'], 1, reason: '#$no');
      }
      expect((await rental(2))['is_placeholder'], 0);
    });

    test('nothing named Blank or Cancel becomes a customer', () async {
      final names = (await db.query('customers'))
          .map((c) => (c['full_name'] as String).toLowerCase())
          .toList();
      expect(names, isNot(contains('blank')));
      expect(names.where((n) => n.contains('cancel')), isEmpty);
      expect(names, containsAll(['test customer one', 'test customer two']));
    });

    test('a cancelled agreement keeps its number, closed, with no customer',
        () async {
      final r4 = await rental(4);
      expect(r4['is_placeholder'], 0);
      expect(r4['customer_id'], isNull);
      expect(r4['status'], 'Closed');
      expect(r4['remarks'], contains('Cancelled'));

      final r5 = await rental(5);
      expect(r5['customer_id'], isNull);
      expect(r5['status'], 'Closed');
      expect(r5['remarks'], contains('Cancelled (Test Customer Three)'));
      expect(r5['remarks'], contains('Contact: 03000000003'));
    });

    test('a car logged back in is Closed; one still out is Open', () async {
      final r2 = await rental(2);
      expect(r2['status'], 'Closed');
      expect(r2['end_date'], '2022-01-14');
      expect(r2['start_time'], '11:00 AM');
      expect(r2['end_time'], '06:30 PM');
      expect(r2['amount'], 12000.0);
      expect(r2['balance'], 7000.0);
      expect(r2['remarks'], contains('Advance: 5000'));
      expect(r2['remarks'], contains('Checklist: spare wheel'));
      expect(r2['remarks'], contains('Payment 2022-01-14: 65000 -- All clear'));

      final r8 = await rental(8);
      expect(r8['status'], 'Open');
      expect(r8['book_days'], 7); // 1 x Per Week
    });

    test('vehicle details come from the car_details table', () async {
      final v = (await db.query('vehicles')).single;
      expect(v['registration_no'], 'TST-001');
      expect(v['chassis_no'], 'CH-000001');
      expect(v['company'], 'Toyota');
      expect(v['model_name'], 'Corolla GLI');
      expect(v['reg_year'], 2017);
    });

    test('a number typed twice for different agreements keeps the original '
        'and names the corrected re-entry', () async {
      expect(cleaned.where((r) => r['rentalno'] == '2'), hasLength(1));
      expect(cleaned.firstWhere((r) => r['rentalno'] == '2')['id'], '2');
      final note = dump.notes.singleWhere((n) => n.startsWith('Rental #2 was'));
      expect(note, contains('Test Customer Tow'));
      expect(note, contains('already on record as Rental #6'));
    });
  });
}
