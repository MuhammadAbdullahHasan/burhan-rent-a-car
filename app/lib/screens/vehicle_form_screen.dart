import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../widgets/form_fields.dart';

class VehicleFormScreen extends StatefulWidget {
  final Map<String, Object?>? vehicle;

  const VehicleFormScreen({super.key, this.vehicle});

  @override
  State<VehicleFormScreen> createState() => _VehicleFormScreenState();
}

class _VehicleFormScreenState extends State<VehicleFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  bool _saving = false;

  bool get _isEdit => widget.vehicle != null;

  static const _keys = [
    'registration_no',
    'company',
    'model_name',
    'trim',
    'horsepower',
    'color',
    'reg_year',
    'chassis_no',
    'engine_no',
    'insurance_due_on',
  ];

  @override
  void initState() {
    super.initState();
    final v = widget.vehicle;
    _fields = {
      for (final key in _keys)
        key: TextEditingController(text: v?[key]?.toString() ?? ''),
    };
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final services = AppScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final registration = _value('registration_no');
    final registrationNorm = normalizeRegistration(registration ?? '');

    try {
      // Registration is the vehicle's real-world unique key, and the column
      // is UNIQUE -- refuse rather than let the insert fail.
      if (registrationNorm != null) {
        final existing = await services.vehicles.findByRegistrationNorm(
          services.db,
          registrationNorm,
        );
        final isSameRecord = _isEdit &&
            existing != null &&
            existing['id'] == widget.vehicle!['id'];
        if (existing != null && !isSameRecord) {
          setState(() => _saving = false);
          messenger.showSnackBar(
            SnackBar(
              content: Text('$registration is already in the inventory.'),
            ),
          );
          return;
        }
      }

      final fields = <String, Object?>{
        'registration_no': registration,
        'registration_norm': registrationNorm,
        'company': _value('company'),
        'model_name': _value('model_name'),
        'trim': _value('trim'),
        'horsepower': _value('horsepower'),
        'color': _value('color'),
        'reg_year': int.tryParse(_value('reg_year') ?? ''),
        'chassis_no': _value('chassis_no'),
        'engine_no': _value('engine_no'),
        'insurance_due_on': _value('insurance_due_on'),
      };

      if (_isEdit) {
        await services.engine.updateVehicle(
          services.db,
          widget.vehicle!['id'] as String,
          fields,
        );
      } else {
        await services.engine.createVehicle(
          services.db,
          registrationNo: fields['registration_no'] as String?,
          registrationNorm: fields['registration_norm'] as String?,
          company: fields['company'] as String?,
          modelName: fields['model_name'] as String?,
          trim: fields['trim'] as String?,
          horsepower: fields['horsepower'] as String?,
          color: fields['color'] as String?,
          regYear: fields['reg_year'] as int?,
          chassisNo: fields['chassis_no'] as String?,
          engineNo: fields['engine_no'] as String?,
          insuranceDueOn: fields['insurance_due_on'] as String?,
        );
      }
      messenger.showSnackBar(
        SnackBar(content: Text(_isEdit ? 'Vehicle updated.' : 'Vehicle added.')),
      );
      navigator.pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save the vehicle: $error')),
      );
    }
  }

  String? _value(String key) {
    final text = _fields[key]!.text.trim();
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Vehicle' : 'New Vehicle')),
      bottomNavigationBar: FormActionBar(
        saveLabel: 'Save Vehicle',
        saving: _saving,
        onSave: _save,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            FormSection(
              title: 'IDENTIFICATION',
              children: [
                AppTextField(
                  controller: _fields['registration_no']!,
                  label: 'Registration number',
                  hint: 'ABC-123',
                  required: true,
                  textCapitalization: TextCapitalization.characters,
                  helper: 'Must be unique across the inventory',
                ),
                FormRow(
                  children: [
                    AppTextField(
                      controller: _fields['chassis_no']!,
                      label: 'Chassis #',
                      textCapitalization: TextCapitalization.characters,
                    ),
                    AppTextField(
                      controller: _fields['engine_no']!,
                      label: 'Engine #',
                      textCapitalization: TextCapitalization.characters,
                    ),
                  ],
                ),
              ],
            ),
            FormSection(
              title: 'SPECIFICATION',
              children: [
                FormRow(
                  children: [
                    AppTextField(
                      controller: _fields['company']!,
                      label: 'Company',
                      textCapitalization: TextCapitalization.words,
                    ),
                    AppTextField(
                      controller: _fields['model_name']!,
                      label: 'Model',
                      textCapitalization: TextCapitalization.words,
                    ),
                  ],
                ),
                FormRow(
                  children: [
                    AppTextField(
                      controller: _fields['trim']!,
                      label: 'Trim',
                    ),
                    AppTextField(
                      controller: _fields['horsepower']!,
                      label: 'Horsepower',
                    ),
                  ],
                ),
                FormRow(
                  children: [
                    AppTextField(
                      controller: _fields['color']!,
                      label: 'Color',
                      textCapitalization: TextCapitalization.words,
                    ),
                    AppTextField(
                      controller: _fields['reg_year']!,
                      label: 'Registration year',
                      keyboardType: TextInputType.number,
                      validator: Validate.year,
                    ),
                  ],
                ),
              ],
            ),
            FormSection(
              title: 'INSURANCE',
              children: [
                AppDateField(
                  controller: _fields['insurance_due_on']!,
                  label: 'Insurance due on',
                  helper: 'Shown on the Home dashboard when it falls due',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
