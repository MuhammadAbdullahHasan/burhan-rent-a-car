/// One CSV source row, translated into business-meaning fields, independent
/// of whatever the source column names/order/formats happened to be.
///
/// This is the boundary the import pipeline (dedupe, gap-fill, transactional
/// insert, reconciliation) is written against. A new source file only needs
/// a new `RentalCsvMapper` that produces these -- nothing downstream changes.
class MappedRentalRow {
  final int rentalNo;

  // Customer fields
  final String? customerName;
  final String? customerPhone;
  final String? customerCnic;
  final String? customerLicenseNo;
  final String? customerLicenseCity;

  // Vehicle fields
  final String? vehicleRegistration;
  final String? vehicleChassisNo;
  final String? vehicleEngineNo;
  final String? vehicleCompany;
  final String? vehicleModelName;
  final String? vehicleTrim;
  final String? vehicleHorsepower;
  final String? vehicleColor;
  final int? vehicleRegYear;
  final String? vehicleInsuranceDueOn;

  // Rental-transaction fields
  final String? startDate;
  final String? startTime;
  final String? endDate;
  final String? endTime;
  final int? bookDays;
  final double? amount;
  final double? balance;
  final String? status;
  final String? remarks;
  final String? refName;
  final String? refContact;
  final String? refRelation;

  /// Non-fatal issues found while mapping this row (malformed date, unusual
  /// value, etc.) -- surfaced in the reconciliation report, never blocks
  /// the row from being imported.
  final List<String> warnings;

  MappedRentalRow({
    required this.rentalNo,
    this.customerName,
    this.customerPhone,
    this.customerCnic,
    this.customerLicenseNo,
    this.customerLicenseCity,
    this.vehicleRegistration,
    this.vehicleChassisNo,
    this.vehicleEngineNo,
    this.vehicleCompany,
    this.vehicleModelName,
    this.vehicleTrim,
    this.vehicleHorsepower,
    this.vehicleColor,
    this.vehicleRegYear,
    this.vehicleInsuranceDueOn,
    this.startDate,
    this.startTime,
    this.endDate,
    this.endTime,
    this.bookDays,
    this.amount,
    this.balance,
    this.status,
    this.remarks,
    this.refName,
    this.refContact,
    this.refRelation,
    List<String>? warnings,
  }) : warnings = warnings ?? const [];
}

/// Raised when a source row cannot even be assigned a rental number -- the
/// one case the pipeline treats as fatal to that row (see ImportPipeline).
class RowMappingException implements Exception {
  final String message;
  RowMappingException(this.message);
  @override
  String toString() => 'RowMappingException: $message';
}

/// Translates one raw CSV row (header -> value) into a [MappedRentalRow].
/// Implement one of these per source file shape; the rest of the import
/// pipeline never needs to know column names.
abstract class RentalCsvMapper {
  MappedRentalRow map(Map<String, String> rawRow);
}
