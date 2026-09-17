import 'dart:io';

import 'package:burhan_rent_a_car/app_services.dart';
import 'package:burhan_rent_a_car/main.dart';
import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Widget tests run against a real (FFI-backed) database seeded from the
/// same temporary CSV the app bundles, so screens are exercised against
/// real rows rather than mocks.
Future<AppServices> seededServices(Directory dir) async {
  sqfliteFfiInit();
  final db = await openAppDatabase(
    databaseFactoryFfi,
    p.join(dir.path, 'widget_test.db'),
  );
  final csv = await File(
    '../test_data/burhan_rent_a_car_temporary_test.csv',
  ).readAsString();
  await ImportPipeline(mapper: TestCsvMapper()).importCsvString(db, csv);
  return AppServices.forDatabase(db);
}

/// `pumpAndSettle` can't be used here: the screens await real SQLite file
/// I/O, which never completes inside the fake-async zone a widget test runs
/// in. Each round lets the real event loop drain (`runAsync`) and then
/// advances the fake clock so route transitions and debounce timers fire.
Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await settle(tester);
}

/// Starts the app on a fresh database. The test data has a vehicle whose
/// insurance is due within the month, so Home greets the first launch of
/// the day with the insurance alert; that is put off so the test can get
/// at the screen underneath. Pass [keepInsuranceAlert] to test the alert.
Future<void> pumpApp(
  WidgetTester tester,
  AppServices services, {
  bool keepInsuranceAlert = false,
}) async {
  await tester.pumpWidget(BurhanApp(services: services));
  await settle(tester);
  if (keepInsuranceAlert) return;
  final later = find.widgetWithText(TextButton, 'Later');
  if (later.evaluate().isNotEmpty) await tapAndSettle(tester, later);
}

/// "Search" and "Library" also appear as quick-nav card labels on Home, so
/// tab switches must target the bottom navigation bar specifically.
Future<void> goToTab(WidgetTester tester, String label) async {
  await tapAndSettle(
    tester,
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    ),
  );
}

/// Switches to the Search tab if needed and types into one category
/// field. Defaults to the rental-number field for an all-digit query and
/// the customer-name field otherwise; pass [field] for the others.
Future<void> searchFor(
  WidgetTester tester,
  String query, {
  String? field,
}) async {
  final bar = find.byKey(const Key('search_field'));
  if (bar.evaluate().isEmpty) {
    await goToTab(tester, 'Search');
  }
  // Older call sites name the category the way the previous layout
  // labelled its fields; map those onto the chips.
  final chip = switch (field) {
    'All' => 'All',
    'Rental number' || 'Rental #' => 'Rental #',
    'Customer name' || 'Customer' => 'Customer',
    'Mobile number' || 'Mobile' => 'Mobile',
    'CNIC' => 'CNIC',
    'Vehicle registration' || 'Vehicle Reg' => 'Vehicle Reg',
    _ => RegExp(r'^\d+$').hasMatch(query.trim()) ? 'Rental #' : 'Customer',
  };
  await tapAndSettle(
    tester,
    find.descendant(of: find.byType(ChoiceChip), matching: find.text(chip)),
  );
  await tester.enterText(bar, query);
  await settle(tester);
}

/// The scrollable belonging to the form currently on top. Routes underneath
/// keep their own lists in the tree, so an unqualified `byType(Scrollable)`
/// matches several and scrollUntilVisible refuses to guess.
Finder formScrollable() {
  final inForm = find.descendant(
    of: find.byType(Form),
    matching: find.byType(Scrollable),
  );
  return inForm.evaluate().isNotEmpty
      ? inForm.first
      : find.byType(Scrollable).last;
}

/// Scrolls a form field into view before typing into it. Long forms are
/// lazily built, so a field below the fold doesn't exist in the tree yet.
Future<void> enterFieldText(
  WidgetTester tester,
  String label,
  String text,
) async {
  final finder = find.widgetWithText(TextFormField, label);
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200, scrollable: formScrollable());
    await settle(tester);
  }
  await tester.ensureVisible(finder);
  await settle(tester);
  await tester.enterText(finder, text);
  await settle(tester);
}

/// Taps a button that may be below the fold.
Future<void> tapButton(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200, scrollable: formScrollable());
    await settle(tester);
  }
  await tapAndSettle(tester, finder);
}
