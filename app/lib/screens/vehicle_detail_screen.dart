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
    final rentals =
        await services.rentals.findByVehicleId(db, widget.vehicleId);
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
          final isDeleted = (vehicle['is_deleted'] as int? ?? 0) == 1;
          final theme = Theme.of(context);

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              SectionCard(
                title: 'VEHICLE',
                action: isDeleted
                    ? null
                    : TextButton.icon(
                        onPressed: () async {
                          final saved = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                              builder: (_) =>
                                  VehicleFormScreen(vehicle: vehicle),
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayOrNA(vehicle['registration_no']),
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (isDeleted)
                          Text(
                            'DELETED',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.error,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
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
                    DetailField(
                        label: 'Chassis #', value: vehicle['chassis_no']),
                    DetailField(label: 'Engine #', value: vehicle['engine_no']),
                    DetailField(
                      label: 'Insurance due',
                      value: vehicle['insurance_due_on'],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              CollapsibleSectionCard(
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
              if (!isDeleted) ...[
                const SizedBox(height: 16),
                Card(
                  child: SwitchListTile(
                    value: VehicleRepository.isInFleet(vehicle),
                    onChanged: (value) => _setInFleet(vehicle, value),
                    title: const Text('In the current fleet'),
                    subtitle: Text(
                      VehicleRepository.isInFleet(vehicle)
                          ? 'Shown in the Library with the working fleet.'
                          : 'Kept with the past vehicles. Its rentals and '
                              'history are unchanged.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  ),
                ),
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: () => _delete(vehicle, data.rentals.length),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete vehicle'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _setInFleet(Map<String, Object?> vehicle, bool inFleet) async {
    final services = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await services.engine.setVehicleInFleet(
      services.db,
      vehicle['id'] as String,
      inFleet,
    );
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(inFleet
          ? '${displayOrNA(vehicle['registration_no'])} is back in the fleet.'
          : '${displayOrNA(vehicle['registration_no'])} moved to past '
              'vehicles.'),
    ));
    _reload();
  }

  Future<void> _delete(Map<String, Object?> vehicle, int rentalCount) async {
    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final reg = displayOrNA(vehicle['registration_no']);
    final history = rentalCount == 0
        ? ''
        : ', and its $rentalCount rental${rentalCount == 1 ? '' : 's'} keep '
            'their history';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $reg?'),
        content: Text(
          'It will be hidden from the Library and search, and can no '
          'longer be chosen for a new rental. It is never erased$history — '
          'its record and every rental against it can still be opened '
          'directly, and re-entering the same registration later creates a '
          'new vehicle rather than reviving this one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await services.engine
        .queueSoftDeleteVehicle(services.db, vehicle['id'] as String);
    navigator.pop();
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
            title:
                'ON ${displayOrNA(vehicle['registration_no']).toUpperCase()}',
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
