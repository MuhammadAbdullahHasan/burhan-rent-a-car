import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_services.dart';
import '../services/agreement_photo.dart';
import '../widgets/agreement_card.dart';
import '../widgets/common.dart';
import '../widgets/form_fields.dart';
import 'customer_form_screen.dart';
import 'vehicle_form_screen.dart';

/// New Rental / Edit Rental.
///
/// A new rental is created through the sync engine's offline path: saved
/// locally with no rental number and queued, so it shows as "Pending #"
/// until the backend assigns the permanent number. The form never invents,
/// edits or reuses a number.
class RentalFormScreen extends StatefulWidget {
  final Map<String, Object?>? rental;

  const RentalFormScreen({super.key, this.rental});

  @override
  State<RentalFormScreen> createState() => _RentalFormScreenState();
}

class _RentalFormScreenState extends State<RentalFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _startDate = TextEditingController();
  final _startTime = TextEditingController();
  final _endDate = TextEditingController();
  final _endTime = TextEditingController();
  final _bookDays = TextEditingController();
  final _amount = TextEditingController();
  final _balance = TextEditingController();
  final _remarks = TextEditingController();
  final _refName = TextEditingController();
  final _refContact = TextEditingController();
  final _refRelation = TextEditingController();

  /// New rentals default to typing a NEW customer in, because that is the
  /// common case; picking a repeat customer is the alternative. Editing
  /// always works with the rental's existing customer link.
  bool _useExistingCustomer = false;
  final _custName = TextEditingController();
  final _custPhone = TextEditingController();
  final _custCnic = TextEditingController();
  final _custLicense = TextEditingController();
  final _custLicenseCity = TextEditingController();

  Map<String, Object?>? _customer;
  Map<String, Object?>? _vehicle;
  String _status = 'Open';
  bool _saving = false;
  bool _linkError = false;

  bool get _typingNewCustomer => !_isEdit && !_useExistingCustomer;

  /// Photo taken while filling in a new rental; stored once the rental
  /// exists. (An existing rental's photo is managed from its detail screen.)
  AgreementPhoto? _pendingPhoto;
  bool _photoBusy = false;

  Future<void> _capturePhoto(ImageSource source) async {
    setState(() => _photoBusy = true);
    try {
      final photo = await AgreementPhotoPicker().pickFrom(source);
      if (photo != null && mounted) setState(() => _pendingPhoto = photo);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get the photo: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _photoBusy = false);
    }
  }

  bool get _isEdit => widget.rental != null;

  @override
  void initState() {
    super.initState();
    final r = widget.rental;
    if (r != null) {
      _startDate.text = r['start_date'] as String? ?? '';
      _startTime.text = r['start_time'] as String? ?? '';
      _endDate.text = r['end_date'] as String? ?? '';
      _endTime.text = r['end_time'] as String? ?? '';
      _bookDays.text = r['book_days']?.toString() ?? '';
      _amount.text = _numberText(r['amount']);
      _balance.text = _numberText(r['balance']);
      _remarks.text = r['remarks'] as String? ?? '';
      _refName.text = r['ref_name'] as String? ?? '';
      _refContact.text = r['ref_contact'] as String? ?? '';
      _refRelation.text = r['ref_relation'] as String? ?? '';
      _status = r['status'] as String? ?? 'Open';
    } else {
      _startDate.text = formatIsoDate(DateTime.now());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isEdit && _customer == null && _vehicle == null) {
      _loadLinkedEntities();
    }
  }

  Future<void> _loadLinkedEntities() async {
    final services = AppScope.of(context);
    final r = widget.rental!;
    final customerId = r['customer_id'] as String?;
    final vehicleId = r['vehicle_id'] as String?;
    final customer = customerId == null
        ? null
        : await services.customers.getById(services.db, customerId);
    final vehicle = vehicleId == null
        ? null
        : await services.vehicles.getById(services.db, vehicleId);
    if (!mounted) return;
    setState(() {
      _customer = customer;
      _vehicle = vehicle;
    });
  }

  @override
  void dispose() {
    for (final c in [
      _startDate,
      _startTime,
      _endDate,
      _endTime,
      _bookDays,
      _amount,
      _balance,
      _remarks,
      _refName,
      _refContact,
      _refRelation,
      _custName,
      _custPhone,
      _custCnic,
      _custLicense,
      _custLicenseCity,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickCustomer() async {
    final services = AppScope.of(context);
    final picked = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => EntityPicker(
        title: 'Select Customer',
        loadAll: () => services.customers.listAll(services.db),
        labelOf: (row) => displayOrNA(row['full_name']),
        subtitleOf: (row) => displayOrNA(row['phone']),
        createNew: () => const CustomerFormScreen(),
      ),
    );
    if (picked != null) {
      setState(() {
        _customer = picked;
        _linkError = false;
      });
    }
  }

  Future<void> _pickVehicle() async {
    final services = AppScope.of(context);
    final picked = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => EntityPicker(
        title: 'Select Vehicle',
        loadAll: () => services.vehicles.listWithStats(services.db),
        labelOf: (row) => displayOrNA(row['registration_no']),
        subtitleOf: (row) => [row['company'], row['model_name']]
            .where((v) => v != null)
            .join(' '),
        createNew: () => const VehicleFormScreen(),
      ),
    );
    if (picked != null) {
      setState(() {
        _vehicle = picked;
        _linkError = false;
      });
    }
  }

  String? _validateEndDate(String? value) =>
      Validate.dateOrder(value, _startDate.text);

  /// Shown as a hint only. `book_days` stays exactly what the user entered
  /// -- the source data shows the two don't always agree, so this never
  /// overwrites it.
  String? get _durationHint {
    final start = DateTime.tryParse(_startDate.text.trim());
    final end = DateTime.tryParse(_endDate.text.trim());
    if (start == null || end == null) return null;
    final days = end.difference(start).inDays;
    if (days < 0) return null;
    return 'Selected dates span $days day${days == 1 ? '' : 's'}';
  }

  Future<void> _save() async {
    final formValid = _formKey.currentState!.validate();
    final customerValid = _typingNewCustomer || _customer != null;
    final linksValid = customerValid && _vehicle != null;
    setState(() => _linkError = !linksValid);

    if (!formValid || !linksValid) {
      if (!linksValid) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_linkMessage)),
        );
      }
      return;
    }

    setState(() => _saving = true);
    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      if (_typingNewCustomer) {
        final customerId = await _resolveNewCustomer(services);
        if (customerId == null) {
          if (mounted) setState(() => _saving = false);
          return;
        }
        _customer = {'id': customerId};
      }

      if (_isEdit) {
        // rental_no is deliberately absent: an assigned number is immutable.
        await services.engine.queueUpdate(
          services.db,
          widget.rental!['id'] as String,
          {
            'customer_id': _customer?['id'],
            'vehicle_id': _vehicle?['id'],
            'start_date': _text(_startDate),
            'start_time': _text(_startTime),
            'end_date': _text(_endDate),
            'end_time': _text(_endTime),
            'book_days': int.tryParse(_bookDays.text.trim()),
            'amount': double.tryParse(_amount.text.trim()),
            'balance': double.tryParse(_balance.text.trim()),
            'status': _status,
            'remarks': _text(_remarks),
            'ref_name': _text(_refName),
            'ref_contact': _text(_refContact),
            'ref_relation': _text(_refRelation),
          },
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Rental ${rentalDisplayNumber(widget.rental!)} updated.',
            ),
          ),
        );
      } else {
        final rentalId = await services.engine.createPendingRental(
          services.db,
          customerId: _customer?['id'] as String?,
          vehicleId: _vehicle?['id'] as String?,
          startDate: _text(_startDate),
          startTime: _text(_startTime),
          endDate: _text(_endDate),
          endTime: _text(_endTime),
          bookDays: int.tryParse(_bookDays.text.trim()),
          amount: double.tryParse(_amount.text.trim()),
          balance: double.tryParse(_balance.text.trim()),
          status: _status,
          remarks: _text(_remarks),
          refName: _text(_refName),
          refContact: _text(_refContact),
          refRelation: _text(_refRelation),
        );
        final photo = _pendingPhoto;
        if (photo != null) {
          await services.engine.setRentalAgreementPhoto(
            services.db,
            rentalId: rentalId,
            image: photo.image,
            thumbnail: photo.thumbnail,
            mimeType: AgreementPhoto.mimeType,
          );
        }
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Rental saved as Pending — it gets its permanent number on sync.',
            ),
          ),
        );
      }
      navigator.pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save the rental: $error')),
      );
    }
  }

  String get _linkMessage => _typingNewCustomer
      ? 'Select a vehicle.'
      : _customer == null && _vehicle == null
          ? 'A rental needs both a customer and a vehicle.'
          : _customer == null
              ? 'Select a customer.'
              : 'Select a vehicle.';

  /// Creates the typed-in customer and returns its id -- unless the phone
  /// or CNIC already belongs to someone, in which case the owner chooses
  /// between linking that customer and creating a separate record (the
  /// import pipeline's rule: match by phone, then CNIC, never by name).
  /// Null means the owner cancelled.
  Future<String?> _resolveNewCustomer(AppServices services) async {
    final phoneNorm = normalizeDigits(_custPhone.text);
    final cnicNorm = normalizeDigits(_custCnic.text);
    final existing = await services.customers.findByPhoneOrCnic(
      services.db,
      phoneNormalized: phoneNorm,
      cnicNormalized: cnicNorm,
    );
    if (existing != null && mounted) {
      final choice = await showDialog<_DuplicateChoice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Repeat customer?'),
          content: Text(
            '${displayOrNA(existing['full_name'])} '
            '(${displayOrNA(existing['phone'])}) already has this phone or '
            'CNIC.\n\nUse that customer for this rental, or create a '
            'separate record? Records are never merged.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, _DuplicateChoice.cancel),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, _DuplicateChoice.createSeparate),
              child: const Text('Create separate'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _DuplicateChoice.useExisting),
              child: const Text('Use existing'),
            ),
          ],
        ),
      );
      switch (choice) {
        case _DuplicateChoice.useExisting:
          return existing['id'] as String;
        case _DuplicateChoice.createSeparate:
          break;
        case _DuplicateChoice.cancel:
        case null:
          return null;
      }
    }
    return services.engine.createCustomer(
      services.db,
      fullName: _text(_custName),
      phone: _text(_custPhone),
      phoneNormalized: phoneNorm,
      cnic: _text(_custCnic),
      cnicNormalized: cnicNorm,
      licenseNo: _text(_custLicense),
      licenseCity: _text(_custLicenseCity),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Rental' : 'New Rental')),
      bottomNavigationBar: FormActionBar(
        saveLabel: _isEdit ? 'Save Changes' : 'Create Rental',
        saving: _saving,
        onSave: _save,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            _numberBanner(theme),
            FormSection(
              title: 'CUSTOMER',
              children: [
                if (!_isEdit) ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.person_add_alt_1),
                        label: Text('New customer'),
                      ),
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.person_search),
                        label: Text('Existing customer'),
                      ),
                    ],
                    selected: {_useExistingCustomer},
                    onSelectionChanged: (selection) => setState(() {
                      _useExistingCustomer = selection.first;
                      _linkError = false;
                    }),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_typingNewCustomer) ...[
                  AppTextField(
                    controller: _custName,
                    label: 'Full name',
                    required: true,
                    textCapitalization: TextCapitalization.words,
                  ),
                  AppTextField(
                    controller: _custPhone,
                    label: 'Phone',
                    keyboardType: TextInputType.phone,
                    validator: Validate.phone,
                    helper: 'Used to recognise repeat customers',
                  ),
                  AppTextField(
                    controller: _custCnic,
                    label: 'CNIC',
                    hint: '42201-1234567-1',
                    validator: Validate.cnic,
                  ),
                  FormRow(
                    children: [
                      AppTextField(
                        controller: _custLicense,
                        label: 'License #',
                      ),
                      AppTextField(
                        controller: _custLicenseCity,
                        label: 'License city',
                        textCapitalization: TextCapitalization.words,
                      ),
                    ],
                  ),
                ] else
                  _PickerTile(
                    icon: Icons.person,
                    label: 'Customer *',
                    value: _customer == null
                        ? null
                        : displayOrNA(_customer!['full_name']),
                    subtitle: _customer == null
                        ? null
                        : displayOrNA(_customer!['phone']),
                    hasError: _linkError && _customer == null,
                    onTap: _pickCustomer,
                  ),
                const SizedBox(height: 8),
              ],
            ),
            FormSection(
              title: 'VEHICLE',
              children: [
                _PickerTile(
                  icon: Icons.directions_car,
                  label: 'Vehicle *',
                  value: _vehicle == null
                      ? null
                      : displayOrNA(_vehicle!['registration_no']),
                  subtitle: _vehicle == null
                      ? null
                      : [_vehicle!['company'], _vehicle!['model_name']]
                          .where((v) => v != null)
                          .join(' '),
                  hasError: _linkError && _vehicle == null,
                  onTap: _pickVehicle,
                ),
                if (_linkError)
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(
                      _linkMessage,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
            FormSection(
              title: 'RENTAL PERIOD',
              children: [
                FormRow(
                  children: [
                    AppDateField(
                      controller: _startDate,
                      label: 'Start date',
                      required: true,
                    ),
                    AppTimeField(
                      controller: _startTime,
                      label: 'Start time',
                    ),
                  ],
                ),
                FormRow(
                  children: [
                    AppDateField(
                      controller: _endDate,
                      label: 'Return date',
                      validator: _validateEndDate,
                      helper: _durationHint,
                    ),
                    AppTimeField(
                      controller: _endTime,
                      label: 'Return time',
                    ),
                  ],
                ),
                FormRow(
                  children: [
                    AppTextField(
                      controller: _bookDays,
                      label: 'Booked days',
                      keyboardType: TextInputType.number,
                      validator: (v) => Validate.positiveInt(v, 'Booked days'),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DropdownButtonFormField<String>(
                        value: _status,
                        decoration: const InputDecoration(labelText: 'Status'),
                        items: const [
                          DropdownMenuItem(value: 'Open', child: Text('Open')),
                          DropdownMenuItem(
                            value: 'Closed',
                            child: Text('Closed'),
                          ),
                        ],
                        onChanged: (v) => setState(() => _status = v ?? 'Open'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            FormSection(
              title: 'PAYMENT',
              children: [
                FormRow(
                  children: [
                    AppTextField(
                      controller: _amount,
                      label: 'Amount',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (v) => Validate.amount(v, 'Amount'),
                    ),
                    AppTextField(
                      controller: _balance,
                      label: 'Balance',
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (v) => Validate.amount(v, 'Balance'),
                    ),
                  ],
                ),
                AppTextField(
                  controller: _remarks,
                  label: 'Remarks',
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                ),
              ],
            ),
            if (!_isEdit) ...[
              AgreementCard(
                title: 'AGREEMENT PHOTO (OPTIONAL)',
                image: _pendingPhoto?.image,
                rentalLabel: 'new rental',
                busy: _photoBusy,
                onTakePhoto: () => _capturePhoto(ImageSource.camera),
                onChooseFromGallery: () => _capturePhoto(ImageSource.gallery),
                onRemove: _pendingPhoto == null
                    ? null
                    : () => setState(() => _pendingPhoto = null),
              ),
              const SizedBox(height: 16),
            ],
            FormSection(
              title: 'REFERENCE (OPTIONAL)',
              children: [
                AppTextField(
                  controller: _refName,
                  label: 'Reference name',
                  textCapitalization: TextCapitalization.words,
                ),
                FormRow(
                  children: [
                    AppTextField(
                      controller: _refContact,
                      label: 'Contact',
                      keyboardType: TextInputType.phone,
                      validator: Validate.phone,
                    ),
                    AppTextField(
                      controller: _refRelation,
                      label: 'Relation',
                      textCapitalization: TextCapitalization.words,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberBanner(ThemeData theme) {
    if (_isEdit) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                RentalNumberBadge(rental: widget.rental!),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Rental number is read-only and can never be changed.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(
                  Icons.lock_outline,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.schedule, color: theme.colorScheme.tertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Saved offline as "Pending" — the backend assigns the next '
                  'permanent number on sync. Retired and skipped numbers are '
                  'never reused.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _text(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }
}

enum _DuplicateChoice { useExisting, createSeparate, cancel }

String _numberText(Object? value) {
  if (value == null) return '';
  if (value is num && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

class _PickerTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? value;
  final String? subtitle;
  final bool hasError;
  final VoidCallback onTap;

  const _PickerTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.subtitle,
    this.hasError = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hasError
                  ? theme.colorScheme.error
                  : theme.colorScheme.outlineVariant,
              width: hasError ? 1.6 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.labelMedium),
                    const SizedBox(height: 2),
                    Text(
                      value ?? 'Tap to select',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: value == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    if (value != null &&
                        subtitle != null &&
                        subtitle!.isNotEmpty)
                      Text(subtitle!, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

/// A searchable picker so attaching an existing customer/vehicle stays fast
/// even with thousands of records, with an inline path to create a new one.
class EntityPicker extends StatefulWidget {
  final String title;
  final Future<List<Map<String, Object?>>> Function() loadAll;
  final String Function(Map<String, Object?>) labelOf;
  final String Function(Map<String, Object?>) subtitleOf;
  final Widget Function() createNew;

  const EntityPicker({
    super.key,
    required this.title,
    required this.loadAll,
    required this.labelOf,
    required this.subtitleOf,
    required this.createNew,
  });

  @override
  State<EntityPicker> createState() => _EntityPickerState();
}

class _EntityPickerState extends State<EntityPicker> {
  late Future<List<Map<String, Object?>>> _future;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _future = widget.loadAll();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final saved = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => widget.createNew()),
                      );
                      if (saved == true && mounted) {
                        setState(() {
                          _future = widget.loadAll();
                        });
                      }
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Filter…',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => _filter = v.toLowerCase()),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: AsyncList<Map<String, Object?>>(
                future: _future,
                emptyMessage: 'Nothing here yet.',
                builder: (context, rows) {
                  final filtered = _filter.isEmpty
                      ? rows
                      : rows
                          .where((r) =>
                              widget
                                  .labelOf(r)
                                  .toLowerCase()
                                  .contains(_filter) ||
                              widget
                                  .subtitleOf(r)
                                  .toLowerCase()
                                  .contains(_filter))
                          .toList();
                  if (filtered.isEmpty) {
                    return const EmptyState(
                      icon: Icons.search_off,
                      message: 'No match.',
                    );
                  }
                  return ListView.builder(
                    controller: scrollController,
                    itemCount: filtered.length,
                    itemBuilder: (context, i) => ListTile(
                      title: Text(widget.labelOf(filtered[i])),
                      subtitle: Text(widget.subtitleOf(filtered[i])),
                      onTap: () => Navigator.pop(context, filtered[i]),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
