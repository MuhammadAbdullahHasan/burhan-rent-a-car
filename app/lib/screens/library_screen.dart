import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../widgets/common.dart';
import '../widgets/showroom_scaffold.dart';
import 'vehicle_detail_screen.dart';
import 'vehicle_form_screen.dart';

/// Library = vehicle inventory. One card per *distinct* vehicle (the
/// vehicles table is already deduplicated by normalized registration), never
/// a list of rentals -- 10,000 rentals collapse into a handful of cars.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late Future<List<Map<String, Object?>>> _future;
  ValueNotifier<int>? _dataChanged;

  /// The old records name hundreds of plates last rented a decade ago.
  /// They keep their history and stay searchable, but the inventory shows
  /// the working fleet unless the owner asks for the rest.
  bool _showPast = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
    final notifier = AppScope.of(context).dataChanged;
    if (!identical(notifier, _dataChanged)) {
      _dataChanged?.removeListener(_reload);
      _dataChanged = notifier..addListener(_reload);
    }
  }

  @override
  void dispose() {
    _dataChanged?.removeListener(_reload);
    super.dispose();
  }

  Future<List<Map<String, Object?>>> _load() {
    final services = AppScope.of(context);
    return services.vehicles.listWithStats(services.db);
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _addVehicle() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const VehicleFormScreen()),
    );
    if (saved == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return ShowroomScaffold(
      title: 'Vehicle Inventory',
      actions: [
        IconButton(
          tooltip: 'Add vehicle',
          onPressed: _addVehicle,
          icon: const Icon(Icons.add),
        ),
      ],
      onRefresh: () async => _reload(),
      slivers: [
        FutureBuilder<List<Map<String, Object?>>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.error_outline,
                  message: 'Could not load data:\n${snapshot.error}',
                ),
              );
            }
            final all = snapshot.data ?? const [];
            if (all.isEmpty) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.directions_car_outlined,
                  message: 'No vehicles yet.',
                ),
              );
            }
            final fleet = all.where(VehicleRepository.isInFleet).toList();
            final past = all.length - fleet.length;
            final vehicles = _showPast ? all : fleet;
            return SliverMainAxisGroup(slivers: [
              if (past > 0)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _showPast
                                ? 'All ${all.length} vehicles'
                                : 'Fleet · ${fleet.length} vehicles',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () =>
                              setState(() => _showPast = !_showPast),
                          icon: Icon(_showPast
                              ? Icons.visibility_off_outlined
                              : Icons.history),
                          label: Text(_showPast
                              ? 'Hide past vehicles'
                              : 'Show $past past vehicles'),
                        ),
                      ],
                    ),
                  ),
                ),
              _grid(vehicles),
            ]);
          },
        ),
      ],
    );
  }

  Widget _grid(List<Map<String, Object?>> vehicles) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        // Responsive: one column on a phone, more on a tablet.
        final width = constraints.crossAxisExtent;
        final columns = width > 900
            ? 3
            : width > 600
                ? 2
                : 1;
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            ShowroomScaffold.bottomInset(context),
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: 148,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => _VehicleCard(
                vehicle: vehicles[i],
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VehicleDetailScreen(
                        vehicleId: vehicles[i]['id'] as String,
                      ),
                    ),
                  );
                  _reload();
                },
              ),
              childCount: vehicles.length,
            ),
          ),
        );
      },
    );
  }
}

class _VehicleCard extends StatelessWidget {
  final Map<String, Object?> vehicle;
  final VoidCallback onTap;

  const _VehicleCard({required this.vehicle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = [
      vehicle['company'],
      vehicle['model_name'],
      vehicle['trim'],
    ].where((v) => v != null).join(' ');

    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.directions_car,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayOrNA(vehicle['registration_no']),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          description.isEmpty ? 'N/A' : description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  _Stat(
                    icon: Icons.receipt_long_outlined,
                    label: '${vehicle['rental_count'] ?? 0} rentals',
                  ),
                  const SizedBox(width: 16),
                  _Stat(
                    icon: Icons.people_outline,
                    label: '${vehicle['customer_count'] ?? 0} customers',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final IconData icon;
  final String label;

  const _Stat({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
