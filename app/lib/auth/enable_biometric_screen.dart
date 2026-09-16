import 'package:flutter/material.dart';

import 'biometric_service.dart';

/// Offered once, right after a password sign-in on a phone that has a
/// fingerprint or face enrolled. Either answer is remembered; "Not now" can
/// be reversed from the Home menu.
class EnableBiometricScreen extends StatefulWidget {
  final BiometricService biometrics;
  final VoidCallback onDone;

  const EnableBiometricScreen({
    super.key,
    required this.biometrics,
    required this.onDone,
  });

  @override
  State<EnableBiometricScreen> createState() => _EnableBiometricScreenState();
}

class _EnableBiometricScreenState extends State<EnableBiometricScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _enable() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // Confirm it actually works on this phone before relying on it.
    final ok = await widget.biometrics.authenticate(
      'Confirm to turn on fingerprint / face sign-in',
    );
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = "Couldn't verify. You can try again or skip for now.";
      });
      return;
    }
    await widget.biometrics.setEnabled(true);
    widget.onDone();
  }

  Future<void> _skip() async {
    await widget.biometrics.setEnabled(false);
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.fingerprint,
                    size: 72,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Sign in faster next time',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use your fingerprint or face to open the app instead '
                    'of typing your password each time. Your password still '
                    'works, and you can turn this off later from the Home '
                    'menu.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  FilledButton.icon(
                    onPressed: _busy ? null : _enable,
                    icon: const Icon(Icons.fingerprint),
                    label: Text(
                      _busy ? 'Confirming…' : 'Turn on fingerprint / face',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy ? null : _skip,
                    child: const Text('Not now'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
