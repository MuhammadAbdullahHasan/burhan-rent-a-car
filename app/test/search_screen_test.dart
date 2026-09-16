import 'dart:io';

import 'package:burhan_rent_a_car/app_services.dart';
import 'package:burhan_rent_a_car/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// One search bar; the selected chip decides which category the text
/// searches. Recent searches are kept on the device.
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

  testWidgets('shows one search bar and a chip per category', (t) async {
    await pumpSearch(t);
    expect(find.byKey(const Key('search_field')), findsOneWidget);
    for (final chip in [
      'Rental #',
      'Customer',
      'Mobile',
      'CNIC',
      'Vehicle Reg'
    ]) {
      expect(
        find.descendant(of: find.byType(ChoiceChip), matching: find.text(chip)),
        findsOneWidget,
      );
    }
    expect(find.text('No Recent Searches\nEnter a rental number above'),
        findsOneWidget);
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
    expect(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.textContaining('Rental #'),
      ),
      findsNothing,
    );
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

  testWidgets('switching the chip re-runs the same text in the new category',
      (t) async {
    await pumpSearch(t);
    await searchFor(t, '1', field: 'Rental #');
    expect(find.text('Rental #1'), findsOneWidget);
    expect(find.text('Billa Khan'), findsNothing);

    // Same "1" as mobile digits: the rental is gone, phone matches appear.
    await tapAndSettle(
      t,
      find.descendant(
          of: find.byType(ChoiceChip), matching: find.text('Mobile')),
    );
    expect(find.text('Rental #1'), findsNothing);
    expect(find.text('Billa Khan'), findsOneWidget);
  });

  testWidgets('submitted searches are remembered and can be re-run', (t) async {
    await pumpSearch(t);
    await searchFor(t, 'Billa', field: 'Customer');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);

    // Clearing the bar shows the history; tapping an entry re-runs it.
    await tapAndSettle(t, find.byTooltip('Clear'));
    expect(find.text('RECENT SEARCHES'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Billa'), findsOneWidget);
    await tapAndSettle(t, find.widgetWithText(ListTile, 'Billa'));
    expect(find.text('Billa Khan'), findsOneWidget);
  });

  testWidgets('no match shows a category-specific message', (t) async {
    await pumpSearch(t);
    await searchFor(t, 'Zzzz', field: 'Customer name');
    expect(find.textContaining('No customer name matched'), findsOneWidget);
  });
}
