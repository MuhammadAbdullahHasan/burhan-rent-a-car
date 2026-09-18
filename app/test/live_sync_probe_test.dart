// ignore_for_file: avoid_print
// A one-off probe, skipped unless SUPABASE_EMAIL/PASSWORD are set: signs in
// as the owner, opens a fresh local database (what a new phone has) and runs
// the real sync engine against the cloud, printing exactly what the Home bar
// would show. Never part of the normal suite.
import 'dart:io';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:burhan_rent_a_car/services/agreement_archive.dart';
import 'package:burhan_rent_a_car/supabase_config.dart';
import 'package:burhan_rent_a_car/sync/cloud_sync_engine.dart';

void main() {
  final email = Platform.environment["SUPABASE_EMAIL"] ?? "";
  final password = Platform.environment["SUPABASE_PASSWORD"] ?? "";
  test('live sync pass against the cloud', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('live_probe_');
    final db = await openAppDatabase(databaseFactoryFfi, p.join(dir.path, 'probe.db'));
    final client = SupabaseClient(supabaseUrl, supabasePublishableKey);
    await client.auth.signInWithPassword(email: email, password: password);
    final engine = CloudSyncEngine(client: client, db: db);
    final sw = Stopwatch()..start();
    final first = await engine.syncNow();
    print('PASS 1 (${sw.elapsed}): pushed=${first.pushed} pulled=${first.pulled} failed=${first.failed} conflicts=${first.conflicts} error=${first.error} notices=${first.notices}');
    final counts = await db.rawQuery('select (select count(*) from rentals) r, (select count(*) from customers) c, (select count(*) from vehicles) v, (select count(*) from attachments) a, (select count(*) from sync_queue) q');
    print('LOCAL after pass 1: $counts');
    sw.reset();
    final second = await engine.syncNow();
    print('PASS 2 (${sw.elapsed}): pushed=${second.pushed} pulled=${second.pulled} failed=${second.failed} error=${second.error} notices=${second.notices}');
    // Push path: the same edits the app makes (vehicle insurance date via the
    // insurance dialog, a rental's remarks via the form), then a sync pass.
    final local = LocalSyncEngine();
    final v = (await db.query('vehicles', where: 'registration_no = ?', whereArgs: ['BKY-391'])).first;
    await local.updateVehicle(db, v['id'] as String, {'insurance_due_on': v['insurance_due_on']});
    final r = (await db.query('rentals', where: 'rental_no = ?', whereArgs: [1])).first;
    await local.queueUpdate(db, r['id'] as String, {'remarks': r['remarks']});
    final q = await db.rawQuery("select entity_type, operation, status from sync_queue");
    print('QUEUE before push: $q');
    sw.reset();
    final third = await engine.syncNow();
    print('PASS 3 push (${sw.elapsed}): pushed=${third.pushed} pulled=${third.pulled} failed=${third.failed} conflicts=${third.conflicts} error=${third.error} notices=${third.notices}');
    print('QUEUE after push: ${await db.rawQuery("select entity_type, operation, status, last_error from sync_queue")}');
    final marked = await db.rawQuery("select rental_no, version, substr(remarks,1,20) rem from rentals where rental_no in (8671, 8552) order by rental_no");
    print('MARKED ROWS on device: $marked');
    final archive = AgreementArchive(client: client);
    for (final no in [1, 5, 96, 7576, 9921, 9630]) {
      final sw2 = Stopwatch()..start();
      final photos = await archive.photosFor(no);
      print('ARCHIVE #$no: ${photos.length} photo(s) ${photos.map((b) => '${b.length ~/ 1024} KB').join(', ')} in ${sw2.elapsedMilliseconds} ms');
    }
    await engine.stop();
    await db.close();
    await client.dispose();
  }, skip: email.isEmpty || password.isEmpty ? 'no credentials' : false, timeout: const Timeout(Duration(minutes: 15)));
}
