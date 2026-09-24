import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase_config.dart';
import 'package:uuid/uuid.dart';

/// What one sync pass did, for the UI to report.
class SyncSummary {
  final int pushed;
  final int pulled;
  final int failed;
  final int conflicts;
  final String? error;

  /// Things the owner should know that are not failures -- e.g. a rental
  /// whose vehicle link could not be recovered and needs setting again.
  final List<String> notices;

  const SyncSummary({
    required this.pushed,
    required this.pulled,
    this.failed = 0,
    this.conflicts = 0,
    this.error,
    this.notices = const [],
  });

  bool get hasError => error != null || failed > 0;
  bool get changedAnything => pushed > 0 || pulled > 0 || conflicts > 0;
}

const _hydratedKey = 'cloud_hydrated';
const _generationKey = 'cloud_generation';
const _watermarkPrefix = 'cloud_wm_';
const _epoch = '1970-01-01T00:00:00.000Z';
const _pageSize = 500;
const _archiveBucket = 'agreements';
const _batchSize = 200;
const _attachmentBatchSize = 20;

/// Re-read this much before the last watermark on every pull. Rows are
/// stamped with the server clock at write time, and a write that commits a
/// moment after a later-stamped one could otherwise slip between two pulls.
/// Applying a row twice is harmless (idempotent by id).
const _overlap = Duration(seconds: 10);

const _uuid = Uuid();

/// The only thing in the app that talks to Postgres.
///
/// Every read/write the rest of the app does goes to local SQLite
/// (offline-first); this engine pushes the outbox up and pulls remote
/// changes down, keeping local rows equal to the server's.
///
/// * Push before pull in one pass, so a pull can never clobber a change
///   this device hasn't sent; pull also skips rows still pending.
/// * Pull is paged and driven by the SERVER's change clock (`synced_at`),
///   never a device clock, so nothing is missed on a phone with a wrong
///   time and a 10,000-row dataset arrives complete.
/// * Realtime: the server announces every change; [start] subscribes and
///   a pull follows within a second. A periodic pass and the connectivity
///   listener in main.dart are the safety net.
/// * Edits carry a version. An edit that reaches the server after a newer
///   edit of the same record from another device is NOT applied over it:
///   the server's row wins locally and the overridden values are kept in
///   `sync_conflicts` for the owner to see. Nothing is lost silently.
/// * A device starts empty and is filled by its first pull ("hydration").
///   Devices from before that rule held their own private copy of the test
///   dataset; their first sync replaces it with the cloud's -- [_hydrate].
class CloudSyncEngine {
  final SupabaseClient client;
  final Database db;
  final Outbox _outbox = Outbox();

  /// True while the realtime channel is connected.
  final ValueNotifier<bool> live = ValueNotifier<bool>(false);

  Future<SyncSummary>? _inFlight;
  bool _runAgain = false;
  RealtimeChannel? _channel;
  Timer? _periodic;
  Timer? _debounce;
  void Function(SyncSummary summary)? onPass;

  CloudSyncEngine({required this.client, required this.db});

  /// True once this device's local data has been taken from the cloud
  /// rather than seeded locally.
  static Future<bool> isHydrated(DatabaseExecutor db) async {
    final rows = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [_hydratedKey],
    );
    return rows.isNotEmpty;
  }

  // ---- lifecycle -----------------------------------------------------------

  /// Subscribes to server change notifications and starts the periodic
  /// safety pass. Idempotent.
  void start() {
    if (_channel != null) return;
    var channel = client.channel('sync-${_uuid.v4()}');
    for (final table in const [
      'customers',
      'vehicles',
      'rentals',
      'attachments'
    ]) {
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => requestSync(),
      );
    }
    _channel = channel
      ..subscribe((status, error) {
        final connected = status == RealtimeSubscribeStatus.subscribed;
        live.value = connected;
        // Anything that happened while disconnected is picked up now.
        if (connected) requestSync();
      });
    _periodic = Timer.periodic(const Duration(seconds: 60), (_) => syncNow());
  }

  Future<void> stop() async {
    _periodic?.cancel();
    _periodic = null;
    _debounce?.cancel();
    _debounce = null;
    final channel = _channel;
    _channel = null;
    live.value = false;
    if (channel != null) await client.removeChannel(channel);
  }

  /// Coalesces bursts (a realtime event per row, a save followed by a photo)
  /// into one pass shortly after the last request.
  void requestSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), syncNow);
  }

  /// Overlapping calls share one pass; a request that arrives mid-pass
  /// triggers exactly one more pass afterwards, so nothing announced during
  /// a pass is missed. (Two passes at once could also ask the server for a
  /// rental number twice for the same rental.)
  Future<SyncSummary> syncNow() {
    final running = _inFlight;
    if (running != null) {
      _runAgain = true;
      return running;
    }
    final pass = _run().whenComplete(() {
      _inFlight = null;
      if (_runAgain) {
        _runAgain = false;
        syncNow();
      }
    });
    _inFlight = pass;
    return pass;
  }

  /// Completes once no pass is running (tests, and shutdown).
  Future<void> settle() async {
    while (_inFlight != null) {
      await _inFlight;
    }
  }

  Future<SyncSummary> _run() async {
    try {
      await _adoptGeneration();
    } catch (e) {
      return SyncSummary(pushed: 0, pulled: 0, error: e.toString());
    }
    if (!await isHydrated(db)) {
      try {
        await _hydrate();
      } catch (e) {
        return SyncSummary(pushed: 0, pulled: 0, error: e.toString());
      }
    }

    var pushed = 0;
    var failed = 0;
    var conflicts = 0;
    var notices = const <String>[];
    String? error;
    try {
      final result = await _push();
      pushed = result.pushed;
      failed = result.failed;
      conflicts = result.conflicts;
      error = result.firstError;
      notices = result.notices;
    } catch (e) {
      error = e.toString();
    }
    var pulled = 0;
    try {
      pulled = await _pull();
    } catch (e) {
      error ??= e.toString();
    }
    try {
      await _fileUnfiledPhotos();
    } catch (e) {
      error ??= e.toString();
    }
    final summary = SyncSummary(
      pushed: pushed,
      pulled: pulled,
      failed: failed,
      conflicts: conflicts,
      error: error,
      notices: notices,
    );
    onPass?.call(summary);
    return summary;
  }

  // ---- push ------------------------------------------------------------

  Future<_PushResult> _push() async {
    var pushed = 0;
    var failed = 0;
    var conflicts = 0;
    String? firstError;
    _notices = [];

    // Parents before children, otherwise in the order things happened:
    // every customer/vehicle a rental needs was created before it, and an
    // entity's own create precedes its edits, so a stable sort by kind
    // keeps every dependency while letting creates of one kind batch.
    final items = List.of(await _outbox.pending(db))
      ..sort((a, b) => _order(a['entity_type'] as String)
          .compareTo(_order(b['entity_type'] as String)));
    var i = 0;
    while (i < items.length) {
      final item = items[i];
      final entityType = item['entity_type'] as String;
      final operation = item['operation'] as String;

      // Consecutive creates/restores of one kind go up in one request.
      if (operation == 'insert' || operation == 'restore') {
        final batch = <Map<String, Object?>>[item];
        final limit =
            entityType == 'attachment' ? _attachmentBatchSize : _batchSize;
        while (i + batch.length < items.length && batch.length < limit) {
          final next = items[i + batch.length];
          if (next['entity_type'] != entityType ||
              next['operation'] != operation) {
            break;
          }
          batch.add(next);
        }
        i += batch.length;
        try {
          await _pushBatch(entityType, operation, batch);
          for (final b in batch) {
            await _outbox.markDone(db, b['id'] as String);
          }
          pushed += batch.length;
        } catch (e) {
          failed += batch.length;
          firstError ??= e.toString();
          for (final b in batch) {
            await _outbox.markFailed(db, b['id'] as String, e.toString());
          }
        }
        continue;
      }

      i++;
      final id = item['id'] as String;
      try {
        final conflicted =
            await _pushEdit(entityType, item['entity_id'] as String);
        await _outbox.markDone(db, id);
        if (conflicted) {
          conflicts++;
        } else {
          pushed++;
        }
      } catch (e) {
        failed++;
        firstError ??= e.toString();
        await _outbox.markFailed(db, id, e.toString());
      }
    }
    return _PushResult(pushed, failed, conflicts, firstError, _notices);
  }

  /// Creates (and restore fills) go up as upserts. `restore` never
  /// overwrites a row the server already has -- the cloud stays the truth
  /// and a backup only fills what is missing.
  Future<void> _pushBatch(
    String entityType,
    String operation,
    List<Map<String, Object?>> batch,
  ) async {
    final table = _tableOf(entityType);
    final ids = batch.map((b) => b['entity_id'] as String).toList();
    final rows = await _rowsByIds(table, ids);
    if (rows.isEmpty) return; // deleted locally before ever syncing
    final ignoreExisting = operation == 'restore';

    if (entityType == 'rental') {
      // Numbers first (one atomic server call each), then one upsert.
      final numbered = <Map<String, Object?>>[];
      for (final raw in rows) {
        final row = await _healLinks(raw);
        numbered.add(row['rental_no'] == null
            ? {...row, 'rental_no': await _allocateNumber(row['id'] as String)}
            : row);
      }
      try {
        await _upsertRentals(numbered, ignoreExisting);
      } on PostgrestException catch (e) {
        if (e.code != '23503') rethrow; // a parent is missing on the server
        await _ensureParents(numbered);
        await _upsertRentals(numbered, ignoreExisting);
      }
      return;
    }

    if (entityType == 'attachment') {
      for (final row in rows) {
        await _fileInArchive(row);
      }
    }

    final remote = rows.map((r) => _toRemote(table, r)).toList();
    await client.from(table).upsert(remote, ignoreDuplicates: ignoreExisting);
  }

  /// Photos taken before the app filed them by number (or while their
  /// rental was still unnumbered) are filed on a later pass, a few at a
  /// time so a sync is never held up by them.
  ///
  /// A number that already has something filed under it is left alone and
  /// simply remembered: either this very photo was filed by another
  /// device, or the rental has a scan from before the app -- and in
  /// neither case should a second copy be added.
  Future<void> _fileUnfiledPhotos() async {
    final unfiled = await db.query(
      'attachments',
      where: "storage_path IS NULL AND is_deleted = 0 AND kind = ? "
          "AND entity_type = 'rental'",
      whereArgs: [kindRentalAgreement],
      limit: 20,
    );
    for (final attachment in unfiled) {
      final rental =
          await _rowById('rentals', attachment['entity_id'] as String);
      final rentalNo = rental?['rental_no'] as int?;
      if (rentalNo == null) continue;

      final existing = await _archiveNamesFor(rentalNo);
      if (existing.isNotEmpty) {
        await db.update(
          'attachments',
          {'storage_path': existing.first},
          where: 'id = ?',
          whereArgs: [attachment['id']],
        );
        continue;
      }
      await _fileInArchive(attachment);
    }
  }

  /// Files a photo taken in the app in the `agreements` bucket under the
  /// rental's number -- "96.jpg" for a rental's first photo, "96-2.jpg"
  /// for the next -- so it sits in the archive beside the scans made
  /// before the app, and any device can find it by number.
  ///
  /// The name it took is kept on this device, so a retry after a failed
  /// push re-uses it instead of claiming a second name. A rental that has
  /// no number yet (created offline, not pushed) is left for a later pass;
  /// the photo is on the rental either way.
  Future<void> _fileInArchive(Map<String, Object?> attachment) async {
    if (attachment['entity_type'] != 'rental') return;
    if (attachment['kind'] != kindRentalAgreement) return;
    if ((attachment['storage_path'] as String?)?.isNotEmpty ?? false) return;

    final rental = await _rowById('rentals', attachment['entity_id'] as String);
    final rentalNo = rental?['rental_no'] as int?;
    if (rentalNo == null) return;

    final name = await _freeArchiveName(rentalNo);
    await client.storage.from(_archiveBucket).uploadBinary(
          '$businessFolder/$name',
          attachment['image'] as Uint8List,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
          ),
        );
    await db.update(
      'attachments',
      {'storage_path': name},
      where: 'id = ?',
      whereArgs: [attachment['id']],
    );
  }

  /// The first name free for [rentalNo]: "96.jpg", else "96-2.jpg",
  /// "96-3.jpg" ... so a new photo never overwrites a scan already filed
  /// under that number.
  Future<String> _freeArchiveName(int rentalNo) async {
    final taken = await _archiveNamesFor(rentalNo);
    if (!taken.contains('$rentalNo.jpg')) return '$rentalNo.jpg';
    for (var i = 2; i <= 99; i++) {
      if (!taken.contains('$rentalNo-$i.jpg')) return '$rentalNo-$i.jpg';
    }
    return '$rentalNo-${DateTime.now().millisecondsSinceEpoch}.jpg';
  }

  List<String> _notices = [];

  /// A rental pointing at a customer/vehicle that exists nowhere any more
  /// (a copy that was replaced before its link could be re-pointed) would
  /// be refused by the server forever. The dead link is cleared so the
  /// rental syncs, and the owner is told which rental needs the link set
  /// again. Nothing else about the rental changes.
  Future<Map<String, Object?>> _healLinks(Map<String, Object?> row) async {
    var healed = row;
    for (final (column, table) in _rentalParents) {
      final ref = row[column] as String?;
      if (ref == null || await _rowById(table, ref) != null) continue;
      await db.update(
        'rentals',
        {column: null},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      healed = {...healed, column: null};
      final what = column == 'customer_id' ? 'customer' : 'vehicle';
      _notices.add(
        'Rental ${rentalDisplayNumber(healed)} lost its $what link and needs '
        'it set again (open the rental, Edit).',
      );
    }
    return healed;
  }

  Future<void> _upsertRentals(
    List<Map<String, Object?>> rows,
    bool ignoreExisting,
  ) async {
    try {
      await client.from('rentals').upsert(
            rows.map(_rentalToRemote).toList(),
            ignoreDuplicates: ignoreExisting,
          );
    } on PostgrestException catch (e) {
      // A number this device held without the server ever storing it has
      // since been taken. It was never confirmed; the server issues the
      // real one now -- one rental at a time so the rest are unaffected.
      final numberTaken = e.code == '23505' && e.message.contains('rental_no');
      if (!numberTaken || ignoreExisting) rethrow;
      for (final row in rows) {
        await _pushRentalRenumbering(row);
      }
    }
  }

  Future<void> _pushRentalRenumbering(Map<String, Object?> row) async {
    try {
      await client.from('rentals').upsert(_rentalToRemote(row));
    } on PostgrestException catch (e) {
      final numberTaken = e.code == '23505' && e.message.contains('rental_no');
      if (!numberTaken ||
          !await _createdLocally('rental', row['id'] as String)) {
        rethrow;
      }
      final fresh = {
        ...row,
        'rental_no': await _allocateNumber(row['id'] as String),
      };
      await client.from('rentals').upsert(_rentalToRemote(fresh));
    }
  }

  /// A rental's customer/vehicle must exist on the server before the
  /// rental can (foreign keys). Outbox order normally guarantees that; this
  /// covers a parent that exists only locally for any other reason.
  /// Insert-if-missing only -- never overwrites a server copy.
  Future<void> _ensureParents(List<Map<String, Object?>> rentals) async {
    for (final (column, table) in const [
      ('customer_id', 'customers'),
      ('vehicle_id', 'vehicles'),
    ]) {
      final ids = rentals
          .map((r) => r[column] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      if (ids.isEmpty) continue;
      final rows = await _rowsByIds(table, ids);
      if (rows.isEmpty) continue;
      await client.from(table).upsert(
            rows.map((r) => _toRemote(table, r)).toList(),
            ignoreDuplicates: true,
          );
    }
  }

  Future<int> _allocateNumber(String rentalId) async {
    final response = await client.rpc('allocate_rental_no');
    final rentalNo = (response as num).toInt();
    await db.update(
      'rentals',
      {'rental_no': rentalNo},
      where: 'id = ?',
      whereArgs: [rentalId],
    );
    return rentalNo;
  }

  /// An edit (update / soft delete) is applied only if the server's copy is
  /// older than the version this edit was made on. Returns true when it
  /// lost to a newer edit from another device -- the server's row is then
  /// taken locally and the overridden values recorded.
  Future<bool> _pushEdit(String entityType, String entityId) async {
    final table = _tableOf(entityType);
    final rows = await db.query(table, where: 'id = ?', whereArgs: [entityId]);
    if (rows.isEmpty) return false;
    final local = rows.first;
    final version = local['version'] as int;

    if (entityType == 'rental' && local['rental_no'] == null) {
      // Edited before it was ever sent: the pending create carries the
      // edit, and there is no server row to race against yet.
      return false;
    }

    final remote = _toRemote(table, local);
    final updated = await client
        .from(table)
        .update(remote)
        .eq('id', entityId)
        .lt('version', version)
        .select('id');
    if (updated.isNotEmpty) return false;

    final server =
        await client.from(table).select().eq('id', entityId).maybeSingle();
    if (server == null) {
      // Never reached the server (created on an old build); create it now.
      if (entityType == 'rental') await _ensureParents([local]);
      await client.from(table).upsert(remote);
      return false;
    }
    if (server['version'] == version &&
        server['updated_at'] == local['updated_at']) {
      return false; // this exact edit is already there
    }

    await db.insert('sync_conflicts', {
      'id': _uuid.v4(),
      'entity_type': entityType,
      'entity_id': entityId,
      'local_row': jsonEncode(_jsonSafe(local)),
      'server_row': jsonEncode(server),
      'resolved': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    await _apply(table, server);
    return true;
  }

  /// Everything already filed under [rentalNo]: "96.jpg", "96-2.jpg" ...
  /// A search matches on substring, so "961.jpg" can come back too; only
  /// exact names for this number are kept.
  Future<Set<String>> _archiveNamesFor(int rentalNo) async {
    final names = <String>{};
    final pattern = RegExp('^$rentalNo(-\\d+)?\\.jpg\$');
    for (final search in ['$rentalNo.', '$rentalNo-']) {
      final objects = await client.storage.from(_archiveBucket).list(
            path: businessFolder,
            searchOptions: SearchOptions(search: search),
          );
      names.addAll(objects.map((o) => o.name).where(pattern.hasMatch));
    }
    return names;
  }

  // ---- pull --------------------------------------------------------------

  Future<int> _pull() async {
    final pulled = await _pullAll();
    return pulled.values.fold<int>(0, (sum, r) => sum + r.written.length);
  }

  /// Pulls every table from its own watermark.
  Future<Map<String, _PullResult>> _pullAll() async {
    return {
      for (final table in _syncedTables)
        table: await _pullTable(table, await _pendingIdsFor(_typeOf(table))),
    };
  }

  Future<_PullResult> _pullTable(String table, Set<String> skipIds) async {
    final watermark = await _watermark(table);
    final since = watermark == _epoch
        ? _epoch
        : DateTime.parse(watermark)
            .toUtc()
            .subtract(_overlap)
            .toIso8601String();

    // `written`: rows this pass actually inserted/replaced -- what the
    // owner-facing summary ("N received") and changedAnything should count.
    // `confirmed`: written, PLUS rows already identical locally (skipped as
    // a no-op write, but still a real, current cloud row -- not a leftover
    // to be cleaned up). Hydrate's post-pull cleanup needs `confirmed`: a
    // resumed hydrate (the first attempt was interrupted, e.g. the app was
    // closed mid-download) must not drop rows the interrupted attempt
    // already saved correctly just because this pass had no reason to
    // rewrite them.
    final written = <String>{};
    final confirmed = <String>{};
    var newest = watermark;
    var offset = 0;
    while (true) {
      final rows = await client
          .from(table)
          .select()
          .gt('synced_at', since)
          .order('synced_at', ascending: true)
          .order('id', ascending: true)
          .range(offset, offset + _pageSize - 1);
      for (final row in rows) {
        final id = row['id'] as String;
        final stamp = row['synced_at'] as String;
        if (_isLater(stamp, newest)) newest = stamp;
        if (skipIds.contains(id)) continue; // has an unpushed local change
        if (await _alreadyLocal(table, row)) {
          confirmed.add(id);
          continue; // overlap re-read; already correct, nothing to write
        }
        await _apply(table, row);
        written.add(id);
        confirmed.add(id);
      }
      if (rows.length < _pageSize) break;
      offset += rows.length;
    }
    if (newest != watermark) await _setWatermark(table, newest);
    return _PullResult(written, confirmed);
  }

  /// The overlap window re-reads rows this device already holds; an
  /// identical copy is neither re-written nor reported as a change.
  Future<bool> _alreadyLocal(String table, Map<String, dynamic> row) async {
    final local = await db.query(
      table,
      columns: ['version', 'updated_at', if (table == 'rentals') 'rental_no'],
      where: 'id = ?',
      whereArgs: [row['id']],
    );
    if (local.isEmpty) return false;
    final l = local.first;
    return l['version'] == row['version'] &&
        l['updated_at'] == row['updated_at'] &&
        (table != 'rentals' || l['rental_no'] == row['rental_no']);
  }

  bool _isLater(String a, String b) {
    if (b == _epoch) return true;
    return DateTime.parse(a).isAfter(DateTime.parse(b));
  }

  Future<Set<String>> _pendingIdsFor(String entityType) async {
    final rows = await db.query(
      'sync_queue',
      columns: ['entity_id'],
      where: "entity_type = ? AND status = 'pending'",
      whereArgs: [entityType],
    );
    return rows.map((r) => r['entity_id'] as String).toSet();
  }

  Future<void> _apply(String table, Map<String, dynamic> row) =>
      switch (table) {
        'customers' => _applyCustomer(row),
        'vehicles' => _applyVehicle(row),
        'rentals' => _applyRental(row),
        _ => _applyAttachment(row),
      };

  Future<void> _applyCustomer(Map<String, Object?> r) => db.insert(
        'customers',
        {
          'id': r['id'],
          'full_name': r['full_name'],
          'phone': r['phone'],
          'phone_normalized': r['phone_normalized'],
          'cnic': r['cnic'],
          'cnic_normalized': r['cnic_normalized'],
          'license_no': r['license_no'],
          'license_city': r['license_city'],
          'possible_duplicate': _asInt(r['possible_duplicate']),
          'is_deleted': _asInt(r['is_deleted']),
          'version': r['version'],
          'created_at': r['created_at'],
          'updated_at': r['updated_at'],
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> _applyVehicle(Map<String, Object?> r) => db.insert(
        'vehicles',
        {
          'id': r['id'],
          'registration_no': r['registration_no'],
          'registration_norm': r['registration_norm'],
          'chassis_no': r['chassis_no'],
          'engine_no': r['engine_no'],
          'company': r['company'],
          'model_name': r['model_name'],
          'trim': r['trim'],
          'horsepower': r['horsepower'],
          'color': r['color'],
          'reg_year': r['reg_year'],
          'insurance_due_on': r['insurance_due_on'],
          // A server that has not got the column yet means
          // "in fleet", never "past".
          'in_fleet': r['in_fleet'] == null ? 1 : _asInt(r['in_fleet']),
          'is_deleted': _asInt(r['is_deleted']),
          'version': r['version'],
          'created_at': r['created_at'],
          'updated_at': r['updated_at'],
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// The server's number is authoritative. If a *locally created* rental
  /// already carries the incoming number (assigned by the pre-cloud local
  /// stand-in), it goes back to Pending and is renumbered when pushed; a
  /// stale copy of a cloud row simply gets replaced.
  Future<void> _applyRental(Map<String, Object?> r) async {
    final rentalNo = r['rental_no'];
    if (rentalNo != null) {
      final clash = await db.query(
        'rentals',
        columns: ['id'],
        where: 'rental_no = ? AND id != ?',
        whereArgs: [rentalNo, r['id']],
      );
      for (final row in clash) {
        final id = row['id'] as String;
        if (await _createdLocally('rental', id)) {
          await db.update(
            'rentals',
            {'rental_no': null},
            where: 'id = ?',
            whereArgs: [id],
          );
        }
      }
    }
    await db.insert(
      'rentals',
      {
        'id': r['id'],
        'rental_no': rentalNo,
        'is_placeholder': _asInt(r['is_placeholder']),
        'customer_id': r['customer_id'],
        'vehicle_id': r['vehicle_id'],
        'start_date': r['start_date'],
        'start_time': r['start_time'],
        'end_date': r['end_date'],
        'end_time': r['end_time'],
        'book_days': r['book_days'],
        'amount': r['amount'],
        'balance': r['balance'],
        'status': r['status'],
        'remarks': r['remarks'],
        'ref_name': r['ref_name'],
        'ref_contact': r['ref_contact'],
        'ref_relation': r['ref_relation'],
        'is_deleted': _asInt(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _applyAttachment(Map<String, Object?> r) async {
    final thumb = r['thumbnail_base64'] as String?;
    await db.insert(
      'attachments',
      {
        'id': r['id'],
        'entity_type': r['entity_type'],
        'entity_id': r['entity_id'],
        'kind': r['kind'],
        'mime_type': r['mime_type'],
        'image': base64Decode(r['image_base64'] as String),
        'thumbnail': thumb == null ? null : base64Decode(thumb),
        'is_deleted': _asInt(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---- hydration ------------------------------------------------------------

  /// First-ever cloud sync on this device. On a device that started empty
  /// this is just a full pull. On a device that still holds its own
  /// locally-seeded copy of the dataset, every row the owner never touched
  /// is a duplicate of a cloud row under a different id, so:
  ///
  ///  1. Seeded rows the owner *edited* here have their edits copied onto
  ///     the matching cloud row (same phone/CNIC, registration number or
  ///     rental number) and that row is queued as an update.
  ///  2. Rows the owner *created* here are kept and re-queued; references
  ///     from them to seeded customers/vehicles are re-pointed at the cloud
  ///     twin the same way.
  ///  3. Every other seeded row is dropped in favour of the cloud's copy.
  ///
  /// A local record whose twin can't be found is kept and sent up as new
  /// -- nothing the owner entered is ever discarded.
  Future<void> _hydrate() async {
    final startedAt = DateTime.now().toUtc().toIso8601String();
    final touched = await _touchedIds();
    final created = await _createdIds();

    // Snapshot BEFORE the pull: REPLACE on rental_no / registration_norm
    // deletes the seeded copies as their cloud twins arrive.
    final before = <String, Map<String, Map<String, Object?>>>{
      for (final table in _tables)
        table: {
          for (final r in await db.query(table)) r['id'] as String: r,
        },
    };

    // Anything still pending is re-queued below in dependency order.
    await db.update(
      'sync_queue',
      {'status': 'done'},
      where: "status = 'pending'",
    );

    await _resetWatermarks();
    final pulled = await _pullAll();
    final twin = {for (final table in _tables) table: <String, String>{}};
    final keep = {
      for (final table in _tables) table: {...created[_typeOf(table)]!},
    };

    /// The cloud id a local reference should point at, or null when the
    /// referenced row has no twin (it is then kept and sent up as new).
    Future<String?> resolve(String table, String id) async {
      // A row created here keeps its id -- unless the pull already replaced
      // it with a cloud row carrying the same registration / number, in
      // which case that cloud row is its twin.
      if (created[_typeOf(table)]!.contains(id) &&
          await _rowById(table, id) != null) {
        return id;
      }
      final mapped = twin[table]![id];
      if (mapped != null) return mapped;
      final row = before[table]![id];
      return row == null ? null : _match(table, row, pulled[table]!.confirmed);
    }

    /// Null when the referenced row exists nowhere any more: the link is
    /// then cleared (the push path reports it to the owner).
    Future<String?> resolveOrKeep(String table, String id) async {
      final target = await resolve(table, id);
      if (target != null) return target;
      if (await _rowById(table, id) == null) return null;
      keep[table]!.add(id);
      return id;
    }

    // 1. Edits to seeded rows -> onto the cloud twin. Customers and
    //    vehicles first so rentals can resolve through them.
    for (final table in _tables) {
      final type = _typeOf(table);
      for (final id in touched[type]!.difference(created[type]!)) {
        final row = before[table]![id];
        if (row == null) continue;
        final target = await _match(table, row, pulled[table]!.confirmed);
        if (target == null) {
          keep[table]!.add(id);
          continue;
        }
        final cloud = await _rowById(table, target);
        final merged = Map<String, Object?>.from(row)
          ..remove('id')
          ..remove('created_at')
          ..remove('rental_no')
          ..remove('registration_norm');
        if (table == 'rentals') {
          for (final (column, parent) in _rentalParents) {
            final ref = row[column] as String?;
            if (ref != null) {
              merged[column] =
                  await resolveOrKeep(parent, ref) ?? cloud?[column];
            }
          }
        }
        merged['version'] = ((cloud?['version'] as int?) ?? 0) + 1;
        merged['updated_at'] = DateTime.now().toUtc().toIso8601String();
        await db.update(table, merged, where: 'id = ?', whereArgs: [target]);
        twin[table]![id] = target;
      }
    }

    // 2. Rentals created here -> point at cloud customers/vehicles. One the
    //    server does not hold yet also gives up any number it carries: that
    //    number was never confirmed (pre-cloud stand-in, or allocated but
    //    then refused), and the server issues the real one on push. A
    //    rental the server already stores keeps its number, untouched.
    for (final id in created['rental']!) {
      final row = await _rowById('rentals', id);
      if (row == null) continue;
      final updates = <String, Object?>{};
      if (!pulled['rentals']!.confirmed.contains(id) &&
          row['rental_no'] != null) {
        updates['rental_no'] = null;
      }
      for (final (column, parent) in _rentalParents) {
        final ref = row[column] as String?;
        if (ref == null) continue;
        final target = await resolveOrKeep(parent, ref);
        if (target != ref) updates[column] = target;
      }
      if (updates.isNotEmpty) {
        await db.update('rentals', updates, where: 'id = ?', whereArgs: [id]);
      }
    }

    // 3. Photos follow their rental to its cloud id.
    for (final id in touched['attachment']!) {
      final row = await _rowById('attachments', id);
      if (row == null) continue;
      final rentalId = row['entity_id'] as String;
      final target = await resolveOrKeep('rentals', rentalId);
      if (target != null && target != rentalId) {
        await db.update(
          'attachments',
          {'entity_id': target},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }

    // 4. Drop the device's private seeded copies that now have a cloud twin.
    for (final table in _tables) {
      await _dropExcept(table, {...pulled[table]!.confirmed, ...keep[table]!});
    }

    // 5. Re-queue in dependency order so parents reach the server first.
    for (final table in _tables) {
      for (final id in keep[table]!) {
        await _outbox.enqueue(
          db,
          entityType: _typeOf(table),
          entityId: id,
          operation: 'insert',
        );
      }
      for (final id in twin[table]!.values) {
        await _outbox.enqueue(
          db,
          entityType: _typeOf(table),
          entityId: id,
          operation: 'update',
        );
      }
    }
    for (final id in touched['attachment']!) {
      await _outbox.enqueue(
        db,
        entityType: 'attachment',
        entityId: id,
        operation: 'insert',
      );
    }

    await db.insert(
      'app_meta',
      {'key': _hydratedKey, 'value': startedAt},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static const _tables = ['customers', 'vehicles', 'rentals'];
  static const _rentalParents = [
    ('customer_id', 'customers'),
    ('vehicle_id', 'vehicles'),
  ];

  /// Entity ids by type that have ever been through the outbox -- i.e.
  /// everything the owner created or edited on this device.
  Future<Map<String, Set<String>>> _touchedIds() => _queueIds();

  Future<Map<String, Set<String>>> _createdIds() =>
      _queueIds(where: "operation = 'insert'");

  Future<Map<String, Set<String>>> _queueIds({String? where}) async {
    final rows = await db.query(
      'sync_queue',
      columns: ['entity_type', 'entity_id'],
      where: where,
    );
    final result = {
      'customer': <String>{},
      'vehicle': <String>{},
      'rental': <String>{},
      'attachment': <String>{},
    };
    for (final r in rows) {
      result[r['entity_type']]?.add(r['entity_id'] as String);
    }
    return result;
  }

  Future<bool> _createdLocally(String entityType, String id) async {
    final rows = await db.query(
      'sync_queue',
      columns: ['id'],
      where: "entity_type = ? AND entity_id = ? AND operation = 'insert'",
      whereArgs: [entityType, id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The cloud twin of a seeded row among the rows just pulled: customers
  /// by normalized phone, then CNIC (never by name); vehicles by normalized
  /// registration; rentals by rental number.
  Future<String?> _match(
    String table,
    Map<String, Object?> row,
    Set<String> pulled,
  ) async {
    if (pulled.isEmpty) return null;
    final String where;
    final List<Object?> args;
    switch (table) {
      case 'customers':
        final phone = row['phone_normalized'] as String?;
        final cnic = row['cnic_normalized'] as String?;
        if (phone == null && cnic == null) return null;
        where = '((? IS NOT NULL AND phone_normalized = ?) OR '
            '(? IS NOT NULL AND cnic_normalized = ?))';
        args = [phone, phone, cnic, cnic];
      case 'vehicles':
        final norm = row['registration_norm'];
        if (norm == null) return null;
        where = 'registration_norm = ?';
        args = [norm];
      default:
        final rentalNo = row['rental_no'];
        if (rentalNo == null) return null;
        where = 'rental_no = ?';
        args = [rentalNo];
    }
    final placeholders = List.filled(pulled.length, '?').join(',');
    final rows = await db.query(
      table,
      columns: ['id'],
      where: 'id IN ($placeholders) AND $where',
      whereArgs: [...pulled, ...args],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<void> _dropExcept(String table, Set<String> survivors) async {
    if (survivors.isEmpty) {
      await db.delete(table);
      return;
    }
    await db.delete(
      table,
      where: 'id NOT IN (${List.filled(survivors.length, '?').join(',')})',
      whereArgs: survivors.toList(),
    );
  }

  Future<Map<String, Object?>?> _rowById(String table, String id) async {
    final rows = await db.query(table, where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  String _typeOf(String table) => switch (table) {
        'customers' => 'customer',
        'vehicles' => 'vehicle',
        'rentals' => 'rental',
        _ => 'attachment',
      };

  // ---- watermark -----------------------------------------------------------

  // ---- watermarks ------------------------------------------------------------

  static const _syncedTables = [
    'customers',
    'vehicles',
    'rentals',
    'attachments'
  ];

  // ---- dataset generation ----------------------------------------------------

  /// The cloud stamps each owner's dataset with a generation id, renewed
  /// whenever the dataset is replaced wholesale (a bulk load, a reset).
  /// A device whose local copy belongs to another generation -- or came
  /// from another account or another project -- lets that copy go and
  /// downloads the current dataset, so no device can ever push stale rows
  /// into a fresh one. A device meeting its first generation adopts it and
  /// hydrates as usual, merging anything it already holds.
  Future<void> _adoptGeneration() async {
    final rows = await client.from('dataset_generation').select('generation');
    String remote;
    if (rows.isEmpty) {
      final inserted = await client
          .from('dataset_generation')
          .insert(<String, Object?>{})
          .select('generation')
          .single();
      remote = inserted['generation'] as String;
    } else {
      remote = rows.first['generation'] as String;
    }
    final local = await _meta(_generationKey);
    if (local == remote) return;
    if (local != null || await isHydrated(db)) {
      await _releaseLocalDataset();
    }
    await _setMeta(_generationKey, remote);
  }

  /// Empties the synced tables, the outbox, conflict records and the sync
  /// bookkeeping, leaving device-only preferences (recent searches, the
  /// biometric switch) alone. The next pass hydrates from scratch.
  Future<void> _releaseLocalDataset() async {
    await db.transaction((txn) async {
      for (final table in [
        'sync_queue',
        'sync_conflicts',
        'attachments',
        'rentals',
        'customers',
        'vehicles',
      ]) {
        await txn.delete(table);
      }
      await txn.delete(
        'app_meta',
        where: 'key = ? OR key LIKE ?',
        whereArgs: [_hydratedKey, '$_watermarkPrefix%'],
      );
    });
  }

  Future<String?> _meta(String key) async {
    final rows = await db.query('app_meta', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _setMeta(String key, String value) => db.insert(
        'app_meta',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<String> _watermark(String table) async {
    final rows = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: ['$_watermarkPrefix$table'],
    );
    return rows.isEmpty ? _epoch : rows.first['value'] as String;
  }

  Future<void> _setWatermark(String table, String iso) => db.insert(
        'app_meta',
        {'key': '$_watermarkPrefix$table', 'value': iso},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Forces the next pull to re-read everything (after a restore, or on
  /// hydration). Applying is idempotent, so this is always safe.
  Future<void> _resetWatermarks() async {
    await db.delete(
      'app_meta',
      where: 'key LIKE ?',
      whereArgs: ['$_watermarkPrefix%'],
    );
  }

  /// Public form of [_resetWatermarks] for the restore flow.
  Future<void> forceFullPull() => _resetWatermarks();

  // ---- helpers ---------------------------------------------------------------

  int _order(String entityType) => switch (entityType) {
        'customer' => 0,
        'vehicle' => 1,
        'rental' => 2,
        _ => 3,
      };

  String _tableOf(String entityType) => switch (entityType) {
        'customer' => 'customers',
        'vehicle' => 'vehicles',
        'rental' => 'rentals',
        _ => 'attachments',
      };

  Future<List<Map<String, Object?>>> _rowsByIds(
    String table,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final rows = await db.query(
      table,
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
    // Keep outbox order.
    final byId = {for (final r in rows) r['id'] as String: r};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!
    ];
  }

  Map<String, Object?> _toRemote(String table, Map<String, Object?> r) =>
      switch (table) {
        'customers' => _customerToRemote(r),
        'vehicles' => _vehicleToRemote(r),
        'rentals' => _rentalToRemote(r),
        _ => _attachmentToRemote(r),
      };

  /// Bytes can't go into the conflict log as-is.
  Map<String, Object?> _jsonSafe(Map<String, Object?> r) => {
        for (final e in r.entries)
          e.key: e.value is Uint8List
              ? '<${(e.value as Uint8List).length} bytes>'
              : e.value,
      };

  // ---- row shape: local -> remote -------------------------------------------

  Map<String, Object?> _customerToRemote(Map<String, Object?> r) => {
        'id': r['id'],
        'full_name': r['full_name'],
        'phone': r['phone'],
        'phone_normalized': r['phone_normalized'],
        'cnic': r['cnic'],
        'cnic_normalized': r['cnic_normalized'],
        'license_no': r['license_no'],
        'license_city': r['license_city'],
        'possible_duplicate': _asBool(r['possible_duplicate']),
        'is_deleted': _asBool(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };

  Map<String, Object?> _vehicleToRemote(Map<String, Object?> r) => {
        'id': r['id'],
        'registration_no': r['registration_no'],
        'registration_norm': r['registration_norm'],
        'chassis_no': r['chassis_no'],
        'engine_no': r['engine_no'],
        'company': r['company'],
        'model_name': r['model_name'],
        'trim': r['trim'],
        'horsepower': r['horsepower'],
        'color': r['color'],
        'reg_year': r['reg_year'],
        'insurance_due_on': r['insurance_due_on'],
        'in_fleet': r['in_fleet'] == null ? true : _asBool(r['in_fleet']),
        'is_deleted': _asBool(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };

  Map<String, Object?> _rentalToRemote(Map<String, Object?> r) => {
        'id': r['id'],
        'rental_no': r['rental_no'],
        'is_placeholder': _asBool(r['is_placeholder']),
        'customer_id': r['customer_id'],
        'vehicle_id': r['vehicle_id'],
        'start_date': r['start_date'],
        'start_time': r['start_time'],
        'end_date': r['end_date'],
        'end_time': r['end_time'],
        'book_days': r['book_days'],
        'amount': r['amount'],
        'balance': r['balance'],
        'status': r['status'],
        'remarks': r['remarks'],
        'ref_name': r['ref_name'],
        'ref_contact': r['ref_contact'],
        'ref_relation': r['ref_relation'],
        'is_deleted': _asBool(r['is_deleted']),
        'version': r['version'],
        'created_at': r['created_at'],
        'updated_at': r['updated_at'],
      };

  Map<String, Object?> _attachmentToRemote(Map<String, Object?> r) {
    final thumb = r['thumbnail'] as Uint8List?;
    return {
      'id': r['id'],
      'entity_type': r['entity_type'],
      'entity_id': r['entity_id'],
      'kind': r['kind'],
      'mime_type': r['mime_type'],
      'image_base64': base64Encode(r['image'] as Uint8List),
      'thumbnail_base64': thumb == null ? null : base64Encode(thumb),
      'is_deleted': _asBool(r['is_deleted']),
      'version': r['version'],
      'created_at': r['created_at'],
      'updated_at': r['updated_at'],
    };
  }
}

class _PushResult {
  final int pushed;
  final int failed;
  final int conflicts;
  final String? firstError;
  final List<String> notices;
  _PushResult(
    this.pushed,
    this.failed,
    this.conflicts,
    this.firstError,
    this.notices,
  );
}

/// See the doc comment on [CloudSyncEngine._pullTable] for what each set
/// means and why they must stay separate.
class _PullResult {
  final Set<String> written;
  final Set<String> confirmed;
  _PullResult(this.written, this.confirmed);
}

bool _asBool(Object? sqliteInt) => sqliteInt == 1;
int _asInt(Object? remoteBool) => remoteBool == true ? 1 : 0;
