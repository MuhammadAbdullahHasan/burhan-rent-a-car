import 'package:burhan_rent_a_car/widgets/form_fields.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bookedDaysBetween', () {
    test('counts the nights between start and return', () {
      expect(bookedDaysBetween('2026-01-08', '2026-01-10'), 2);
      expect(bookedDaysBetween('2026-01-11', '2026-01-14'), 3);
      expect(bookedDaysBetween('2026-01-05', '2026-01-06'), 1);
    });

    test('a same-day return is still one day', () {
      expect(bookedDaysBetween('2026-01-05', '2026-01-05'), 1);
    });

    test('is null until both dates are valid and in order', () {
      expect(bookedDaysBetween('2026-01-05', null), isNull);
      expect(bookedDaysBetween('', '2026-01-05'), isNull);
      expect(bookedDaysBetween('2026-01-05', 'soon'), isNull);
      expect(bookedDaysBetween('2026-01-10', '2026-01-05'), isNull);
    });

    test('crosses month and year boundaries', () {
      expect(bookedDaysBetween('2026-12-30', '2027-01-02'), 3);
    });
  });
}
