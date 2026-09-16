import 'package:flutter/material.dart';

import 'biometric_service.dart';
import 'brand_backdrop.dart';

/// Shown on launch when a saved sign-in exists and biometric unlock is on.
/// Prompts immediately; the owner can retry, or fall back to the password
/// (which discards the saved session).
class LockScreen extends StatefulWidget {
  final BiometricService biometrics;
  final String? email;
  final VoidCallback onUnlocked;
  final Future<void> Function() onUsePassword;

  const LockScreen({
    super.key,
    required this.biometrics,
    required this.email,
    required this.onUnlocked,
    required this.onUsePassword,
  });

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _checking = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    // Prompt as soon as the screen is up, without waiting for a tap.
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _failed = false;
    });
    final ok = await widget.biometrics.authenticate(
      'Unlock Burhan Rent-A-Car',
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      _failed = !ok;
    });
    if (ok) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    return BrandBackdrop(
      subtitle: widget.email == null
          ? 'Unlock to continue'
          : 'Signed in as ${widget.email}',
      child: Builder(builder: (context) {
        final theme = Theme.of(context);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.fingerprint,
              size: 56,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            if (_failed) ...[
              Text(
                "Couldn't verify. Try again, or use your password.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: _checking ? null : _unlock,
              icon: const Icon(Icons.fingerprint),
              label: Text(
                _checking ? 'Waiting…' : 'Unlock with fingerprint / face',
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _checking ? null : widget.onUsePassword,
              child: const Text('Use password instead'),
            ),
          ],
        );
      }),
    );
  }
}
