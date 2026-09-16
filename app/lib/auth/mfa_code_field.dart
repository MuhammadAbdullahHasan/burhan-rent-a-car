import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The 6-digit authenticator code input, shared by enrolment and the
/// per-login challenge. Digits only, capped at six, submits on Enter.
class MfaCodeField extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSubmitted;
  final bool autofocus;

  const MfaCodeField({
    super.key,
    required this.controller,
    required this.onSubmitted,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(6),
      ],
      textAlign: TextAlign.center,
      style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 8),
      decoration: const InputDecoration(
        hintText: '••••••',
        counterText: '',
      ),
      onSubmitted: (_) => onSubmitted(),
    );
  }
}
