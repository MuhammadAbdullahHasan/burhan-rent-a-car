import 'package:burhan_rent_a_car/widgets/form_fields.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure validation rules, tested directly rather than through the widgets.
void main() {
  group('Validate.dateOrder', () {
    test('rejects a return date before the start date', () {
      expect(
        Validate.dateOrder('2026-01-01', '2026-06-10'),
        'Return date is before the start date',
      );
    });

    test('accepts same-day and later return dates', () {
      expect(Validate.dateOrder('2026-06-10', '2026-06-10'), isNull);
      expect(Validate.dateOrder('2026-06-12', '2026-06-10'), isNull);
    });

    test('ignores incomplete input', () {
      expect(Validate.dateOrder(null, '2026-06-10'), isNull);
      expect(Validate.dateOrder('2026-06-10', ''), isNull);
    });
  });

  group('Validate.amount', () {
    test('rejects negatives and non-numbers, allows blank', () {
      expect(Validate.amount('-1', 'Amount'), 'Amount cannot be negative');
      expect(Validate.amount('abc', 'Amount'), 'Amount must be a number');
      expect(Validate.amount('', 'Amount'), isNull);
      expect(Validate.amount('4500', 'Amount'), isNull);
    });
  });

  group('Validate.positiveInt', () {
    test('requires at least 1 when present', () {
      expect(Validate.positiveInt('0', 'Booked days'),
          'Booked days must be at least 1');
      expect(Validate.positiveInt('3', 'Booked days'), isNull);
      expect(Validate.positiveInt('', 'Booked days'), isNull);
    });
  });

  group('Validate.phone / cnic / year', () {
    test('phone length bounds', () {
      expect(Validate.phone('0300123'), 'Phone should be 10-13 digits');
      expect(Validate.phone('03001234567'), isNull);
      expect(Validate.phone(''), isNull);
    });

    test('CNIC must be 13 digits, separators ignored', () {
      expect(Validate.cnic('123'), 'CNIC should be 13 digits');
      expect(Validate.cnic('42201-1234567-1'), isNull);
    });

    test('year must be plausible', () {
      expect(Validate.year('1820'), 'Enter a valid year');
      expect(Validate.year('2021'), isNull);
      expect(Validate.year(''), isNull);
    });
  });
}
