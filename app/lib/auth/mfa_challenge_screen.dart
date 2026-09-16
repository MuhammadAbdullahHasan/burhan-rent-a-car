import 'package:flutter/material.dart';
import 'auth_error_message.dart';
import 'auth_service.dart';
import 'mfa_code_field.dart';

/// The second step on every sign-in: a code from the already-enrolled
/// authenticator app. No email, no network round-trip to send anything --
/// the code is generated on the user's own device.
class MfaChallengeScreen extends StatefulWidget {
  final AuthService authService;
  final String factorId;
  final VoidCallback onVerified;

  const MfaChallengeScreen({
    super.key,
    required this.authService,
    required this.factorId,
    required this.onVerified,
  });

  @override
  State<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends State<MfaChallengeScreen> {
  final _code = TextEditingController();
  bool _verifying = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your app');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await widget.authService.verifyTotp(
        factorId: widget.factorId,
        code: code,
      );
      widget.onVerified();
    } catch (e) {
      setState(() => _error = authErrorMessage(e, fallback: 'Could not verify the code.'));
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Verify it's you"),
        actions: [
          TextButton(
            onPressed: () => widget.authService.signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.phonelink_lock_outlined,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Authenticator code',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Open your authenticator app and enter the current '
                    '6-digit code for Burhan Rent-A-Car.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  MfaCodeField(
                    controller: _code,
                    autofocus: true,
                    onSubmitted: _verify,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _verifying ? null : _verify,
                    child: Text(_verifying ? 'Verifying…' : 'Verify'),
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
