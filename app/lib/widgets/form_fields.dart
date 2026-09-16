import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared form building blocks, so every form validates and formats the
/// same way. Dates are always stored as ISO `YYYY-MM-DD` and times in the
/// same `h:mm AM/PM` shape the source data uses, regardless of how the user
/// picked them.

class FormSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const FormSection({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Standard spacing wrapper so fields never sit flush against each other.
class FormRow extends StatelessWidget {
  final List<Widget> children;

  const FormRow({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: children[i]),
          ],
        ],
      ),
    );
  }
}

class AppTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helper;
  final bool required;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final bool readOnly;

  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.helper,
    this.required = false,
    this.maxLines = 1,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.validator,
    this.readOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        readOnly: readOnly,
        maxLines: maxLines,
        keyboardType: keyboardType,
        textCapitalization: textCapitalization,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          hintText: hint,
          helperText: helper,
          filled: true,
          fillColor: readOnly
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Colors.white,
        ),
        validator: (value) {
          if (required && (value == null || value.trim().isEmpty)) {
            return '$label is required';
          }
          return validator?.call(value);
        },
      ),
    );
  }
}

/// Tap-to-pick date field. Never free-typed, so a malformed date can't be
/// entered; the stored value is always ISO `YYYY-MM-DD`.
class AppDateField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final bool required;
  final String? helper;
  final String? Function(String?)? validator;

  const AppDateField({
    super.key,
    required this.controller,
    required this.label,
    this.required = false,
    this.helper,
    this.validator,
  });

  @override
  State<AppDateField> createState() => _AppDateFieldState();
}

class _AppDateFieldState extends State<AppDateField> {
  Future<void> _pick() async {
    final current = DateTime.tryParse(widget.controller.text.trim());
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        widget.controller.text = formatIsoDate(picked);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasValue = widget.controller.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: widget.controller,
        readOnly: true,
        onTap: _pick,
        decoration: InputDecoration(
          labelText: widget.required ? '${widget.label} *' : widget.label,
          helperText: widget.helper,
          hintText: 'YYYY-MM-DD',
          prefixIcon: const Icon(Icons.calendar_today_outlined, size: 20),
          suffixIcon: hasValue
              ? IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => setState(() {
                    widget.controller.clear();
                  }),
                )
              : null,
        ),
        validator: (value) {
          if (widget.required && (value == null || value.trim().isEmpty)) {
            return '${widget.label} is required';
          }
          return widget.validator?.call(value);
        },
      ),
    );
  }
}

/// Tap-to-pick time field, stored in the same `h:mm AM/PM` shape as the
/// source data.
class AppTimeField extends StatefulWidget {
  final TextEditingController controller;
  final String label;

  const AppTimeField({
    super.key,
    required this.controller,
    required this.label,
  });

  @override
  State<AppTimeField> createState() => _AppTimeFieldState();
}

class _AppTimeFieldState extends State<AppTimeField> {
  Future<void> _pick() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked != null && mounted) {
      setState(() {
        widget.controller.text = formatTimeOfDay(context, picked);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasValue = widget.controller.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: widget.controller,
        readOnly: true,
        onTap: _pick,
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: const Icon(Icons.schedule, size: 20),
          suffixIcon: hasValue
              ? IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => setState(() {
                    widget.controller.clear();
                  }),
                )
              : null,
        ),
      ),
    );
  }
}

/// Save/Cancel pinned to the bottom of the screen. Long forms scroll, so a
/// submit button placed at the end of the list would be off-screen most of
/// the time -- the primary action should never require scrolling to reach.
class FormActionBar extends StatelessWidget {
  final String saveLabel;
  final bool saving;
  final VoidCallback onSave;

  const FormActionBar({
    super.key,
    required this.saveLabel,
    required this.saving,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: saving ? null : () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: saving ? null : onSave,
                child: Text(saving ? 'Saving…' : saveLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatIsoDate(DateTime date) {
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${date.year}-$m-$d';
}

String formatTimeOfDay(BuildContext context, TimeOfDay time) {
  return MaterialLocalizations.of(context).formatTimeOfDay(
    time,
    alwaysUse24HourFormat: false,
  );
}

/// Validators shared across forms.
class Validate {
  /// A number that must be zero or positive when present.
  static String? amount(String? value, String label) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = double.tryParse(text);
    if (parsed == null) return '$label must be a number';
    if (parsed < 0) return '$label cannot be negative';
    return null;
  }

  static String? positiveInt(String? value, String label) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = int.tryParse(text);
    if (parsed == null) return '$label must be a whole number';
    if (parsed <= 0) return '$label must be at least 1';
    return null;
  }

  /// Phone numbers are stored as typed, but an obviously wrong length is
  /// worth catching at entry -- the digits are what search matches on.
  static String? phone(String? value) {
    final digits = (value ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    if (digits.length < 10 || digits.length > 13) {
      return 'Phone should be 10-13 digits';
    }
    return null;
  }

  static String? cnic(String? value) {
    final digits = (value ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    if (digits.length != 13) return 'CNIC should be 13 digits';
    return null;
  }

  /// Return date may not precede the start date. Pure so it can be tested
  /// directly -- the date fields themselves are tap-to-pick and read-only,
  /// so they can't be driven by typing.
  static String? dateOrder(String? endValue, String? startValue) {
    final end = DateTime.tryParse(endValue?.trim() ?? '');
    final start = DateTime.tryParse(startValue?.trim() ?? '');
    if (end == null || start == null) return null;
    if (end.isBefore(start)) return 'Return date is before the start date';
    return null;
  }

  static String? year(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = int.tryParse(text);
    if (parsed == null) return 'Year must be a number';
    if (parsed < 1950 || parsed > DateTime.now().year + 1) {
      return 'Enter a valid year';
    }
    return null;
  }
}
