import 'dart:io';

import 'package:burhan_rent_a_car/app_services.dart';
import 'package:burhan_rent_a_car/main.dart';
import 'package:burhan_rent_a_car/screens/library_screen.dart';
import 'package:burhan_rent_a_car/screens/search_screen.dart';
import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late Directory tempDir;
  late AppServices services;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('burhan_app_test_');
    services = await seededServices(tempDir);
  });

  tearDown(() async {
    await services.db.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(BurhanApp(services: services));
    await settle(tester);
  }

  testWidgets('home shows four tiles and the last rental number', (t) async {
    await pumpApp(t);

    expect(find.text('Burhan Rent-A-Car'), findsOneWidget);
    expect(find.text('New Rental'), findsOneWidget);
    for (final tile in ['Search', 'Library', 'Needs Attention', 'Last Rental']) {
      expect(find.text(tile), findsWidgets, reason: tile);
    }
    // The highest real number in the test data is 60; the rental lists
    // that used to follow the tiles are gone.
    expect(find.text('#60'), findsOneWidget);
    expect(find.text('ACTIVE / UNCLOSED RENTALS'), findsNothing);
    expect(find.text('RECENT RENTALS'), findsNothing);

    // All three top-level sections are reachable from the nav bar.
    final navBar = find.byType(NavigationBar);
    for (final label in ['Home', 'Search', 'Library']) {
      expect(
        find.descendant(of: navBar, matching: find.text(label)),
        findsOneWidget,
      );
    }
  });

  testWidgets('the Last Rental tile opens that rental', (t) async {
    await pumpApp(t);
    await tapAndSettle(t, find.text('#60'));
    expect(find.text('Rental'), findsOneWidget);
    expect(find.text('#60'), findsOneWidget);
  });

  testWidgets('library shows one card per distinct vehicle, not per rental',
      (t) async {
    await pumpApp(t);
    await goToTab(t, 'Library');

    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.text('Vehicle Inventory'), findsOneWidget);
    // 3 distinct vehicles across 55 rentals.
    expect(find.text('KHI-123'), findsOneWidget);
    expect(find.text('KHI-789'), findsOneWidget);
    expect(find.text('KHI-654'), findsOneWidget);
    expect(find.text('22 rentals'), findsOneWidget);
  });

  testWidgets('vehicle drill-down reaches customers and history', (t) async {
    await pumpApp(t);
    await goToTab(t, 'Library');
    await tapAndSettle(t, find.text('KHI-123'));

    expect(find.text('Vehicle Details'), findsOneWidget);
    // The detail sections sit below the vehicle's field list.
    await t.scrollUntilVisible(
      find.text('CUSTOMERS WHO RENTED THIS VEHICLE'),
      300,
    );
    await settle(t);
    expect(find.text('CUSTOMERS WHO RENTED THIS VEHICLE'), findsOneWidget);
    expect(find.text('Billa Khan'), findsWidgets);

    await t.scrollUntilVisible(find.text('COMPLETE RENTAL HISTORY'), 300);
    await settle(t);
    expect(find.text('COMPLETE RENTAL HISTORY'), findsOneWidget);
  });

  testWidgets('universal search finds a customer by partial name', (t) async {
    await pumpApp(t);
    await searchFor(t, 'Billa');

    expect(find.byType(SearchScreen), findsOneWidget);
    expect(find.text('Billa Khan'), findsOneWidget);
  });

  testWidgets('universal search finds an exact rental number', (t) async {
    await pumpApp(t);
    await searchFor(t, '23');

    expect(find.text('EXACT MATCH'), findsOneWidget);
    expect(find.text('Rental #23'), findsOneWidget);
  });

  testWidgets('a placeholder rental renders its own message', (t) async {
    await pumpApp(t);
    await searchFor(t, '4');
    await tapAndSettle(t, find.text('Rental #4'));

    expect(find.text('No previous record available'), findsOneWidget);
  });

  testWidgets('a rental created offline displays as Pending', (t) async {
    // Created through the same engine path the New Rental form uses.
    // Real database I/O must run outside the fake-async zone.
    await t.runAsync(() async {
      final billa = await services.db.query(
        'customers',
        where: 'full_name = ?',
        whereArgs: ['Billa Khan'],
      );
      final id = await services.engine.createPendingRental(
        services.db,
        customerId: billa.single['id'] as String,
        status: 'Open',
        startDate: '2026-09-14',
      );
      final row = await services.rentals.getById(services.db, id);
      expect(rentalDisplayNumber(row!), startsWith('Pending #'));
    });

    await pumpApp(t);
    // Home only ever shows the last *numbered* rental; the pending one is
    // listed under its customer.
    expect(find.text('#60'), findsOneWidget);
    await searchFor(t, 'Billa');
    await tapAndSettle(t, find.text('Billa Khan'));
    expect(find.textContaining('Pending #'), findsWidgets);
  });

  testWidgets('rental detail shows N/A for a missing field', (t) async {
    await pumpApp(t);
    // Rental #24 has a blank Remarks field in the source CSV.
    await searchFor(t, '24');
    await tapAndSettle(t, find.text('Rental #24'));

    await t.scrollUntilVisible(find.text('Remarks'), 200);
    await settle(t);
    expect(find.text('Remarks'), findsOneWidget);
    expect(find.text('N/A'), findsWidgets);
  });

  testWidgets('editing a rental never changes its number', (t) async {
    await pumpApp(t);
    await searchFor(t, '58');
    await tapAndSettle(t, find.text('Rental #58'));

    await t.scrollUntilVisible(find.text('Edit'), 300);
    await settle(t);
    await tapAndSettle(t, find.text('Edit'));

    expect(find.text('Edit Rental'), findsOneWidget);
    expect(
      find.text('Rental number is read-only and can never be changed.'),
      findsOneWidget,
    );
    // The number is displayed, not editable.
    expect(find.text('#58'), findsOneWidget);
  });
}
