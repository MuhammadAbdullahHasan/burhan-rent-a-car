import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:burhan_rent_a_car/app_services.dart';
import 'package:burhan_rent_a_car/backup/backup_codec.dart';
import 'package:burhan_rent_a_car/backup/cloud_backup.dart';
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

  /// Server clock for `synced_at`: strictly increasing, like the trigger.
  int _tick = 0;
  String _stamp() {
    _tick++;
    return DateTime.utc(2026, 9, 16, 12, 0, 0)
        .add(Duration(milliseconds: _tick))
        .toIso8601String();
  }

  /// The owner's dataset generation; null until a device creates it.
  String? generation;

  Future<http.Response> _handle(http.Request request) async {
    final segments = request.url.pathSegments; // rest, v1, <table>|rpc, ...
    final q = request.url.queryParameters;
    requests.add('${request.method} ${request.url.path}');
    if (segments[2] == 'dataset_generation') {
      if (request.method == 'POST') {
        generation ??= 'gen-${_stamp()}';
        return _json({'generation': generation}); // insert(...).single()
      }
      return _json([
        if (generation != null) {'generation': generation},
      ]);
    }
    if (segments[2] == 'rpc') {
      final max = tables['rentals']!
          .values
          .map((r) => (r['rental_no'] as num?)?.toInt() ?? 0)
          .fold(0, (a, b) => a > b ? a : b);
      floor = (max > floor ? max : floor) + 1;
      return _json(floor);
    }
    final name = segments[2];
    final table = tables[name]!;

    if (request.method == 'GET') {
      var rows = table.values.toList();
      final byId = q['id'];
      if (byId != null) {
        expect(byId, startsWith('eq.'));
        rows = rows.where((r) => r['id'] == byId.substring(3)).toList();
      }
      final since = q['synced_at'];
      if (since != null) {
        expect(since, startsWith('gt.'));
        final cutoff = DateTime.parse(since.substring(3));
        rows = rows
            .where(
                (r) => DateTime.parse(r['synced_at'] as String).isAfter(cutoff))
            .toList();
      }
      if (q['order'] != null) {
        expect(q['order'], startsWith('synced_at.asc'));
        rows.sort((a, b) {
          final c =
              (a['synced_at'] as String).compareTo(b['synced_at'] as String);
          return c != 0 ? c : (a['id'] as String).compareTo(b['id'] as String);
        });
      }
      final offset = int.tryParse(q['offset'] ?? '') ?? 0;
      final limit = int.tryParse(q['limit'] ?? '') ?? rows.length;
      rows = rows.skip(offset).take(limit).toList();
      return _json(rows);
    }

    if (request.method == 'PATCH') {
      // Conditional update: id=eq.X&version=lt.N
      final id = q['id']!.substring(3);
      final versionFilter = q['version'];
      final row = table[id];
      final matches = row != null &&
          (versionFilter == null ||
              (row['version'] as num) < int.parse(versionFilter.substring(3)));
      if (!matches) return _json(const []);
      final patch = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final error = _constraintError(name, {...row, ...patch});
      if (error != null) return error;
      table[id] = {...row, ...patch, 'synced_at': _stamp()};
      return _json([
        {'id': id}
      ]);
    }

    if (request.method == 'POST') {
      if (name == 'attachments' && failAttachments) {
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
        final error = _constraintError(name, row);
        if (error != null) return error;
        table[id] = {...Map<String, Object?>.from(row), 'synced_at': _stamp()};
      }
      return http.Response('', 201);
    }
    return http.Response('unsupported', 405);
  }

  http.Response? _constraintError(String name, Map<String, dynamic> row) {
    if (name != 'rentals') return null;
    final id = row['id'] as String;
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
    final clash = tables['rentals']!.values.any(
          (r) => r['id'] != id && no != null && r['rental_no'] == no,
        );
    if (clash) {
      return _error(
        '23505',
        'duplicate key value violates unique constraint "rentals_rental_no_key"',
      );
    }
    return null;
  }

  /// Loads the same dataset the real loader script pushes, from a freshly
  /// imported SQLite file -- so the server's ids differ from any device's.
  Future<void> loadDataset(Database imported) async {
    for (final r in await imported.query('customers')) {
      tables['customers']![r['id'] as String] = {
        ...r,
        'possible_duplicate': r['possible_duplicate'] == 1,
        'is_deleted': r['is_deleted'] == 1,
        'synced_at': _stamp(),
      };
    }
    for (final r in await imported.query('vehicles')) {
      tables['vehicles']![r['id'] as String] = {
        ...r,
        'is_deleted': r['is_deleted'] == 1,
        'synced_at': _stamp(),
      };
    }
    for (final r in await imported.query('rentals')) {
      tables['rentals']![r['id'] as String] = {
        ...r,
        'is_placeholder': r['is_placeholder'] == 1,
        'is_deleted': r['is_deleted'] == 1,
        'synced_at': _stamp(),
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

  test('a replaced cloud dataset is taken over in full, stale rows and all',
      () async {
    final db = await openAppDatabase(
      databaseFactoryFfi,
      p.join(dir.path, 'phone.db'),
    );
    expect((await engineFor(db).syncNow()).error, isNull);
    expect(await _count(db, 'rentals'), 60);

    // Work done here after that sync, still in the outbox.
    await LocalSyncEngine().createPendingRental(
      db,
      startDate: '2026-09-20',
      status: 'Open',
    );
    expect(await _count(db, 'sync_queue', "status = 'pending'"), 1);

    // The owner reloads the whole dataset: a new generation, one rental.
    final keep = server.tables['rentals']!.values.first;
    server.tables['rentals']!
      ..clear()
      ..[keep['id'] as String] = keep;
    server.generation = 'gen-reloaded';

    final after = await engineFor(db).syncNow();
    expect(after.error, isNull);
    expect(await _count(db, 'rentals'), 1);
    expect(await _count(db, 'sync_queue', "status = 'pending'"), 0);
    expect(server.tables['rentals']!.length, 1,
        reason: 'nothing from the old copy may reach the new dataset');

    // Same generation again: an ordinary incremental sync.
    final again = await engineFor(db).syncNow();
    expect(again.changedAnything, isFalse);
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

    // (f) meanwhile another device already took #61 on the server -- the
    //     number this device's legacy rental holds locally.
    final taken = Map<String, Object?>.from(
      server.tables['rentals']!.values.firstWhere((r) => r['rental_no'] == 60),
    )
      ..['id'] = 'taken-61'
      ..['rental_no'] = 61
      ..['updated_at'] = '2026-09-16T00:00:00.000Z'
      ..['synced_at'] = server._stamp();
    server.tables['rentals']!['taken-61'] = taken;

    final summary = await engineFor(db).syncNow();
    expect(summary.failed, 0, reason: summary.error);
    expect(summary.error, isNull);

    // Local now mirrors the cloud dataset (60 + the taken #61) plus the
    // owner's three rentals.
    expect(await _count(db, 'rentals'), 64);
    expect(await _count(db, 'customers'), 11);
    expect(await _count(db, 'vehicles'), 3);
    expect(server.tables['vehicles']!.length, 3);
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

    // #61 stayed with the device that had it stored first; this device's
    // legacy #61 was re-numbered by the server. Nothing reused or skipped.
    final top = server.tables['rentals']!.values
        .map((r) => r['rental_no'] as int)
        .where((n) => n > 60)
        .toList()
      ..sort();
    expect(top, [61, 62, 63, 64]);
    expect(server.tables['rentals']!['taken-61']!['rental_no'], 61);
    final legacy =
        (await db.query('rentals', where: 'id = ?', whereArgs: [legacyId]))
            .first;
    expect(legacy['rental_no'], isNot(61));
    expect(await _count(db, 'sync_queue', "status = 'pending'"), 0);
    await db.close();
  });

  test('a dataset far larger than one page arrives complete', () async {
    // 1,300 extra rentals on the server (PostgREST would cap an unpaged
    // read at 1,000).
    final vehicle = server.tables['vehicles']!.keys.first;
    final customer = server.tables['customers']!.keys.first;
    for (var n = 100; n < 1400; n++) {
      server.tables['rentals']!['big-$n'] = {
        'id': 'big-$n',
        'rental_no': n,
        'is_placeholder': false,
        'customer_id': customer,
        'vehicle_id': vehicle,
        'start_date': '2026-01-01',
        'start_time': null,
        'end_date': null,
        'end_time': null,
        'book_days': 1,
        'amount': 1000,
        'balance': 0,
        'status': 'Closed',
        'remarks': null,
        'ref_name': null,
        'ref_contact': null,
        'ref_relation': null,
        'is_deleted': false,
        'version': 1,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
        'synced_at': server._stamp(),
      };
    }
    final db = await openAppDatabase(
      databaseFactoryFfi,
      p.join(dir.path, 'fresh.db'),
    );
    final summary = await engineFor(db).syncNow();
    expect(summary.error, isNull);
    expect(await _count(db, 'rentals'), 60 + 1300);
    expect(
      server.requests.where((r) => r.contains('GET /rest/v1/rentals')).length,
      greaterThan(1),
      reason: 'paged',
    );
    await db.close();
  });

  test('an edit that lost to a newer edit elsewhere is kept, not lost',
      () async {
    final dbA =
        await openAppDatabase(databaseFactoryFfi, p.join(dir.path, 'a.db'));
    final dbB =
        await openAppDatabase(databaseFactoryFfi, p.join(dir.path, 'b.db'));
    final a = engineFor(dbA);
    final b = engineFor(dbB);
    await a.syncNow();
    await b.syncNow();
    final id = (await dbA.query('rentals', where: 'rental_no = 23')).first['id']
        as String;

    // Both devices edit #23 from the same starting point.
    await LocalSyncEngine()
        .queueUpdate(dbA, id, {'status': 'Closed', 'remarks': 'A'});
    await LocalSyncEngine()
        .queueUpdate(dbB, id, {'status': 'Open', 'remarks': 'B'});

    final first = await a.syncNow();
    expect(first.conflicts, 0);
    expect(server.tables['rentals']![id]!['remarks'], 'A');

    final second = await b.syncNow();
    expect(second.conflicts, 1);
    expect(second.failed, 0);
    // Server kept A's edit; B now shows it too, and B's own values are
    // recorded for review.
    expect(server.tables['rentals']![id]!['remarks'], 'A');
    final local =
        (await dbB.query('rentals', where: 'id = ?', whereArgs: [id])).first;
    expect(local['remarks'], 'A');
    final conflicts = await dbB.query('sync_conflicts', where: 'resolved = 0');
    expect(conflicts, hasLength(1));
    expect(conflicts.single['entity_id'], id);
    expect(jsonDecode(conflicts.single['local_row'] as String)['remarks'], 'B');

    // A later, informed edit on B (made on top of A's version) goes through.
    await LocalSyncEngine().queueUpdate(dbB, id, {'remarks': 'B again'});
    final third = await b.syncNow();
    expect(third.conflicts, 0);
    expect(server.tables['rentals']![id]!['remarks'], 'B again');
    await dbA.close();
    await dbB.close();
  });

  test('many new records go up in a few requests, in dependency order',
      () async {
    final db =
        await openAppDatabase(databaseFactoryFfi, p.join(dir.path, 'c.db'));
    final engine = engineFor(db);
    await engine.syncNow();
    final vehicle =
        (await db.query('vehicles', limit: 1)).first['id'] as String;
    final local = LocalSyncEngine();
    for (var n = 0; n < 30; n++) {
      final customer =
          await local.createCustomer(db, fullName: 'C$n', phone: '0300$n');
      await local.createPendingRental(db,
          customerId: customer, vehicleId: vehicle, amount: 100);
    }
    server.requests.clear();
    final summary = await engine.syncNow();
    expect(summary.failed, 0, reason: summary.error);
    expect(summary.pushed, 60);
    // Alternating customer/rental items can't batch across types, but each
    // rental needs a number, so: 30 RPCs + at most a request per item.
    // 1 customers batch + 30 number allocations + 1 rentals batch (+ the
    // parent-check retry path, unused here).
    final posts = server.requests.where((r) => r.startsWith('POST')).length;
    expect(posts, lessThanOrEqualTo(34));
    expect(server.tables['customers']!.length, 40);
    expect(server.tables['rentals']!.length, 90);
    await db.close();
  });

  group('backup', () {
    test('encrypted file round-trips and rejects the wrong password', () async {
      final db = await _openSeeded(dir, 'bk.db');
      final snapshot = await exportSnapshot(db);
      final bytes = await BackupCodec.encrypt(snapshot, 'correct horse');
      expect(String.fromCharCodes(bytes.sublist(0, 5)), 'BRAC1');

      final back = await BackupCodec.decrypt(bytes, 'correct horse');
      expect(back.rentals.length, 60);
      expect(back.customers.length, 10);
      expect(back.vehicles.length, 3);

      expect(
        () => BackupCodec.decrypt(bytes, 'wrong'),
        throwsA(isA<WrongPasswordException>()),
      );
      expect(
        () => BackupCodec.decrypt(Uint8List.fromList([1, 2, 3]), 'x'),
        throwsA(isA<BackupFormatException>()),
      );
      await db.close();
    });

    test('restore fills what is missing without overwriting the cloud',
        () async {
      final db = await openAppDatabase(
        databaseFactoryFfi,
        p.join(dir.path, 'r.db'),
      );
      final services = AppServices.forDatabase(db);
      services.cloudSync = engineFor(db);
      await services.cloudSync!.syncNow();
      // A backup taken while everything was fine...
      final snapshot = await exportSnapshot(db);

      // ...then the cloud loses 30 rentals and one is edited there.
      final serverRentals = server.tables['rentals']!;
      for (final id in serverRentals.keys.take(30).toList()) {
        serverRentals.remove(id);
      }
      final keptId = serverRentals.keys.first;
      serverRentals[keptId] = {
        ...serverRentals[keptId]!,
        'remarks': 'cloud is newer',
        'version': 9,
        'updated_at': '2026-09-17T00:00:00.000Z',
        'synced_at': server._stamp(),
      };

      await restoreIntoApp(services, snapshot);
      final summary = await services.cloudSync!.syncNow();
      expect(summary.failed, 0, reason: summary.error);
      expect(serverRentals.length, 60, reason: 'lost rows put back');
      expect(serverRentals[keptId]!['remarks'], 'cloud is newer');
      final local = (await db.query(
        'rentals',
        where: 'id = ?',
        whereArgs: [keptId],
      ))
          .first;
      expect(local['remarks'], 'cloud is newer', reason: 'cloud wins locally');
      expect(await _count(db, 'rentals'), 60);
      await services.cloudSync!.stop();
      await services.cloudSync!.settle();
      await db.close();
    });
  });

  test('a rental whose vehicle row vanished still syncs, and says so',
      () async {
    final db = await openAppDatabase(
      databaseFactoryFfi,
      p.join(dir.path, 'dead.db'),
    );
    final engine = engineFor(db);
    await engine.syncNow();
    final customer =
        (await db.query('customers', limit: 1)).first['id'] as String;
    final rentalId = await LocalSyncEngine().createPendingRental(
      db,
      customerId: customer,
      vehicleId: 'gone-forever',
      amount: 1200,
      status: 'Open',
    );

    final summary = await engine.syncNow();
    expect(summary.failed, 0, reason: summary.error);
    expect(summary.pushed, 1);
    expect(summary.notices, hasLength(1));
    expect(summary.notices.single, contains('lost its vehicle link'));
    final pushed = server.tables['rentals']![rentalId]!;
    expect(pushed['vehicle_id'], isNull);
    expect(pushed['customer_id'], customer);
    expect(pushed['rental_no'], 61);
    final local =
        (await db.query('rentals', where: 'id = ?', whereArgs: [rentalId]))
            .first;
    expect(local['vehicle_id'], isNull);

    final again = await engine.syncNow();
    expect(again.notices, isEmpty);
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
