import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:test/test.dart';

import 'package:burhan_rent_a_car_data/src/db/ffi_database.dart';
import 'package:burhan_rent_a_car_data/src/import/import_pipeline.dart';
import 'package:burhan_rent_a_car_data/src/import/test_csv_mapper.dart';
import 'package:burhan_rent_a_car_data/src/sync/local_sync_engine.dart';
import 'package:burhan_rent_a_car_data/src/sync/outbox.dart';

void main() {
  late Directory tempDir;
  late Database db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('outbox_test_');
    db = await openAppDatabaseFfi(p.join(tempDir.path, 'test.db'));
    await ImportPipeline(mapper: TestCsvMapper())
        .importFile(db, 'test_data/burhan_rent_a_car_temporary_test.csv');
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  test('a change the server keeps rejecting is listed with its error, and '
      'can be discarded by the owner', () async {
    final outbox = Outbox();
    final rental = (await db.query('rentals',
            where: 'rental_no = ?', whereArgs: [23]))
        .single;
    await LocalSyncEngine()
        .queueUpdate(db, rental['id'] as String, {'remarks': 'typed offline'});

    var details = await outbox.pendingDetails(db);
    expect(details, hasLength(1));
    expect(details.single['rental_no'], 23);
    expect(details.single['retry_count'], 0);
    expect(details.single['last_error'], isNull);

    final id = details.single['id'] as String;
    await outbox.markFailed(db, id, 'PostgrestException: 23503 foreign key');
    await outbox.markFailed(db, id, 'PostgrestException: 23503 foreign key');
    details = await outbox.pendingDetails(db);
    expect(details.single['retry_count'], 2);
    expect(details.single['last_error'], contains('23503'));
    expect(await outbox.pendingCount(db), 1, reason: 'still waiting');

    await outbox.discard(db, id);
    expect(await outbox.pendingDetails(db), isEmpty);
    expect(await outbox.pendingCount(db), 0);
    // The local edit is untouched; only its delivery was given up.
    final after = (await db.query('rentals',
            where: 'rental_no = ?', whereArgs: [23]))
        .single;
    expect(after['remarks'], 'typed offline');
  });
}
