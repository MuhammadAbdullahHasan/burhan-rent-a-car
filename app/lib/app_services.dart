import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';

import 'auth/biometric_service.dart';
import 'backup/cloud_backup.dart';
import 'sync/auto_sync_engine.dart';
import 'sync/cloud_sync_engine.dart';
import 'sync/sync_actions.dart';
import 'sync/sync_status.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// Everything the UI needs from the validated data layer, assembled once.
///
/// The data layer is used as-is: this class only opens the database with
/// Android's `sqflite` factory and hands the same repositories/engine the
/// tests already exercise to the screens. No query logic is reimplemented
/// here, and nothing about rental numbering is touched.
class AppServices {
  final Database db;
  final CustomerRepository customers;
  final VehicleRepository vehicles;
  final RentalRepository rentals;
  final AttachmentRepository attachments;
  final UniversalSearchService search;
  late final LocalSyncEngine engine;

  /// Signs the owner out. Null when there is no auth layer (widget tests
  /// inject services directly), in which case the UI hides the action.
  Future<void> Function()? signOut;

  /// Fingerprint/face preference, for the Home menu switch. Null without an
  /// auth layer.
  BiometricService? biometrics;

  /// The push/pull engine to Postgres. Null in widget tests (no auth/
  /// network layer); sync_actions.dart falls back to the local stand-in
  /// when this is null, so screens never need to check it themselves.
  CloudSyncEngine? cloudSync;

  /// Daily snapshots + manual restore; null without a cloud (tests).
  CloudBackup? cloudBackup;

  /// Bumped after any sync that changed local rows, so open screens can
  /// reload without the owner having to navigate away and back.
  final ValueNotifier<int> dataChanged = ValueNotifier<int>(0);

  /// What Home shows about sync: live / syncing / last success / problems.
  final ValueNotifier<SyncStatus> syncStatus =
      ValueNotifier<SyncStatus>(const SyncStatus());

  AppServices._(this.db)
      : customers = CustomerRepository(),
        vehicles = VehicleRepository(),
        rentals = RentalRepository(),
        attachments = AttachmentRepository(),
        search = UniversalSearchService() {
    engine = AutoSyncEngine(onLocalChange: _onLocalChange);
  }

  /// Every local write lands here: the pending count on Home updates at
  /// once and the change is pushed within a second when a cloud is wired.
  void _onLocalChange() {
    pendingChanges().then((n) {
      syncStatus.value = syncStatus.value.copyWith(pending: n);
    });
    cloudSync?.requestSync();
  }

  Future<int> pendingChanges() => Outbox().pendingCount(db);

  /// Runs a pass now and reports it through [syncStatus]; the same call
  /// "Sync Now" makes.
  Future<String> syncNow() => runSync(this);

  /// Opens the local database. It starts empty on a new device and is
  /// filled by the first cloud sync (see CloudSyncEngine); nothing is ever
  /// seeded locally, so every device works from the same records.
  ///
  /// The storage backend differs per platform, but nothing above this line
  /// does: Android uses `sqflite`, and the browser (used for local
  /// development on a Mac without Xcode) uses the same SQLite compiled to
  /// WASM, backed by IndexedDB. The schema, repositories, numbering and
  /// search are identical either way.
  static Future<AppServices> bootstrap() async {
    final Database db;
    if (kIsWeb) {
      db = await openAppDatabase(
        databaseFactoryFfiWeb,
        'burhan_rent_a_car.db',
      );
    } else {
      final path = p.join(
        await sqflite.getDatabasesPath(),
        'burhan_rent_a_car.db',
      );
      db = await openAppDatabase(sqflite.databaseFactory, path);
    }
    return AppServices._(db);
  }

  /// Wraps an already-open database (used by widget tests, which supply an
  /// FFI-backed one).
  static AppServices forDatabase(Database db) => AppServices._(db);
}

/// Simple dependency lookup. A single owner on a single device doesn't need
/// a state-management framework here -- screens read services from context
/// and reload their own futures after a mutation returns.
class AppScope extends InheritedWidget {
  final AppServices services;

  const AppScope({
    super.key,
    required this.services,
    required super.child,
  });

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing from the widget tree');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => oldWidget.services != services;
}
