import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';

/// The data layer's local engine, with one addition: every write reports
/// itself so the cloud sync can push it straight away instead of waiting
/// for a tap or a timer. All rules (numbering, soft delete, outbox) are the
/// base class's, untouched.
class AutoSyncEngine extends LocalSyncEngine {
  final void Function() onLocalChange;

  AutoSyncEngine({required this.onLocalChange});

  @override
  Future<String> createPendingRental(
    Database db, {
    String? customerId,
    String? vehicleId,
    String? startDate,
    String? startTime,
    String? endDate,
    String? endTime,
    int? bookDays,
    double? amount,
    double? balance,
    String? status,
    String? remarks,
    String? refName,
    String? refContact,
    String? refRelation,
  }) async {
    final id = await super.createPendingRental(
      db,
      customerId: customerId,
      vehicleId: vehicleId,
      startDate: startDate,
      startTime: startTime,
      endDate: endDate,
      endTime: endTime,
      bookDays: bookDays,
      amount: amount,
      balance: balance,
      status: status,
      remarks: remarks,
      refName: refName,
      refContact: refContact,
      refRelation: refRelation,
    );
    onLocalChange();
    return id;
  }

  @override
  Future<void> queueUpdate(
    Database db,
    String rentalId,
    Map<String, Object?> fields,
  ) async {
    await super.queueUpdate(db, rentalId, fields);
    onLocalChange();
  }

  @override
  Future<void> queueSoftDelete(Database db, String rentalId) async {
    await super.queueSoftDelete(db, rentalId);
    onLocalChange();
  }

  @override
  Future<String> createCustomer(
    Database db, {
    String? fullName,
    String? phone,
    String? phoneNormalized,
    String? cnic,
    String? cnicNormalized,
    String? licenseNo,
    String? licenseCity,
  }) async {
    final id = await super.createCustomer(
      db,
      fullName: fullName,
      phone: phone,
      phoneNormalized: phoneNormalized,
      cnic: cnic,
      cnicNormalized: cnicNormalized,
      licenseNo: licenseNo,
      licenseCity: licenseCity,
    );
    onLocalChange();
    return id;
  }

  @override
  Future<void> updateCustomer(
    Database db,
    String customerId,
    Map<String, Object?> fields,
  ) async {
    await super.updateCustomer(db, customerId, fields);
    onLocalChange();
  }

  @override
  Future<String> createVehicle(
    Database db, {
    String? registrationNo,
    String? registrationNorm,
    String? chassisNo,
    String? engineNo,
    String? company,
    String? modelName,
    String? trim,
    String? horsepower,
    String? color,
    int? regYear,
    String? insuranceDueOn,
  }) async {
    final id = await super.createVehicle(
      db,
      registrationNo: registrationNo,
      registrationNorm: registrationNorm,
      chassisNo: chassisNo,
      engineNo: engineNo,
      company: company,
      modelName: modelName,
      trim: trim,
      horsepower: horsepower,
      color: color,
      regYear: regYear,
      insuranceDueOn: insuranceDueOn,
    );
    onLocalChange();
    return id;
  }

  @override
  Future<void> updateVehicle(
    Database db,
    String vehicleId,
    Map<String, Object?> fields,
  ) async {
    await super.updateVehicle(db, vehicleId, fields);
    onLocalChange();
  }

  @override
  Future<String> setRentalAgreementPhoto(
    Database db, {
    required String rentalId,
    required Uint8List image,
    Uint8List? thumbnail,
    String? mimeType,
  }) async {
    final id = await super.setRentalAgreementPhoto(
      db,
      rentalId: rentalId,
      image: image,
      thumbnail: thumbnail,
      mimeType: mimeType,
    );
    onLocalChange();
    return id;
  }

  @override
  Future<void> removeRentalAgreementPhoto(Database db, String rentalId) async {
    await super.removeRentalAgreementPhoto(db, rentalId);
    onLocalChange();
  }
}
