import 'dart:io';

import 'package:burhan_rent_a_car/app_services.dart';
import 'package:burhan_rent_a_car/main.dart';
import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Form-level behaviour: validation, read-only rental numbers, Pending #,
/// and the guarantee that numbers are never reused.
void main() {
  late Directory tempDir;
  late AppServices services;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('burhan_forms_test_');
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

  Future<void> openNewRentalForm(WidgetTester t) async {
    await pumpApp(t);
    await tapAndSettle(t, find.text('New Rental'));
    expect(find.text('Create Rental'), findsOneWidget);
  }

  group('New Rental form', () {
    testWidgets('explains that a new rental is Pending until sync', (t) async {
      await openNewRentalForm(t);
      expect(
        find.textContaining('Saved offline as "Pending"'),
        findsOneWidget,
      );
      expect(find.textContaining('never reused'), findsOneWidget);
    });

    testWidgets('refuses to save without a customer and vehicle', (t) async {
      await openNewRentalForm(t);
      await tapButton(t, 'Create Rental');

      expect(
        find.text('A rental needs both a customer and a vehicle.'),
        findsOneWidget,
      );
      // Nothing was written.
      await t.runAsync(() async {
        final pending = await services.db.query(
          'rentals',
          where: 'rental_no IS NULL',
        );
        expect(pending, isEmpty);
      });
    });

    testWidgets('rejects a negative amount', (t) async {
      await openNewRentalForm(t);
      await enterFieldText(t, 'Amount', '-5');
      await tapButton(t, 'Create Rental');
      expect(find.text('Amount cannot be negative'), findsOneWidget);
    });

    testWidgets('rejects a non-numeric amount', (t) async {
      await openNewRentalForm(t);
      await enterFieldText(t, 'Amount', 'abc');
      await tapButton(t, 'Create Rental');
      expect(find.text('Amount must be a number'), findsOneWidget);
    });

    testWidgets('rejects zero booked days', (t) async {
      await openNewRentalForm(t);
      await enterFieldText(t, 'Booked days', '0');
      await tapButton(t, 'Create Rental');
      expect(find.text('Booked days must be at least 1'), findsOneWidget);
    });

    testWidgets('saves as Pending # once customer and vehicle are chosen',
        (t) async {
      await openNewRentalForm(t);

      await tapAndSettle(t, find.text('Tap to select').first);
      await tapAndSettle(t, find.text('Billa Khan').first);

      await tapAndSettle(t, find.text('Tap to select').first);
      await tapAndSettle(t, find.text('KHI-123').first);

      await enterFieldText(t, 'Amount', '5000');
      await tapButton(t, 'Create Rental');

      await t.runAsync(() async {
        final pending = await services.db.query(
          'rentals',
          where: 'rental_no IS NULL AND is_deleted = 0',
        );
        expect(pending, hasLength(1));
        expect(pending.single['amount'], 5000.0);
        expect(rentalDisplayNumber(pending.single), startsWith('Pending #'));
      });
    });
  });

  group('Edit Rental form', () {
    testWidgets('shows the rental number as read-only and never edits it',
        (t) async {
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
      expect(find.text('#58'), findsOneWidget);
      // There is no editable field holding the number.
      expect(find.widgetWithText(TextFormField, '58'), findsNothing);
    });

    testWidgets('saving an edit keeps the same number and adds no row',
        (t) async {
      late int rentalsBefore;
      await t.runAsync(() async {
        rentalsBefore = (await services.db.query('rentals')).length;
      });

      await pumpApp(t);
      await searchFor(t, '58');
      await tapAndSettle(t, find.text('Rental #58'));
      await t.scrollUntilVisible(find.text('Edit'), 300);
      await settle(t);
      await tapAndSettle(t, find.text('Edit'));

      await enterFieldText(t, 'Amount', '7777');
      await tapButton(t, 'Save Changes');

      await t.runAsync(() async {
        final rows = await services.db.query(
          'rentals',
          where: 'rental_no = ?',
          whereArgs: [58],
        );
        expect(rows, hasLength(1));
        expect(rows.single['amount'], 7777.0);
        final after = (await services.db.query('rentals')).length;
        expect(after, rentalsBefore);
      });
    });

    testWidgets('date fields are tap-to-pick, never free-typed', (t) async {
      await pumpApp(t);
      await searchFor(t, '58');
      await tapAndSettle(t, find.text('Rental #58'));
      await t.scrollUntilVisible(find.text('Edit'), 300);
      await settle(t);
      await tapAndSettle(t, find.text('Edit'));

      // A read-only field can't accept a malformed date by typing.
      final startField = find.widgetWithText(TextFormField, 'Start date *');
      await t.ensureVisible(startField);
      await settle(t);
      expect(t.widget<TextField>(
        find.descendant(of: startField, matching: find.byType(TextField)),
      ).readOnly, isTrue);
    });
  });

  group('Customer form', () {
    testWidgets('requires a name', (t) async {
      await pumpApp(t);
      await goToTab(t, 'Search');
      await searchFor(t, 'Billa');
      await tapAndSettle(t, find.text('Billa Khan'));
      await tapAndSettle(t, find.text('Edit'));

      await enterFieldText(t, 'Full name *', '');
      await tapButton(t, 'Save Customer');

      expect(find.text('Full name is required'), findsOneWidget);
    });

    testWidgets('validates CNIC length', (t) async {
      await pumpApp(t);
      await searchFor(t, 'Billa');
      await tapAndSettle(t, find.text('Billa Khan'));
      await tapAndSettle(t, find.text('Edit'));

      await enterFieldText(t, 'CNIC', '123');
      await tapButton(t, 'Save Customer');

      expect(find.text('CNIC should be 13 digits'), findsOneWidget);
    });

    testWidgets('editing a customer does not touch their rentals', (t) async {
      await pumpApp(t);
      await searchFor(t, 'Billa');
      await tapAndSettle(t, find.text('Billa Khan'));
      await tapAndSettle(t, find.text('Edit'));

      await enterFieldText(t, 'Full name *', 'Billa Khan Sr');
      await tapButton(t, 'Save Customer');

      await t.runAsync(() async {
        final customer = (await services.db.query(
          'customers',
          where: 'phone_normalized = ?',
          whereArgs: ['03001234567'],
        )).single;
        expect(customer['full_name'], 'Billa Khan Sr');
        final rentals = await services.rentals.findByCustomerId(
          services.db,
          customer['id'] as String,
        );
        // Still the same nine rentals, numbers untouched.
        expect(rentals, hasLength(9));
        expect(
          rentals.map((r) => r['rental_no']).toSet(),
          {1, 12, 13, 23, 27, 34, 43, 45, 56},
        );
      });
    });
  });

  group('Vehicle form', () {
    testWidgets('requires a registration number', (t) async {
      await pumpApp(t);
      await goToTab(t, 'Library');
      await tapAndSettle(t, find.byIcon(Icons.add));

      await tapButton(t, 'Save Vehicle');
      expect(find.text('Registration number is required'), findsOneWidget);
    });

    testWidgets('rejects a duplicate registration', (t) async {
      await pumpApp(t);
      await goToTab(t, 'Library');
      await tapAndSettle(t, find.byIcon(Icons.add));

      await enterFieldText(t, 'Registration number *', 'KHI-123');
      await tapButton(t, 'Save Vehicle');

      expect(
        find.textContaining('already in the inventory'),
        findsOneWidget,
      );
      await t.runAsync(() async {
        final rows = await services.db.query(
          'vehicles',
          where: 'registration_norm = ?',
          whereArgs: ['KHI123'],
        );
        expect(rows, hasLength(1));
      });
    });

    testWidgets('rejects an implausible registration year', (t) async {
      await pumpApp(t);
      await goToTab(t, 'Library');
      await tapAndSettle(t, find.byIcon(Icons.add));

      await enterFieldText(t, 'Registration number *', 'NEW-001');
      await enterFieldText(t, 'Registration year', '1820');
      await tapButton(t, 'Save Vehicle');
      expect(find.text('Enter a valid year'), findsOneWidget);
    });

    testWidgets('adds a new vehicle to the Library', (t) async {
      await pumpApp(t);
      await goToTab(t, 'Library');
      await tapAndSettle(t, find.byIcon(Icons.add));

      await enterFieldText(t, 'Registration number *', 'LHR-777');
      await enterFieldText(t, 'Company', 'Suzuki');
      await tapButton(t, 'Save Vehicle');

      expect(find.text('LHR-777'), findsOneWidget);
      expect(find.text('0 rentals'), findsOneWidget);
    });
  });

  group('rental numbering rules hold through the UI', () {
    testWidgets('next assigned number is 61 and skips every historical gap',
        (t) async {
      await t.runAsync(() async {
        // Highest real historical rental is #60.
        final maxRow = await services.db.rawQuery(
          'SELECT MAX(rental_no) AS m FROM rentals WHERE is_placeholder = 0',
        );
        expect(maxRow.first['m'], 60);

        // The five gaps exist as placeholders and stay placeholders.
        for (final gap in [4, 11, 25, 40, 55]) {
          final row = await services.rentals.findByRentalNo(services.db, gap);
          expect(row!['is_placeholder'], 1);
        }

        // Create and sync three rentals: 61, 62, 63 -- no gap is reused.
        final assigned = <Object?>[];
        for (var i = 0; i < 3; i++) {
          final id = await services.engine.createPendingRental(
            services.db,
            status: 'Open',
          );
          await services.engine.syncPending(services.db);
          final row = await services.rentals.getById(services.db, id);
          assigned.add(row!['rental_no']);
        }
        expect(assigned, [61, 62, 63]);

        // Gaps are still placeholders, untouched.
        for (final gap in [4, 11, 25, 40, 55]) {
          final row = await services.rentals.findByRentalNo(services.db, gap);
          expect(row!['is_placeholder'], 1);
          expect(row['customer_id'], isNull);
        }
      });
    });
  });
}
