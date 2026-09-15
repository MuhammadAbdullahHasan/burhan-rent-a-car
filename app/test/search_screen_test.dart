import 'dart:io';

import 'package:burhan_rent_a_car/app_services.dart';
import 'package:burhan_rent_a_car/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Categorised search: one field per identifier, each searching only its
/// own category.
void main() {
  late Directory tempDir;
  late AppServices services;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('burhan_search_ui_');
    services = await seededServices(tempDir);
  });

  tearDown(() async {
    await services.db.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpSearch(WidgetTester t) async {
    await t.pumpWidget(BurhanApp(services: services));
    await settle(t);
    await goToTab(t, 'Search');
  }

  testWidgets('shows one field per category', (t) async {
    await pumpSearch(t);
    for (final label in [
      'Rental number',
      'Customer name',
      'Mobile number',
      'CNIC',
      'Vehicle registration',
    ]) {
      expect(find.widgetWithText(TextField, label), findsOneWidget);
    }
  });

  testWidgets('rental number field finds only that rental', (t) async {
    await pumpSearch(t);
    await searchFor(t, '23', field: 'Rental number');
    expect(find.text('EXACT MATCH'), findsOneWidget);
    expect(find.text('Rental #23'), findsOneWidget);
    expect(find.text('Billa Khan'), findsNothing);
  });

  testWidgets('mobile number field finds the customer, not a rental',
      (t) async {
    await pumpSearch(t);
    // "1" would be rental #1 in the number field; here it is phone digits.
    await searchFor(t, '03001234567', field: 'Mobile number');
    expect(find.text('Billa Khan'), findsOneWidget);
    expect(find.textContaining('Rental #'), findsNothing);
  });

  testWidgets('customer name field matches partial names', (t) async {
    await pumpSearch(t);
    await searchFor(t, 'Khan', field: 'Customer name');
    expect(find.text('Billa Khan'), findsOneWidget);
    expect(find.text('Fahad Khan'), findsOneWidget);
  });

  testWidgets('CNIC field finds the customer', (t) async {
    await pumpSearch(t);
    await searchFor(t, '42201-2345678-2', field: 'CNIC');
    expect(find.text('Ahmed Raza'), findsOneWidget);
  });

  testWidgets('vehicle field finds the vehicle regardless of separators',
      (t) async {
    await pumpSearch(t);
    await searchFor(t, 'khi 789', field: 'Vehicle registration');
    expect(find.text('KHI-789'), findsOneWidget);
    expect(find.text('EXACT MATCH'), findsOneWidget);
  });

  testWidgets('typing in a second field clears the first', (t) async {
    await pumpSearch(t);
    await searchFor(t, '23', field: 'Rental number');
    expect(find.text('Rental #23'), findsOneWidget);

    await searchFor(t, 'Billa', field: 'Customer name');
    expect(find.text('Billa Khan'), findsOneWidget);
    expect(find.text('Rental #23'), findsNothing);
    expect(
      t.widget<TextField>(find.widgetWithText(TextField, 'Rental number'))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets('no match shows a category-specific message', (t) async {
    await pumpSearch(t);
    await searchFor(t, 'Zzzz', field: 'Customer name');
    expect(find.textContaining('No customer name matched'), findsOneWidget);
  });
}
