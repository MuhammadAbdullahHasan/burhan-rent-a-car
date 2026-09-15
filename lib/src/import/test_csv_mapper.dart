import 'mapped_rental_row.dart';
import 'normalizers.dart';

/// Maps `test_data/burhan_rent_a_car_temporary_test.csv` specifically.
///
/// TEMPORARY. This mapper exists only because the *real* CSV hasn't arrived
/// yet -- do not extend it speculatively. When the real file is provided,
/// write a new `RealCsvMapper implements RentalCsvMapper` next to this one
/// and point the pipeline at it; delete this class once it's no longer
/// needed for the test suite. See docs/test_data_analysis.md for the [P]
/// (provisional) notes on column meaning this mapper encodes -- in
/// particular the source `Company/Model #/Make/Hors Pwr` columns hold
/// brand/model-name/trim/horsepower in that order, which is unconfirmed
/// against the real data.
class TestCsvMapper implements RentalCsvMapper {
  @override
  MappedRentalRow map(Map<String, String> rawRow) {
    final warnings = <String>[];

    final rentalNoRaw = rawRow['Rental#'];
    final rentalNo = parseIntOrNull(rentalNoRaw);
    if (rentalNo == null) {
      throw RowMappingException(
        'Row has no valid Rental# (raw value: "$rentalNoRaw")',
      );
    }

    final startDate = normalizeIsoDate(rawRow['Date']);
    if (startDate == null && normalizeNullable(rawRow['Date']) != null) {
      warnings.add('Rental #$rentalNo: unparseable Date "${rawRow['Date']}"');
    }
    final endDate = normalizeIsoDate(rawRow['Rcv Date']);
    if (endDate == null && normalizeNullable(rawRow['Rcv Date']) != null) {
      warnings.add(
        'Rental #$rentalNo: unparseable Rcv Date "${rawRow['Rcv Date']}"',
      );
    }
    final insuranceDueOn = normalizeIsoDate(rawRow['Ins. Due On']);

    final regYearRaw = rawRow['Reg. Year'];
    final regYear = parseIntOrNull(regYearRaw);
    if (regYear == null && normalizeNullable(regYearRaw) != null) {
      warnings.add('Rental #$rentalNo: unparseable Reg. Year "$regYearRaw"');
    }

    final bookDaysRaw = rawRow['Book Days'];
    final bookDays = parseIntOrNull(bookDaysRaw);
    if (bookDays == null && normalizeNullable(bookDaysRaw) != null) {
      warnings.add('Rental #$rentalNo: unparseable Book Days "$bookDaysRaw"');
    }

    return MappedRentalRow(
      rentalNo: rentalNo,
      customerName: normalizeNullable(rawRow['Name']),
      customerPhone: normalizeNullable(rawRow['Contact#']),
      customerCnic: normalizeNullable(rawRow['CNIC']),
      customerLicenseNo: normalizeNullable(rawRow['License#']),
      customerLicenseCity: normalizeNullable(rawRow['Lic. City']),
      vehicleRegistration: normalizeNullable(rawRow['Vehicle#']),
      vehicleChassisNo: normalizeNullable(rawRow['Chassis#']),
      vehicleEngineNo: normalizeNullable(rawRow['Engine#']),
      vehicleCompany: normalizeNullable(rawRow['Company']),
      vehicleModelName: normalizeNullable(rawRow['Model #']),
      vehicleTrim: normalizeNullable(rawRow['Make']),
      vehicleHorsepower: normalizeNullable(rawRow['Hors Pwr']),
      vehicleColor: normalizeNullable(rawRow['Color']),
      vehicleRegYear: regYear,
      vehicleInsuranceDueOn: insuranceDueOn,
      startDate: startDate,
      startTime: normalizeNullable(rawRow['Time']),
      endDate: endDate,
      endTime: normalizeNullable(rawRow['Rcv Time']),
      bookDays: bookDays,
      amount: parseDoubleOrNull(rawRow['Amount']),
      balance: parseDoubleOrNull(rawRow['Balance']),
      status: normalizeNullable(rawRow['Status']),
      remarks: normalizeNullable(rawRow['Remarks']),
      refName: normalizeNullable(rawRow['Ref. Name']),
      refContact: normalizeNullable(rawRow['Ref. Cont#']),
      refRelation: normalizeNullable(rawRow['Relation']),
      warnings: warnings,
    );
  }
}
