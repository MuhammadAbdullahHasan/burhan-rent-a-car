import 'dart:io';
import 'dart:typed_data';

import 'package:burhan_rent_a_car/app_services.dart';
import 'package:burhan_rent_a_car/main.dart';
import 'package:burhan_rent_a_car/services/agreement_photo.dart';
import 'package:burhan_rent_a_car/widgets/rental_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'helpers.dart';

/// A real, decodable JPEG so Image.memory renders in tests.
Uint8List _jpeg({int width = 8, int height = 8}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 120, 40));
  return Uint8List.fromList(img.encodeJpg(image, quality: 60));
}

void main() {
  group('AgreementPhotoPicker.process', () {
    test('bounds a large photo and cuts a thumbnail', () async {
      final big = _jpeg(width: 2400, height: 1800);
      final photo = await AgreementPhotoPicker.process(big);

      expect(photo, isNotNull);
      final main = img.decodeImage(photo!.image)!;
      final thumb = img.decodeImage(photo.thumbnail)!;
      expect(main.width, 1600);
      expect(main.height, 1200);
      expect(thumb.width, 320);
      expect(thumb.height, 240);
      expect(photo.image.length, lessThan(big.length));
    });

    test('leaves an already-small photo at its size', () async {
      final photo = await AgreementPhotoPicker.process(_jpeg(width: 640, height: 480));
      final main = img.decodeImage(photo!.image)!;
      expect(main.width, 640);
      expect(main.height, 480);
    });

    test('returns null for bytes that are not an image', () async {
      expect(await AgreementPhotoPicker.process(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('agreement photo in the app', () {
    late Directory tempDir;
    late AppServices services;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('burhan_photo_ui_');
      services = await seededServices(tempDir);
    });

    tearDown(() async {
      await services.db.close();
      await tempDir.delete(recursive: true);
    });

    Future<void> pumpApp(WidgetTester t) async {
      await t.pumpWidget(BurhanApp(services: services));
      await settle(t);
    }

    Future<String> rentalId(int no) async =>
        (await services.rentals.findByRentalNo(services.db, no))!['id'] as String;

    testWidgets('rental detail invites a photo when none is attached',
        (t) async {
      await pumpApp(t);
      await searchFor(t, '23');
      await tapAndSettle(t, find.text('Rental #23'));

      await t.scrollUntilVisible(find.text('RENTAL AGREEMENT'), 300);
      await settle(t);
      expect(find.text('No agreement photo yet'), findsOneWidget);
      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Gallery'), findsOneWidget);
    });

    testWidgets('rental detail shows the attached photo', (t) async {
      await t.runAsync(() async {
        await services.engine.setRentalAgreementPhoto(
          services.db,
          rentalId: await rentalId(23),
          image: _jpeg(width: 64, height: 80),
          thumbnail: _jpeg(width: 16, height: 20),
        );
      });

      await pumpApp(t);
      await searchFor(t, '23');
      await tapAndSettle(t, find.text('Rental #23'));

      await t.scrollUntilVisible(find.text('RENTAL AGREEMENT'), 300);
      await settle(t);
      expect(find.text('No agreement photo yet'), findsNothing);
      expect(find.text('Tap to view full size, zoom, or share'), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets("customer history shows a thumbnail on rentals that have one",
        (t) async {
      await t.runAsync(() async {
        await services.engine.setRentalAgreementPhoto(
          services.db,
          rentalId: await rentalId(23),
          image: _jpeg(width: 64, height: 80),
          thumbnail: _jpeg(width: 16, height: 20),
        );
      });

      await pumpApp(t);
      await searchFor(t, 'Billa');
      await tapAndSettle(t, find.text('Billa Khan'));
      // History tiles show the badge form ("#23"), not the search-result
      // form ("Rental #23"). Rental #23 sits below the fold.
      await t.scrollUntilVisible(find.text('#23'), 300);
      await settle(t);

      final tileWithPhoto = find.ancestor(
        of: find.text('#23'),
        matching: find.byType(RentalTile),
      );
      final tileWithout = find.ancestor(
        of: find.text('#12'),
        matching: find.byType(RentalTile),
      );
      expect(
        find.descendant(of: tileWithPhoto, matching: find.byType(Image)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tileWithout, matching: find.byType(Image)),
        findsNothing,
      );
    });

    testWidgets('new rental form offers the photo; edit form does not',
        (t) async {
      await pumpApp(t);
      await tapAndSettle(t, find.text('New Rental'));
      await t.scrollUntilVisible(
        find.text('AGREEMENT PHOTO (OPTIONAL)'),
        300,
        scrollable: formScrollable(),
      );
      await settle(t);
      expect(find.text('AGREEMENT PHOTO (OPTIONAL)'), findsOneWidget);
      expect(find.text('Take photo'), findsOneWidget);
    });
  });
}
