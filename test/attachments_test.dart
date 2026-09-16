import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'package:burhan_rent_a_car_data/src/backup/snapshot.dart';
import 'package:burhan_rent_a_car_data/src/db/database.dart';
import 'package:burhan_rent_a_car_data/src/db/ffi_database.dart';
import 'package:burhan_rent_a_car_data/src/db/schema.dart';
import 'package:burhan_rent_a_car_data/src/import/import_pipeline.dart';
import 'package:burhan_rent_a_car_data/src/import/test_csv_mapper.dart';
import 'package:burhan_rent_a_car_data/src/repositories/attachment_repository.dart';
import 'package:burhan_rent_a_car_data/src/repositories/rental_repository.dart';
import 'package:burhan_rent_a_car_data/src/sync/local_sync_engine.dart';

const _testCsvPath = 'test_data/burhan_rent_a_car_temporary_test.csv';

Uint8List _fakeJpeg(int seed, [int length = 2048]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * seed) % 256));

void main() {
  late Directory tempDir;
  late Database db;
  final attachments = AttachmentRepository();
  final rentals = RentalRepository();
  final engine = LocalSyncEngine();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('burhan_attach_');
    db = await openAppDatabaseFfi(p.join(tempDir.path, 'a.db'));
    await ImportPipeline(mapper: TestCsvMapper()).importFile(db, _testCsvPath);
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  Future<String> rentalId(int no) async =>
      (await rentals.findByRentalNo(db, no))!['id'] as String;

  group('rental agreement photo', () {
    test('round-trips full image and thumbnail', () async {
      final id = await rentalId(23);
      final image = _fakeJpeg(7);
      final thumb = _fakeJpeg(3, 256);

      await engine.setRentalAgreementPhoto(
        db,
        rentalId: id,
        image: image,
        thumbnail: thumb,
        mimeType: 'image/jpeg',
      );

      final row = await attachments.rentalAgreement(db, id);
      expect(row, isNotNull);
      expect(row!['image'], image);
      expect(row['thumbnail'], thumb);
      expect(row['mime_type'], 'image/jpeg');
    });

    test('a rental with no photo returns null, not an error', () async {
      expect(await attachments.rentalAgreement(db, await rentalId(1)), isNull);
    });

    test('replacing keeps one live photo and retires the old one', () async {
      final id = await rentalId(23);
      await engine.setRentalAgreementPhoto(db, rentalId: id, image: _fakeJpeg(1));
      await engine.setRentalAgreementPhoto(db, rentalId: id, image: _fakeJpeg(2));

      final live = await attachments.rentalAgreement(db, id);
      expect(live!['image'], _fakeJpeg(2));

      final all = await db.query(
        'attachments',
        where: 'entity_id = ?',
        whereArgs: [id],
      );
      expect(all, hasLength(2));
      expect(all.where((r) => r['is_deleted'] == 1), hasLength(1));
    });

    test('removing soft-deletes; nothing is ever erased', () async {
      final id = await rentalId(23);
      await engine.setRentalAgreementPhoto(db, rentalId: id, image: _fakeJpeg(1));
      await engine.removeRentalAgreementPhoto(db, id);

      expect(await attachments.rentalAgreement(db, id), isNull);
      final rows = await db.query('attachments', where: 'entity_id = ?', whereArgs: [id]);
      expect(rows, hasLength(1));
      expect(rows.single['is_deleted'], 1);
    });

    test('thumbnails come back for a list of rentals in one query', () async {
      final a = await rentalId(1);
      final b = await rentalId(12);
      final c = await rentalId(13); // no photo
      await engine.setRentalAgreementPhoto(db, rentalId: a, image: _fakeJpeg(1), thumbnail: _fakeJpeg(11, 64));
      await engine.setRentalAgreementPhoto(db, rentalId: b, image: _fakeJpeg(2), thumbnail: _fakeJpeg(12, 64));

      final thumbs = await attachments.agreementThumbnails(db, [a, b, c]);
      expect(thumbs.keys, unorderedEquals([a, b]));
      expect(thumbs[a], _fakeJpeg(11, 64));
    });

    test('every photo change is queued for sync', () async {
      final id = await rentalId(23);
      await engine.setRentalAgreementPhoto(db, rentalId: id, image: _fakeJpeg(1));
      await engine.removeRentalAgreementPhoto(db, id);

      final queued = await db.query(
        'sync_queue',
        where: "entity_type = 'attachment'",
        orderBy: 'created_at',
      );
      expect(queued.map((q) => q['operation']), ['insert', 'delete']);
    });

    test('backup snapshot carries photos and restore is idempotent', () async {
      final id = await rentalId(23);
      await engine.setRentalAgreementPhoto(db, rentalId: id, image: _fakeJpeg(9));

      final snapshot = await exportSnapshot(db);
      expect(snapshot.attachments, hasLength(1));

      final fresh = await openAppDatabaseFfi(p.join(tempDir.path, 'restore.db'));
      await restoreSnapshot(fresh, snapshot);
      await restoreSnapshot(fresh, snapshot);
      final restored = await attachments.rentalAgreement(fresh, id);
      expect(restored!['image'], _fakeJpeg(9));
      expect(await fresh.query('attachments'), hasLength(1));
      await fresh.close();
    });
  });

  group('schema upgrade', () {
    test('a version-1 database gains the attachments table and keeps its rows',
        () async {
      // Build a database exactly as the currently-installed app would have:
      // version 1, no attachments table.
      final path = p.join(tempDir.path, 'v1.db');
      sqfliteFfiInit();
      final v1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            for (final statement in createTableStatements) {
              if (attachmentsTableStatements.contains(statement) ||
                  syncConflictsTableStatements.contains(statement)) {
                continue;
              }
              await db.execute(statement);
            }
          },
        ),
      );
      await ImportPipeline(mapper: TestCsvMapper()).importFile(v1, _testCsvPath);
      final beforeRentals = (await v1.query('rentals')).length;
      expect(await v1.getVersion(), 1);
      await v1.close();

      // Reopen with the current code: onUpgrade must run.
      final upgraded = await openAppDatabase(databaseFactoryFfi, path);
      expect(await upgraded.getVersion(), schemaVersion);
      expect((await upgraded.query('rentals')).length, beforeRentals);
      expect(await upgraded.query('attachments'), isEmpty); // exists, empty
      expect(await upgraded.query('sync_conflicts'), isEmpty); // v3, empty

      // And it is fully usable.
      final id = (await rentals.findByRentalNo(upgraded, 5))!['id'] as String;
      await engine.setRentalAgreementPhoto(upgraded, rentalId: id, image: _fakeJpeg(4));
      expect(await attachments.rentalAgreement(upgraded, id), isNotNull);
      await upgraded.close();
    });
  });
}
