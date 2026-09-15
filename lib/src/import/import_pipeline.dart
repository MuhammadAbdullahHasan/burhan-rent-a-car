import 'dart:io';

import 'package:csv/csv.dart' as csv_lib;
import 'package:sqflite_common/sqlite_api.dart';

import '../repositories/customer_repository.dart';
import '../repositories/rental_repository.dart';
import '../repositories/vehicle_repository.dart';
import '../sync/rental_number_allocator.dart';
import 'mapped_rental_row.dart';
import 'normalizers.dart';
import 'reconciliation_report.dart';

/// Historical bulk import: parse -> map (via the injected [RentalCsvMapper])
/// -> validate -> transactional insert (dedupe customers/vehicles, gap-fill
/// missing rental numbers) -> seed the rental-number counter -> report.
///
/// All-or-nothing: a fatal error (duplicate rental_no in the source, or a
/// row with no usable rental_no) rolls back the whole import rather than
/// leaving a partially-imported database, per the locked spec's
/// "transactional import" requirement. Per-row data problems that don't
/// threaten numbering integrity (a malformed date, an inconsistent vehicle
/// attribute) are warnings, not aborts -- the row is still imported, since
/// "preserve every row" outranks "every field parsed cleanly".
class ImportPipeline {
  final RentalCsvMapper mapper;
  final CustomerRepository customers;
  final VehicleRepository vehicles;
  final RentalRepository rentals;
  final RentalNumberAllocator allocator;

  ImportPipeline({
    required this.mapper,
    CustomerRepository? customers,
    VehicleRepository? vehicles,
    RentalRepository? rentals,
    RentalNumberAllocator? allocator,
  })  : customers = customers ?? CustomerRepository(),
        vehicles = vehicles ?? VehicleRepository(),
        rentals = rentals ?? RentalRepository(),
        allocator = allocator ?? RentalNumberAllocator();

  Future<ReconciliationReport> importFile(Database db, String csvPath) async {
    final content = await File(csvPath).readAsString();
    return importCsvString(db, content);
  }

  Future<ReconciliationReport> importCsvString(
    Database db,
    String csvContent,
  ) async {
    final table = const csv_lib.CsvToListConverter(
      eol: '\n',
      shouldParseNumbers: false,
    ).convert(csvContent);

    if (table.isEmpty) {
      return ReconciliationReport.failure('CSV is empty.');
    }

    final header = table.first.map((c) => c.toString()).toList();
    final rawRows = table.skip(1).map((row) {
      final map = <String, String>{};
      for (var i = 0; i < header.length; i++) {
        map[header[i]] = i < row.length ? row[i].toString() : '';
      }
      return map;
    }).toList();

    final report = ReconciliationReport();
    final mapped = <MappedRentalRow>[];
    final seenRentalNos = <int>{};

    for (var i = 0; i < rawRows.length; i++) {
      report.rowsRead++;
      final lineNo = i + 2; // +1 for header, +1 for 1-indexing
      try {
        final row = mapper.map(rawRows[i]);
        if (seenRentalNos.contains(row.rentalNo)) {
          return ReconciliationReport.failure(
            'Duplicate Rental# ${row.rentalNo} found at CSV line $lineNo. '
            'Import aborted -- no rows were written.',
          );
        }
        seenRentalNos.add(row.rentalNo);
        report.warnings.addAll(row.warnings);
        mapped.add(row);
      } on RowMappingException catch (e) {
        return ReconciliationReport.failure(
          'CSV line $lineNo: ${e.message}. Import aborted -- no rows were '
          'written.',
        );
      }
    }

    if (mapped.isEmpty) {
      return ReconciliationReport.failure('CSV had no data rows.');
    }

    await db.transaction((txn) async {
      for (final row in mapped) {
        final customerId = await _resolveCustomer(txn, row, report);
        final vehicleId = await _resolveVehicle(txn, row, report);
        await rentals.insert(
          txn,
          rentalNo: row.rentalNo,
          customerId: customerId,
          vehicleId: vehicleId,
          startDate: row.startDate,
          startTime: row.startTime,
          endDate: row.endDate,
          endTime: row.endTime,
          bookDays: row.bookDays,
          amount: row.amount,
          balance: row.balance,
          status: row.status,
          remarks: row.remarks,
          refName: row.refName,
          refContact: row.refContact,
          refRelation: row.refRelation,
        );
        report.rentalsInserted++;
      }

      final allNos = mapped.map((r) => r.rentalNo).toList()..sort();
      final min = allNos.first;
      final max = allNos.last;
      final present = allNos.toSet();
      for (var n = min; n <= max; n++) {
        if (!present.contains(n)) {
          await rentals.insert(txn, rentalNo: n, isPlaceholder: true);
          report.placeholdersInserted++;
        }
      }

      await allocator.seedFromExisting(txn);
    });

    return report;
  }

  Future<String> _resolveCustomer(
    DatabaseExecutor txn,
    MappedRentalRow row,
    ReconciliationReport report,
  ) async {
    final phoneNorm = normalizeDigits(row.customerPhone);
    final cnicNorm = normalizeDigits(row.customerCnic);

    Map<String, Object?>? existing;
    if (phoneNorm != null) {
      existing = await customers.findByPhoneNormalized(txn, phoneNorm);
    }
    existing ??= cnicNorm != null
        ? await customers.findByCnicNormalized(txn, cnicNorm)
        : null;

    if (existing != null) {
      await customers.backfill(
        txn,
        existing,
        phone: row.customerPhone,
        phoneNormalized: phoneNorm,
        cnic: row.customerCnic,
        cnicNormalized: cnicNorm,
        licenseNo: row.customerLicenseNo,
        licenseCity: row.customerLicenseCity,
      );
      report.customersMerged++;
      return existing['id'] as String;
    }

    final flagged = phoneNorm == null && cnicNorm == null;
    if (flagged) {
      report.customersFlaggedForReview++;
      report.warnings.add(
        'Rental #${row.rentalNo}: customer "${row.customerName}" has no '
        'phone or CNIC to match on -- created as a new record, flagged for '
        'manual duplicate review.',
      );
    }

    final id = await customers.insert(
      txn,
      fullName: row.customerName,
      phone: row.customerPhone,
      phoneNormalized: phoneNorm,
      cnic: row.customerCnic,
      cnicNormalized: cnicNorm,
      licenseNo: row.customerLicenseNo,
      licenseCity: row.customerLicenseCity,
      possibleDuplicate: flagged,
    );
    report.customersCreated++;
    return id;
  }

  Future<String?> _resolveVehicle(
    DatabaseExecutor txn,
    MappedRentalRow row,
    ReconciliationReport report,
  ) async {
    final regNorm = normalizeRegistration(row.vehicleRegistration);
    if (regNorm == null) return null;

    final existing = await vehicles.findByRegistrationNorm(txn, regNorm);
    if (existing != null) {
      final mismatch = vehicles.describeAttributeMismatch(
        existing,
        chassisNo: row.vehicleChassisNo,
        engineNo: row.vehicleEngineNo,
        company: row.vehicleCompany,
        modelName: row.vehicleModelName,
        trim: row.vehicleTrim,
        horsepower: row.vehicleHorsepower,
        color: row.vehicleColor,
        regYear: row.vehicleRegYear,
      );
      if (mismatch != null) {
        report.warnings.add(
          'Rental #${row.rentalNo}: vehicle $regNorm attribute mismatch vs '
          'earlier import ($mismatch) -- kept the originally imported '
          'values.',
        );
      }
      return existing['id'] as String;
    }

    final id = await vehicles.insert(
      txn,
      registrationNo: row.vehicleRegistration,
      registrationNorm: regNorm,
      chassisNo: row.vehicleChassisNo,
      engineNo: row.vehicleEngineNo,
      company: row.vehicleCompany,
      modelName: row.vehicleModelName,
      trim: row.vehicleTrim,
      horsepower: row.vehicleHorsepower,
      color: row.vehicleColor,
      regYear: row.vehicleRegYear,
      insuranceDueOn: row.vehicleInsuranceDueOn,
    );
    report.vehiclesCreated++;
    return id;
  }
}
