import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:test/test.dart';

/// The imported remarks blob, as legacy_dump.dart writes it.
const _imported = '''
Father/Husband: K Haji Muhammad Ahmed
Address: House No R 92, The Comfort Society, Gulshan e Shamim, Karachi
Passport: AEO154354
Self-drive: no
Rate: 10,500 Per Month
Ref. father/husband: Muhammad Iqbal
Ref. NIC: 4220173400075''';

void main() {
  group('reading a label out of the remarks blob', () {
    test('finds the value for a label', () {
      expect(
          remarksValue(_imported, 'Father/Husband'), 'K Haji Muhammad Ahmed');
      expect(remarksValue(_imported, 'Ref. NIC'), '4220173400075');
    });

    test('is case-insensitive but only matches a whole label', () {
      expect(
          remarksValue(_imported, 'father/husband'), 'K Haji Muhammad Ahmed');
      // "Ref. father/husband" must not answer for "Father/Husband".
      expect(
          remarksValue('Ref. father/husband: Iqbal', 'Father/Husband'), isNull);
    });

    test('a value with colons in it survives whole', () {
      expect(
        remarksValue('Address: Flat 2: Block B, Karachi', 'Address'),
        'Flat 2: Block B, Karachi',
      );
    });

    test('missing label, empty value, free text and null are all null', () {
      expect(remarksValue(_imported, 'Driver'), isNull);
      expect(remarksValue('Father/Husband:   ', 'Father/Husband'), isNull);
      expect(remarksValue('Returned the car late', 'Father/Husband'), isNull);
      expect(remarksValue(null, 'Father/Husband'), isNull);
    });
  });

  group('what is left for the Remarks field', () {
    test('drops only the labels that are shown in their own rows', () {
      final left = remarksWithout(_imported, ['Father/Husband', 'Ref. NIC']);
      expect(left, isNot(contains('K Haji Muhammad Ahmed')));
      expect(left, isNot(contains('4220173400075')));
      expect(left, contains('Passport: AEO154354'));
      expect(left, contains('Ref. father/husband: Muhammad Iqbal'));
    });

    test('free text the owner typed is untouched', () {
      expect(
        remarksWithout('Car returned with a scratch', ['Father/Husband']),
        'Car returned with a scratch',
      );
    });

    test('null when nothing is left, so the row reads N/A', () {
      expect(
          remarksWithout('Father/Husband: Ahmed', ['Father/Husband']), isNull);
      expect(remarksWithout(null, ['Father/Husband']), isNull);
    });
  });
}
