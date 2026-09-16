import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../widgets/common.dart';
import '../widgets/rental_tile.dart';
import 'customer_detail_screen.dart';
import 'rental_detail_screen.dart';
import 'vehicle_form_screen.dart';

/// Vehicle Details -> the customers who rented it -> that customer's
/// rental history on this vehicle. Also lists the vehicle's full rental
/// history directly.
class VehicleDetailScreen extends StatefulWidget {
  final String vehicleId;

  const VehicleDetailScreen({super.key, required this.vehicleId});

  @override
  State<VehicleDetailScreen> createState() => _VehicleDetailScreenState();
}

class _VehicleDetailScreenState extends State<VehicleDetailScreen> {
  late Future<_VehicleData> _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
  }

  Future<_VehicleData> _load() async {
    final services = AppScope.of(context);
    final db = services.db;
    final vehicle = await services.vehicles.getById(db, widget.vehicleId);
    final rentals = await services.rentals.findByVehicleId(db, widget.vehicleId);
    return _VehicleData(
      vehicle: vehicle,
      customers: await services.vehicles.customersFor(db, widget.vehicleId),
      rentals: rentals,
      thumbnails: await services.attachments.agreementThumbnails(
        db,
        rentals.map((r) => r['id'] as String),
      ),
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vehicle Details')),
      body: FutureBuilder<_VehicleData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.error_outline,
              message: 'Could not load this record:\n${snapshot.error}',
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          final vehicle = data.vehicle;
          if (vehicle == null) {
            return const EmptyState(
              icon: Icons.error_outline,
              message: 'This vehicle no longer exists.',
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              SectionCard(
                title: 'VEHICLE',
                action: TextButton.icon(
                  onPressed: () async {
                    final saved = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => VehicleFormScreen(vehicle: vehicle),
                      ),
                    );
                    if (saved == true) _reload();
                  },
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text('Edit'),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayOrNA(vehicle['registration_no']),
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 12),
                    DetailField(label: 'Company', value: vehicle['company']),
                    DetailField(label: 'Model', value: vehicle['model_name']),
                    DetailField(label: 'Trim', value: vehicle['trim']),
                    DetailField(
                      label: 'Horsepower',
                      value: vehicle['horsepower'],
                    ),
                    DetailField(label: 'Color', value: vehicle['color']),
                    DetailField(
                      label: 'Reg. year',
                      value: vehicle['reg_year'],
                    ),
                    DetailField(label: 'Chassis #', value: vehicle['chassis_no']),
                    DetailField(label: 'Engine #', value: vehicle['engine_no']),
                    DetailField(
                      label: 'Insurance due',
                      value: vehicle['insurance_due_on'],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'CUSTOMERS WHO RENTED THIS VEHICLE',
                action: Text('${data.customers.length}'),
                child: data.customers.isEmpty
                    ? const EmptyState(
                        icon: Icons.people_outline,
                        message: 'No customers linked to this vehicle yet.',
                      )
                    : Column(
                        children: [
                          for (final customer in data.customers)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const CircleAvatar(
                                child: Icon(Icons.person, size: 20),
                              ),
                              title: Text(displayOrNA(customer['full_name'])),
                              subtitle: Text(
                                '${customer['rental_count']} rental'
                                '${customer['rental_count'] == 1 ? '' : 's'} '
                                'on this vehicle',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        _CustomerVehicleHistoryScreen(
                                      customer: customer,
                                      vehicle: vehicle,
                                    ),
                                  ),
                                );
                                _reload();
                              },
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'COMPLETE RENTAL HISTORY',
                action: Text('${data.rentals.length}'),
                child: data.rentals.isEmpty
                    ? const EmptyState(
                        icon: Icons.receipt_long_outlined,
                        message: 'No rentals recorded for this vehicle.',
                      )
                    : Column(
                        children: [
                          for (final rental in data.rentals)
                            RentalTile(
                              rental: rental,
                              agreementThumbnail:
                                  data.thumbnails[rental['id'] as String],
                              onTap: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => RentalDetailScreen(
                                      rentalId: rental['id'] as String,
                                    ),
                                  ),
                                );
                                _reload();
                              },
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The leaf of the Library drill-down: this customer's rentals of *this*
/// vehicle, with a way out to their full profile.
class _CustomerVehicleHistoryScreen extends StatelessWidget {
  final Map<String, Object?> customer;
  final Map<String, Object?> vehicle;

  const _CustomerVehicleHistoryScreen({
    required this.customer,
    required this.vehicle,
  });

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(displayOrNA(customer['full_name']))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          SectionCard(
            title: 'ON ${displayOrNA(vehicle['registration_no']).toUpperCase()}',
            action: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CustomerDetailScreen(
                    customerId: customer['id'] as String,
                  ),
                ),
              ),
              child: const Text('Full profile'),
            ),
            child: AsyncList<Map<String, Object?>>(
              future: services.rentals.findByCustomerAndVehicle(
                services.db,
                customer['id'] as String,
                vehicle['id'] as String,
              ),
              emptyIcon: Icons.receipt_long_outlined,
              emptyMessage: 'No rentals of this vehicle by this customer.',
              builder: (context, rentals) => Column(
                children: [
                  for (final rental in rentals)
                    RentalTile(
                      rental: rental,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RentalDetailScreen(
                            rentalId: rental['id'] as String,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VehicleData {
  final Map<String, Object?>? vehicle;
  final List<Map<String, Object?>> customers;
  final List<Map<String, Object?>> rentals;
  final Map<String, Uint8List> thumbnails;

  _VehicleData({
    required this.vehicle,
    required this.customers,
    required this.rentals,
    this.thumbnails = const {},
  });
}
