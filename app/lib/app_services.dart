import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
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
  final UniversalSearchService search;
  final LocalSyncEngine engine;

  AppServices._(this.db)
      : customers = CustomerRepository(),
        vehicles = VehicleRepository(),
        rentals = RentalRepository(),
        search = UniversalSearchService(),
        engine = LocalSyncEngine();

  /// Opens the local database, seeding it from the bundled temporary CSV
  /// the first time so there is realistic data to develop against.
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
    await seedIfEmpty(db);
    return AppServices._(db);
  }

  /// Wraps an already-open database (used by widget tests, which supply an
  /// FFI-backed one).
  static AppServices forDatabase(Database db) => AppServices._(db);

  /// DEVELOPMENT SEEDING ONLY. Loads the temporary test CSV so the app has
  /// data to show before the real CSV exists. Delete this once the real
  /// historical import runs against the backend -- it is not a production
  /// code path, and it deliberately does nothing if any rental already
  /// exists, so it can never overwrite real records.
  static Future<void> seedIfEmpty(Database db) async {
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM rentals');
    if ((rows.first['c'] as int? ?? 0) > 0) return;

    final csv = await rootBundle.loadString(
      'assets/burhan_rent_a_car_temporary_test.csv',
    );
    await ImportPipeline(mapper: TestCsvMapper()).importCsvString(db, csv);
  }
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
  bool updateShouldNotify(AppScope oldWidget) =>
      oldWidget.services != services;
}
