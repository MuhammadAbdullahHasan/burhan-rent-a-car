import 'dart:typed_data';

import 'package:sqflite_common/sqlite_api.dart';

import '../repositories/attachment_repository.dart';
import '../repositories/customer_repository.dart';
import '../repositories/rental_repository.dart';
import '../repositories/vehicle_repository.dart';
import 'outbox.dart';
import 'rental_number_allocator.dart';

/// Local stand-in for the real sync engine described in the locked spec
/// (§5 offline sync). There is no backend yet, so "sync" here means
/// "process the outbox against this same local database" -- but the shape
/// (outbox -> idempotent apply -> mark done) is the same shape the real
/// engine will use against Supabase, so this exercises the actual
/// contract: offline-created rentals get a real number only once "synced",
/// never before, and processing is safe to run more than once.
class LocalSyncEngine {
  final RentalRepository rentals;
  final CustomerRepository customers;
  final VehicleRepository vehicles;
  final AttachmentRepository attachments;
  final Outbox outbox;
  final RentalNumberAllocator allocator;

  LocalSyncEngine({
    RentalRepository? rentals,
    CustomerRepository? customers,
    VehicleRepository? vehicles,
    AttachmentRepository? attachments,
    Outbox? outbox,
    RentalNumberAllocator? allocator,
  })  : rentals = rentals ?? RentalRepository(),
        customers = customers ?? CustomerRepository(),
        vehicles = vehicles ?? VehicleRepository(),
        attachments = attachments ?? AttachmentRepository(),
        outbox = outbox ?? Outbox(),
        allocator = allocator ?? RentalNumberAllocator();

  /// Creates a rental while "offline": no rental_no yet (shown to the user
  /// as "Pending #<id-prefix>"), queued for the next sync.
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
    late String id;
    await db.transaction((txn) async {
      id = await rentals.insert(
        txn,
        rentalNo: null,
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
      await outbox.enqueue(
        txn,
        entityType: 'rental',
        entityId: id,
        operation: 'insert',
      );
    });
    return id;
  }

  Future<void> queueUpdate(
    Database db,
    String rentalId,
    Map<String, Object?> fields,
  ) async {
    await db.transaction((txn) async {
      final existing = await rentals.getById(txn, rentalId);
      if (existing == null) return;
      await rentals.update(txn, rentalId, fields, existing['version'] as int);
      await outbox.enqueue(
        txn,
        entityType: 'rental',
        entityId: rentalId,
        operation: 'update',
        payload: fields,
      );
    });
  }

  Future<void> queueSoftDelete(Database db, String rentalId) async {
    await db.transaction((txn) async {
      final existing = await rentals.getById(txn, rentalId);
      if (existing == null) return;
      await rentals.softDelete(txn, rentalId, existing['version'] as int);
      await outbox.enqueue(
        txn,
        entityType: 'rental',
        entityId: rentalId,
        operation: 'delete',
      );
    });
  }

  /// Moves a vehicle between the working fleet and the past records.
  Future<void> setVehicleInFleet(
    Database db,
    String vehicleId,
    bool inFleet,
  ) async {
    await db.transaction((txn) async {
      final existing = await vehicles.getById(txn, vehicleId);
      if (existing == null) return;
      await vehicles.setInFleet(
        txn,
        vehicleId,
        inFleet,
        existing['version'] as int,
      );
      await outbox.enqueue(
        txn,
        entityType: 'vehicle',
        entityId: vehicleId,
        operation: 'update',
      );
    });
  }

  /// A vehicle sold, retired or entered by mistake: hidden from the Library
  /// and search, its history untouched. See [VehicleRepository.softDelete].
  Future<void> queueSoftDeleteVehicle(Database db, String vehicleId) async {
    await db.transaction((txn) async {
      final existing = await vehicles.getById(txn, vehicleId);
      if (existing == null) return;
      await vehicles.softDelete(txn, vehicleId, existing['version'] as int);
      await outbox.enqueue(
        txn,
        entityType: 'vehicle',
        entityId: vehicleId,
        operation: 'delete',
      );
    });
  }

  /// Customer and vehicle mutations go through the same outbox as rentals,
  /// so the invariant "every local mutation is queued" already holds when
  /// the real sync engine replaces this class. Neither entity has a
  /// server-assigned business number, so syncing them is a plain
  /// acknowledge today.
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
    late String id;
    await db.transaction((txn) async {
      id = await customers.insert(
        txn,
        fullName: fullName,
        phone: phone,
        phoneNormalized: phoneNormalized,
        cnic: cnic,
        cnicNormalized: cnicNormalized,
        licenseNo: licenseNo,
        licenseCity: licenseCity,
      );
      await outbox.enqueue(
        txn,
        entityType: 'customer',
        entityId: id,
        operation: 'insert',
      );
    });
    return id;
  }

  Future<void> updateCustomer(
    Database db,
    String customerId,
    Map<String, Object?> fields,
  ) async {
    await db.transaction((txn) async {
      final existing = await customers.getById(txn, customerId);
      if (existing == null) return;
      await customers.update(
        txn,
        customerId,
        fields,
        existing['version'] as int,
      );
      await outbox.enqueue(
        txn,
        entityType: 'customer',
        entityId: customerId,
        operation: 'update',
        payload: fields,
      );
    });
  }

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
    late String id;
    await db.transaction((txn) async {
      id = await vehicles.insert(
        txn,
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
      await outbox.enqueue(
        txn,
        entityType: 'vehicle',
        entityId: id,
        operation: 'insert',
      );
    });
    return id;
  }

  Future<void> updateVehicle(
    Database db,
    String vehicleId,
    Map<String, Object?> fields,
  ) async {
    await db.transaction((txn) async {
      final existing = await vehicles.getById(txn, vehicleId);
      if (existing == null) return;
      await vehicles.update(txn, vehicleId, fields, existing['version'] as int);
      await outbox.enqueue(
        txn,
        entityType: 'vehicle',
        entityId: vehicleId,
        operation: 'update',
        payload: fields,
      );
    });
  }

  /// Attaches (or replaces) the photo of a rental's paper agreement. The
  /// outbox entry carries only the attachment id -- the real sync engine
  /// will read the bytes from the row when it pushes, rather than
  /// duplicating them in the queue payload.
  Future<String> setRentalAgreementPhoto(
    Database db, {
    required String rentalId,
    required Uint8List image,
    Uint8List? thumbnail,
    String? mimeType,
  }) async {
    late String id;
    await db.transaction((txn) async {
      id = await attachments.setRentalAgreement(
        txn,
        rentalId: rentalId,
        image: image,
        thumbnail: thumbnail,
        mimeType: mimeType,
      );
      await outbox.enqueue(
        txn,
        entityType: 'attachment',
        entityId: id,
        operation: 'insert',
      );
    });
    return id;
  }

  Future<void> removeRentalAgreementPhoto(Database db, String rentalId) async {
    await db.transaction((txn) async {
      final existing = await attachments.rentalAgreement(txn, rentalId);
      if (existing == null) return;
      await attachments.removeRentalAgreement(txn, rentalId);
      await outbox.enqueue(
        txn,
        entityType: 'attachment',
        entityId: existing['id'] as String,
        operation: 'delete',
      );
    });
  }

  /// Processes every pending outbox entry. Idempotent: a rental that
  /// already has a rental_no (already synced) is never reassigned one, so
  /// running this twice -- or resuming after a crash mid-run -- never
  /// produces a duplicate or a second number for the same rental.
  Future<int> syncPending(Database db) async {
    var processed = 0;
    final items = await outbox.pending(db);
    for (final item in items) {
      final entityType = item['entity_type'] as String;
      final entityId = item['entity_id'] as String;
      final operation = item['operation'] as String;
      final id = item['id'] as String;

      if (entityType != 'rental') {
        await outbox.markDone(db, id);
        continue;
      }

      await db.transaction((txn) async {
        if (operation == 'insert') {
          final row = await rentals.getById(txn, entityId);
          if (row != null && row['rental_no'] == null) {
            final nextNo = await allocator.allocateNext(txn);
            await rentals.update(
              txn,
              entityId,
              {'rental_no': nextNo},
              row['version'] as int,
            );
          }
        }
        // 'update' and 'delete' operations were already applied locally at
        // queue time (outbox stores the mutation as evidence for the real
        // backend push); with no backend yet there's nothing further to
        // apply -- just acknowledge.
        await outbox.markDone(txn, id);
      });
      processed++;
    }
    return processed;
  }
}
