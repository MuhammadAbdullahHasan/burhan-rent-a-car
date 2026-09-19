import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../widgets/common.dart';
import '../widgets/rental_tile.dart';
import 'customer_form_screen.dart';
import 'rental_detail_screen.dart';
import 'vehicle_detail_screen.dart';

/// Customer -> complete profile -> all rental history -> other vehicles.
class CustomerDetailScreen extends StatefulWidget {
  final String customerId;

  const CustomerDetailScreen({super.key, required this.customerId});

  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  late Future<_CustomerData> _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
  }

  Future<_CustomerData> _load() async {
    final services = AppScope.of(context);
    final db = services.db;
    final customer = await services.customers.getById(db, widget.customerId);
    final rentals = await services.rentals.findByCustomerId(
      db,
      widget.customerId,
    );
    final vehicles = await services.customers.vehiclesFor(
      db,
      widget.customerId,
    );
    // Label each rental with its vehicle so the history reads on its own.
    final byId = {for (final v in vehicles) v['id'] as String: v};
    final thumbnails = await services.attachments.agreementThumbnails(
      db,
      rentals.map((r) => r['id'] as String),
    );
    return _CustomerData(
      customer: customer,
      rentals: rentals,
      vehicles: vehicles,
      vehicleById: byId,
      thumbnails: thumbnails,
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Customer')),
      body: FutureBuilder<_CustomerData>(
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
          final customer = data.customer;
          if (customer == null) {
            return const EmptyState(
              icon: Icons.error_outline,
              message: 'This customer no longer exists.',
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              // The owner searches a customer to see their rentals, so those
              // come first; the profile and the cars they have driven follow.
              SectionCard(
                title: 'COMPLETE RENTAL HISTORY',
                action: Text('${data.rentals.length}'),
                child: data.rentals.isEmpty
                    ? const EmptyState(
                        icon: Icons.receipt_long_outlined,
                        message: 'No rentals recorded for this customer.',
                      )
                    : Column(
                        children: [
                          for (final rental in data.rentals)
                            RentalTile(
                              rental: rental,
                              contextLabel: _vehicleLabel(data, rental),
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
              const SizedBox(height: 16),
              SectionCard(
                title: 'PROFILE',
                action: TextButton.icon(
                  onPressed: () async {
                    final saved = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => CustomerFormScreen(customer: customer),
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
                      displayOrNA(customer['full_name']),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if ((customer['possible_duplicate'] as int? ?? 0) == 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: theme.colorScheme.tertiary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Imported without a phone or CNIC — flagged '
                                'for duplicate review.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.tertiary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    DetailField(label: 'Phone', value: customer['phone']),
                    DetailField(label: 'CNIC', value: customer['cnic']),
                    DetailField(
                        label: 'License #', value: customer['license_no']),
                    DetailField(
                      label: 'License city',
                      value: customer['license_city'],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'OTHER VEHICLES RENTED',
                action: Text('${data.vehicles.length}'),
                child: data.vehicles.isEmpty
                    ? const EmptyState(
                        icon: Icons.directions_car_outlined,
                        message: 'No vehicles linked yet.',
                      )
                    : Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final vehicle in data.vehicles)
                            ActionChip(
                              avatar:
                                  const Icon(Icons.directions_car, size: 18),
                              label: Text(
                                '${displayOrNA(vehicle['registration_no'])}'
                                '  ·  ${vehicle['rental_count']}',
                              ),
                              onPressed: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => VehicleDetailScreen(
                                      vehicleId: vehicle['id'] as String,
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

  String _vehicleLabel(_CustomerData data, Map<String, Object?> rental) {
    final vehicleId = rental['vehicle_id'] as String?;
    if (vehicleId == null) return 'N/A';
    return displayOrNA(data.vehicleById[vehicleId]?['registration_no']);
  }
}

class _CustomerData {
  final Map<String, Object?>? customer;
  final List<Map<String, Object?>> rentals;
  final List<Map<String, Object?>> vehicles;
  final Map<String, Map<String, Object?>> vehicleById;
  final Map<String, Uint8List> thumbnails;

  _CustomerData({
    required this.customer,
    required this.rentals,
    required this.vehicles,
    required this.vehicleById,
    this.thumbnails = const {},
  });
}
