import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:burhan_rent_a_car/sync/cloud_sync_engine.dart';
import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase/supabase.dart';

const _csvPath = '../test_data/burhan_rent_a_car_temporary_test.csv';

/// Just enough of PostgREST, in memory, to exercise the engine end to end:
/// upsert (merge / ignore duplicates), "changed since" selects, the
/// rental-number RPC, and the two constraints that matter -- foreign keys
/// from rentals to customers/vehicles, and unique rental numbers.
class FakePostgrest {
  final tables = <String, Map<String, Map<String, Object?>>>{
    'customers': {},
    'vehicles': {},
    'rentals': {},
    'attachments': {},
  };
  final requests = <String>[];
  bool failAttachments = false;
  int floor = 60;

  http.Client client() => MockClient((request) async {
        final response = await _handle(request);
        // postgrest reads response.request, which a bare Response lacks.
        return http.Response(
          response.body,
          response.statusCode,
          headers: response.headers,
          request: request,
        );
      });

  http.Response _json(Object? body, {int status = 200}) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  http.Response _error(String code, String message) => _json(
        {'code': code, 'message': message, 'details': null, 'hint': null},
        status: 409,
      );

  Future<http.Response> _handle(http.Request request) async {
    final segments = request.url.pathSegments; // rest, v1, <table>|rpc, ...
    requests.add('${request.method} ${request.url.path}');
    if (segments[2] == 'rpc') {
      final max = tables['rentals']!
          .values
          .map((r) => (r['rental_no'] as num?)?.toInt() ?? 0)
          .fold(0, (a, b) => a > b ? a : b);
      floor = (max > floor ? max : floor) + 1;
      return _json(floor);
    }
    final table = tables[segments[2]]!;
    if (request.method == 'GET') {
      final since = request.url.queryParameters['updated_at']!;
      expect(since, startsWith('gt.'));
      final cutoff = since.substring(3);
      final rows = table.values
          .where((r) => (r['updated_at'] as String).compareTo(cutoff) > 0)
          .toList();
      return _json(rows);
    }
    if (request.method == 'POST') {
      if (segments[2] == 'attachments' && failAttachments) {
        return _json({'code': '500', 'message': 'boom'}, status: 500);
      }
      final ignore =
          (request.headers['Prefer'] ?? '').contains('ignore-duplicates');
      final decoded = jsonDecode(request.body);
      final rows = decoded is List
          ? decoded.cast<Map<String, dynamic>>()
          : [decoded as Map<String, dynamic>];
      for (final row in rows) {
        final id = row['id'] as String;
        if (ignore && table.containsKey(id)) continue;
        if (segments[2] == 'rentals') {
          final c = row['customer_id'];
          if (c != null && !tables['customers']!.containsKey(c)) {
            return _error(
              '23503',
              'insert or update on table "rentals" violates foreign key '
                  'constraint "rentals_customer_id_fkey"',
            );
          }
          final v = row['vehicle_id'];
          if (v != null && !tables['vehicles']!.containsKey(v)) {
            return _error(
              '23503',
              'insert or update on table "rentals" violates foreign key '
                  'constraint "rentals_vehicle_id_fkey"',
            );
          }
          final no = row['rental_no'];
          final clash = table.values.any(
            (r) => r['id'] != id && no != null && r['rental_no'] == no,
          );
          if (clash) {
            return _error(
                '23505',
                'duplicate key value violates unique '
                    'constraint "rentals_rental_no_key"');
          }
        }
        table[id] = Map<String, Object?>.from(row);
      }
      return http.Response('', 201);
    }
    return http.Response('unsupported', 405);
  }

  /// Loads the same dataset the real loader script pushes, from a freshly
  /// imported SQLite file -- so the server's ids differ from any device's.
  Future<void> loadDataset(Database imported) async {
    for (final r in await imported.query('customers')) {
      tables['customers']![r['id'] as String] = {
        ...r,
        'possible_duplicate': r['possible_duplicate'] == 1,
        'is_deleted': r['is_deleted'] == 1,
      };
    }
    for (final r in await imported.query('vehicles')) {
      tables['vehicles']![r['id'] as String] = {
        ...r,
        'is_deleted': r['is_deleted'] == 1,
      };
    }
    for (final r in await imported.query('rentals')) {
      tables['rentals']![r['id'] as String] = {
        ...r,
        'is_placeholder': r['is_placeholder'] == 1,
        'is_deleted': r['is_deleted'] == 1,
      };
    }
  }
}

Future<Database> _openSeeded(Directory dir, String name) async {
  final db = await openAppDatabase(databaseFactoryFfi, p.join(dir.path, name));
  final csv = await File(_csvPath).readAsString();
  await ImportPipeline(mapper: TestCsvMapper()).importCsvString(db, csv);
  return db;
}

Future<int> _count(Database db, String table, [String? where]) async {
  final rows = await db.rawQuery(
    'SELECT COUNT(*) AS c FROM $table${where == null ? '' : ' WHERE $where'}',
  );
  return rows.first['c'] as int;
}

void main() {
  late Directory dir;
  late FakePostgrest server;
  late Database serverSource;

  setUpAll(() => sqfliteFfiInit());

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cloud_sync_test');
    server = FakePostgrest();
    serverSource = await _openSeeded(dir, 'server.db');
    await server.loadDataset(serverSource);
  });

  tearDown(() async {
    await serverSource.close();
    await dir.delete(recursive: true);
  });

  CloudSyncEngine engineFor(Database db) => CloudSyncEngine(
        client: SupabaseClient(
          'https://fake.supabase.co',
          'fake-key',
          httpClient: server.client(),
        ),
        db: db,
      );

  test('a new device fills itself from the cloud on first sync', () async {
    final db = await openAppDatabase(
      databaseFactoryFfi,
      p.join(dir.path, 'fresh.db'),
    );
    expect(await CloudSyncEngine.isHydrated(db), isFalse);

    final first = await engineFor(db).syncNow();
    expect(first.error, isNull);
    expect(await _count(db, 'rentals'), 60);
    expect(await _count(db, 'rentals', 'is_placeholder = 1'), 5);
    expect(await _count(db, 'customers'), 10);
    expect(await _count(db, 'vehicles'), 3);
    expect(await CloudSyncEngine.isHydrated(db), isTrue);

    final again = await engineFor(db).syncNow();
    expect(again.changedAnything, isFalse);
    expect(again.hasError, isFalse);
    await db.close();
  });

  test(
      'a device with its own seeded copy swaps it for the cloud copy and '
      're-sends what the owner did', () async {
    final db = await _openSeeded(dir, 'phone.db');
    final local = LocalSyncEngine();

    // The owner's work on this device before cloud sync existed:
    final seedCustomer = (await db.query(
      'customers',
      where: 'phone_normalized IS NOT NULL',
      limit: 1,
    ))
        .first;
    final seedVehicle = (await db.query('vehicles', limit: 1)).first;
    final seedRental23 = (await db.query(
      'rentals',
      where: 'rental_no = 23',
    ))
        .first;

    // (a) a rental created here, still Pending, on a seeded customer/vehicle
    final pendingId = await local.createPendingRental(
      db,
      customerId: seedCustomer['id'] as String,
      vehicleId: seedVehicle['id'] as String,
      startDate: '2026-09-01',
      amount: 5000,
      status: 'Open',
    );
    // (b) a rental created here that the old local stand-in already numbered
    final legacyId = await local.createPendingRental(
      db,
      customerId: seedCustomer['id'] as String,
      vehicleId: seedVehicle['id'] as String,
      startDate: '2026-09-02',
      amount: 6000,
      status: 'Open',
    );
    await local.syncPending(db); // assigns #61 locally, marks both done
    // (c) an edit to a seeded rental
    await local.queueUpdate(
      db,
      seedRental23['id'] as String,
      {'status': 'Closed', 'remarks': 'Returned on time'},
    );
    // (d) a brand-new customer plus a rental for them
    final newCustomerId = await local.createCustomer(
      db,
      fullName: 'Brand New',
      phone: '0300-9999999',
      phoneNormalized: '03009999999',
    );
    final newCustomerRentalId = await local.createPendingRental(
      db,
      customerId: newCustomerId,
      vehicleId: seedVehicle['id'] as String,
      startDate: '2026-09-03',
      amount: 7000,
      status: 'Open',
    );

    final summary = await engineFor(db).syncNow();
    expect(summary.failed, 0, reason: summary.error);
    expect(summary.error, isNull);

    // Local now mirrors the cloud dataset plus the owner's three rentals.
    expect(await _count(db, 'rentals'), 63);
    expect(await _count(db, 'customers'), 11);
    expect(await _count(db, 'vehicles'), 3);
    final serverRentalIds = server.tables['rentals']!.keys.toSet();
    for (final r in await db.query('rentals')) {
      expect(serverRentalIds, contains(r['id']));
    }
    final numbers = (await db.query('rentals', columns: ['rental_no']))
        .map((r) => r['rental_no'])
        .toList();
    expect(numbers.toSet().length, numbers.length, reason: 'no duplicates');

    // The created rentals point at the cloud's customer/vehicle rows now.
    final serverCustomerIds = server.tables['customers']!.keys.toSet();
    final serverVehicleIds = server.tables['vehicles']!.keys.toSet();
    for (final id in [pendingId, legacyId, newCustomerRentalId]) {
      final r =
          (await db.query('rentals', where: 'id = ?', whereArgs: [id])).first;
      expect(serverCustomerIds, contains(r['customer_id']));
      expect(serverVehicleIds, contains(r['vehicle_id']));
      expect(r['rental_no'], isNotNull);
      expect(r['rental_no'] as int, greaterThan(60));
    }
    // The cloud's twin of that customer was matched by phone, not duplicated.
    final matched = server.tables['customers']!.values.where(
      (c) => c['phone_normalized'] == seedCustomer['phone_normalized'],
    );
    expect(matched.length, 1);
    expect(server.tables['customers']!.containsKey(newCustomerId), isTrue);

    // The edit to #23 landed on the cloud's #23 (different id, same number).
    final server23 = server.tables['rentals']!.values.singleWhere(
      (r) => r['rental_no'] == 23,
    );
    expect(server23['status'], 'Closed');
    expect(server23['remarks'], 'Returned on time');
    expect(server23['id'], isNot(seedRental23['id']));

    // Numbers 61, 62, 63 were handed out, never reused, never skipped.
    final top = server.tables['rentals']!.values
        .map((r) => r['rental_no'] as int)
        .where((n) => n > 60)
        .toList()
      ..sort();
    expect(top, [61, 62, 63]);
    expect(await _count(db, 'sync_queue', "status = 'pending'"), 0);
    await db.close();
  });

  test('push failures are reported, not hidden', () async {
    final db = await openAppDatabase(
      databaseFactoryFfi,
      p.join(dir.path, 'fresh.db'),
    );
    final engine = engineFor(db);
    await engine.syncNow();

    final rental =
        (await db.query('rentals', where: 'is_placeholder = 0')).first;
    await LocalSyncEngine().setRentalAgreementPhoto(
      db,
      rentalId: rental['id'] as String,
      image: _tinyPng(),
      mimeType: 'image/png',
    );
    server.failAttachments = true;
    final summary = await engine.syncNow();
    expect(summary.failed, 1);
    expect(summary.hasError, isTrue);
    expect(await _count(db, 'sync_queue', "status = 'pending'"), 1);

    server.failAttachments = false;
    final retry = await engine.syncNow();
    expect(retry.failed, 0);
    expect(retry.pushed, 1);
    expect(server.tables['attachments']!.length, 1);
    await db.close();
  });
}

/// 1x1 transparent PNG.
Uint8List _tinyPng() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
