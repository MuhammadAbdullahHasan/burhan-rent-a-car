import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../widgets/form_fields.dart';

/// Create or edit a customer. Normalized search columns are derived here
/// using the data layer's own normalizers, so a hand-typed record is
/// searchable exactly like an imported one.
class CustomerFormScreen extends StatefulWidget {
  final Map<String, Object?>? customer;

  const CustomerFormScreen({super.key, this.customer});

  @override
  State<CustomerFormScreen> createState() => _CustomerFormScreenState();
}

class _CustomerFormScreenState extends State<CustomerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _cnic;
  late final TextEditingController _license;
  late final TextEditingController _licenseCity;
  bool _saving = false;

  bool get _isEdit => widget.customer != null;

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    _name = TextEditingController(text: c?['full_name'] as String? ?? '');
    _phone = TextEditingController(text: c?['phone'] as String? ?? '');
    _cnic = TextEditingController(text: c?['cnic'] as String? ?? '');
    _license = TextEditingController(text: c?['license_no'] as String? ?? '');
    _licenseCity =
        TextEditingController(text: c?['license_city'] as String? ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _cnic, _license, _licenseCity]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Mirrors the import pipeline's conservative matching: phone first, then
  /// CNIC, never name alone. Warns rather than blocks -- two people can
  /// legitimately share a landline, and the owner decides.
  Future<Map<String, Object?>?> _findExisting(AppServices services) async {
    final match = await services.customers.findByPhoneOrCnic(
      services.db,
      phoneNormalized: normalizeDigits(_phone.text),
      cnicNormalized: normalizeDigits(_cnic.text),
    );
    if (match == null) return null;
    if (_isEdit && match['id'] == widget.customer!['id']) return null;
    return match;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final duplicate = await _findExisting(services);
      if (duplicate != null && mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Possible duplicate'),
            content: Text(
              '${displayOrNA(duplicate['full_name'])} already has this '
              'phone or CNIC.\n\nSaving creates a second, separate customer '
              'record. Existing rentals are never merged or moved.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save anyway'),
              ),
            ],
          ),
        );
        if (proceed != true) {
          if (mounted) setState(() => _saving = false);
          return;
        }
      }

      final fields = <String, Object?>{
        'full_name': _nullIfBlank(_name.text),
        'phone': _nullIfBlank(_phone.text),
        'phone_normalized': normalizeDigits(_phone.text),
        'cnic': _nullIfBlank(_cnic.text),
        'cnic_normalized': normalizeDigits(_cnic.text),
        'license_no': _nullIfBlank(_license.text),
        'license_city': _nullIfBlank(_licenseCity.text),
      };

      if (_isEdit) {
        await services.engine.updateCustomer(
          services.db,
          widget.customer!['id'] as String,
          fields,
        );
      } else {
        await services.engine.createCustomer(
          services.db,
          fullName: fields['full_name'] as String?,
          phone: fields['phone'] as String?,
          phoneNormalized: fields['phone_normalized'] as String?,
          cnic: fields['cnic'] as String?,
          cnicNormalized: fields['cnic_normalized'] as String?,
          licenseNo: fields['license_no'] as String?,
          licenseCity: fields['license_city'] as String?,
        );
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _isEdit ? 'Customer updated.' : 'Customer added.',
          ),
        ),
      );
      navigator.pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save the customer: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Customer' : 'New Customer')),
      bottomNavigationBar: FormActionBar(
        saveLabel: 'Save Customer',
        saving: _saving,
        onSave: _save,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            FormSection(
              title: 'IDENTITY',
              children: [
                AppTextField(
                  controller: _name,
                  label: 'Full name',
                  required: true,
                  textCapitalization: TextCapitalization.words,
                ),
                AppTextField(
                  controller: _phone,
                  label: 'Phone',
                  keyboardType: TextInputType.phone,
                  validator: Validate.phone,
                  helper: 'Used to match repeat customers',
                ),
                AppTextField(
                  controller: _cnic,
                  label: 'CNIC',
                  hint: '42201-1234567-1',
                  keyboardType: TextInputType.text,
                  validator: Validate.cnic,
                ),
              ],
            ),
            FormSection(
              title: 'LICENCE',
              children: [
                AppTextField(
                  controller: _license,
                  label: 'License #',
                ),
                AppTextField(
                  controller: _licenseCity,
                  label: 'License city',
                  textCapitalization: TextCapitalization.words,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Leave anything unknown blank — empty fields display as N/A '
                'rather than being guessed.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _nullIfBlank(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
