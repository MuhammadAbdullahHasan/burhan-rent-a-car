import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_services.dart';
import '../sync/sync_actions.dart';
import '../services/agreement_archive.dart';
import '../services/agreement_photo.dart';
import '../widgets/agreement_card.dart';
import '../widgets/common.dart';
import 'customer_detail_screen.dart';
import 'rental_form_screen.dart';
import 'vehicle_detail_screen.dart';

class RentalDetailScreen extends StatefulWidget {
  final String rentalId;

  const RentalDetailScreen({super.key, required this.rentalId});

  @override
  State<RentalDetailScreen> createState() => _RentalDetailScreenState();
}

class _RentalDetailScreenState extends State<RentalDetailScreen> {
  late Future<_RentalData> _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
  }

  Future<_RentalData> _load() async {
    final services = AppScope.of(context);
    final db = services.db;
    final rental = await services.rentals.getById(db, widget.rentalId);
    if (rental == null) return _RentalData(rental: null);
    final customerId = rental['customer_id'] as String?;
    final vehicleId = rental['vehicle_id'] as String?;
    final agreement = await services.attachments.rentalAgreement(
      db,
      widget.rentalId,
    );
    // No photo of its own: show the scan from the owner's archive, if
    // there is one for this number. Fetched after the screen is up so a
    // slow connection never delays the rest of the record.
    final rentalNo = rental['rental_no'] as int?;
    final archive = services.agreementArchive;
    if (agreement == null && rentalNo != null && archive != null) {
      _loadArchive(archive, rentalNo);
    }
    return _RentalData(
      rental: rental,
      customer: customerId == null
          ? null
          : await services.customers.getById(db, customerId),
      vehicle: vehicleId == null
          ? null
          : await services.vehicles.getById(db, vehicleId),
      agreementImage: agreement?['image'] as Uint8List?,
    );
  }

  bool _photoBusy = false;

  /// Scans of this rental from the pre-app archive, once fetched.
  List<Uint8List> _archivePhotos = const [];
  int? _archiveFor;

  Future<void> _loadArchive(AgreementArchive archive, int rentalNo) async {
    if (_archiveFor == rentalNo) return;
    _archiveFor = rentalNo;
    final photos = await archive.photosFor(rentalNo);
    if (mounted && photos.isNotEmpty) setState(() => _archivePhotos = photos);
  }

  Future<void> _attachPhoto(ImageSource source) async {
    final services = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final picker = AgreementPhotoPicker();
    setState(() => _photoBusy = true);
    try {
      final photo = await picker.pickFrom(source);
      if (photo == null) {
        // Either the user backed out, or the file wasn't a readable image.
        return;
      }
      await services.engine.setRentalAgreementPhoto(
        services.db,
        rentalId: widget.rentalId,
        image: photo.image,
        thumbnail: photo.thumbnail,
        mimeType: AgreementPhoto.mimeType,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Agreement photo saved.')),
      );
      _reload();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save the photo: $e')),
      );
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  Future<void> _removePhoto() async {
    final services = AppScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove agreement photo?'),
        content: const Text(
          'The photo will no longer show on this rental. You can add a new '
          'one at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await services.engine.removeRentalAgreementPhoto(
      services.db,
      widget.rentalId,
    );
    _reload();
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _syncNow(Map<String, Object?> rental) async {
    final services = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final message = await runSync(services);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
    _reload();
  }

  Future<void> _closeRental(Map<String, Object?> rental) async {
    final services = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await services.engine.queueUpdate(
      services.db,
      rental['id'] as String,
      {'status': 'Closed'},
    );
    messenger.showSnackBar(
      SnackBar(content: Text('Rental ${rentalDisplayNumber(rental)} closed.')),
    );
    _reload();
  }

  Future<void> _delete(Map<String, Object?> rental) async {
    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this rental?'),
        content: Text(
          'Rental ${rentalDisplayNumber(rental)} will be hidden from lists. '
          'It is never erased, and its number is retired permanently — it '
          'will never be reused by a future rental.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await services.engine.queueSoftDelete(services.db, rental['id'] as String);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Rental')),
      body: FutureBuilder<_RentalData>(
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
          final rental = snapshot.data!.rental;
          if (rental == null) {
            return const EmptyState(
              icon: Icons.error_outline,
              message: 'This rental no longer exists.',
            );
          }

          // A gap in the historical numbering: the row exists so the
          // sequence stays intact, but it has no source data at all.
          if (isPlaceholderRental(rental)) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  child: Column(
                    children: [
                      RentalNumberBadge(rental: rental),
                      const SizedBox(height: 16),
                      Icon(
                        Icons.inventory_2_outlined,
                        size: 40,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        noPreviousRecordAvailable,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This number is kept so the historical sequence is '
                        'never renumbered. It will never be reused for a new '
                        'rental.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          final data = snapshot.data!;
          final isClosed =
              (rental['status'] as String?)?.toLowerCase() == 'closed';
          final isDeleted = (rental['is_deleted'] as int? ?? 0) == 1;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        RentalNumberBadge(rental: rental),
                        const SizedBox(width: 8),
                        StatusChip(status: rental['status'] as String?),
                        const Spacer(),
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
                    if (isPendingRental(rental))
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Created offline. The permanent rental '
                                'number is assigned when this syncs.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.tertiary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: () => _syncNow(rental),
                              child: const Text('Sync Now'),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    DetailField(
                        label: 'Start date', value: rental['start_date']),
                    DetailField(
                        label: 'Start time', value: rental['start_time']),
                    DetailField(
                        label: 'Return date', value: rental['end_date']),
                    DetailField(
                        label: 'Return time', value: rental['end_time']),
                    DetailField(
                        label: 'Booked days', value: rental['book_days']),
                    DetailField(label: 'Amount', value: rental['amount']),
                    DetailField(label: 'Balance', value: rental['balance']),
                    DetailField(label: 'Remarks', value: rental['remarks']),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AgreementCard(
                image: data.agreementImage,
                archive:
                    data.agreementImage == null ? _archivePhotos : const [],
                rentalLabel: rentalDisplayNumber(rental),
                busy: _photoBusy,
                onTakePhoto:
                    isDeleted ? null : () => _attachPhoto(ImageSource.camera),
                onChooseFromGallery:
                    isDeleted ? null : () => _attachPhoto(ImageSource.gallery),
                onRemove: isDeleted || data.agreementImage == null
                    ? null
                    : _removePhoto,
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'REFERENCE',
                child: Column(
                  children: [
                    DetailField(label: 'Name', value: rental['ref_name']),
                    DetailField(label: 'Contact', value: rental['ref_contact']),
                    DetailField(
                        label: 'Relation', value: rental['ref_relation']),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _LinkCard(
                icon: Icons.person,
                title: 'CUSTOMER',
                label: displayOrNA(data.customer?['full_name']),
                subtitle: displayOrNA(data.customer?['phone']),
                onTap: data.customer == null
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CustomerDetailScreen(
                              customerId: data.customer!['id'] as String,
                            ),
                          ),
                        );
                        _reload();
                      },
              ),
              const SizedBox(height: 12),
              _LinkCard(
                icon: Icons.directions_car,
                title: 'VEHICLE',
                label: displayOrNA(data.vehicle?['registration_no']),
                subtitle: [
                  data.vehicle?['company'],
                  data.vehicle?['model_name'],
                ].where((v) => v != null).join(' '),
                onTap: data.vehicle == null
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => VehicleDetailScreen(
                              vehicleId: data.vehicle!['id'] as String,
                            ),
                          ),
                        );
                        _reload();
                      },
              ),
              const SizedBox(height: 24),
              if (!isDeleted) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final saved = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                              builder: (_) => RentalFormScreen(rental: rental),
                            ),
                          );
                          if (saved == true) _reload();
                        },
                        icon: const Icon(Icons.edit),
                        label: const Text('Edit'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: isClosed ? null : () => _closeRental(rental),
                        icon: const Icon(Icons.check),
                        label: Text(isClosed ? 'Closed' : 'Close Rental'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => _delete(rental),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete rental'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String label;
  final String subtitle;
  final VoidCallback? onTap;

  const _LinkCard({
    required this.icon,
    required this.title,
    required this.label,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.10),
          foregroundColor: theme.colorScheme.primary,
          child: Icon(icon, size: 20),
        ),
        title: Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 0.8,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (subtitle.isNotEmpty)
              Text(subtitle, style: theme.textTheme.bodySmall),
          ],
        ),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _RentalData {
  final Map<String, Object?>? rental;
  final Map<String, Object?>? customer;
  final Map<String, Object?>? vehicle;
  final Uint8List? agreementImage;

  _RentalData({
    required this.rental,
    this.customer,
    this.vehicle,
    this.agreementImage,
  });
}
