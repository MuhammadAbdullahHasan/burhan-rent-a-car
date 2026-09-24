import 'dart:io';

import 'package:burhan_rent_a_car/app_services.dart';
import 'package:burhan_rent_a_car/screens/library_screen.dart';
import 'package:burhan_rent_a_car/screens/search_screen.dart';
import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart' as helpers;
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

  Future<void> pumpApp(WidgetTester tester) => helpers.pumpApp(tester, services);

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

  testWidgets('insurance due within a month is announced on every launch',
      (t) async {
    // KHI-654's insurance is due 2026-09-30 in the test data; the other
    // two vehicles are due in November and December.
    await helpers.pumpApp(t, services, keepInsuranceAlert: true);
    final alert = find.widgetWithText(AlertDialog, 'Insurance due');
    expect(alert, findsOneWidget);
    expect(find.text('KHI-654'), findsOneWidget);
    expect(find.text('KHI-123'), findsNothing);
    await tapAndSettle(t, find.text('Later'));
    expect(alert, findsNothing);

    // "Later" is no snooze: the next launch brings it straight back...
    await t.pumpWidget(const SizedBox());
    await helpers.pumpApp(t, services, keepInsuranceAlert: true);
    expect(alert, findsOneWidget);

    // ...and "Done" goes to the vehicle's form to move the date on.
    await tapAndSettle(t, find.text('Done'));
    expect(find.text('Edit Vehicle'), findsOneWidget);
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

  testWidgets('vehicle drill-down reaches its customers', (t) async {
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

    // The list is a dropdown: closed until the card is tapped.
    expect(find.text('Billa Khan'), findsNothing);
    await tapAndSettle(t, find.text('CUSTOMERS WHO RENTED THIS VEHICLE'));
    expect(find.text('Billa Khan'), findsWidgets);

    // The vehicle's own rental list was dropped: its rentals are reached
    // through the customers above, one drill-down deeper.
    expect(find.text('COMPLETE RENTAL HISTORY'), findsNothing);
  });

  testWidgets('a vehicle can be deleted: confirmed, gone from the Library, '
      'its rentals keep their history', (t) async {
    await pumpApp(t);
    await goToTab(t, 'Library');
    await tapAndSettle(t, find.text('KHI-123'));

    await t.scrollUntilVisible(find.text('Delete vehicle'), 300);
    await settle(t);
    await tapAndSettle(t, find.text('Delete vehicle'));
    expect(find.text('Delete KHI-123?'), findsOneWidget);
    expect(find.textContaining('keep their history'), findsOneWidget);

    // Backing out changes nothing.
    await tapAndSettle(t, find.text('Cancel'));
    expect(find.text('Vehicle Details'), findsOneWidget);

    await tapAndSettle(t, find.text('Delete vehicle'));
    await tapAndSettle(t, find.widgetWithText(FilledButton, 'Delete'));

    // Back in the Library, without it.
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.text('KHI-123'), findsNothing);

    // Its rentals are untouched: still findable, still opening.
    await searchFor(t, '5');
    expect(find.text('Rental #5'), findsOneWidget);
    await tapAndSettle(t, find.text('Rental #5'));
    expect(find.text('Rental'), findsWidgets);
    expect(find.text('#5'), findsWidgets);
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
