import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_error_message.dart';
import 'auth_service.dart';
import 'mfa_code_field.dart';

/// One-time setup of the authenticator app. Shows a QR code (and the raw
/// key for manual entry), then confirms with the first code the app
/// produces. Only reached when the signed-in user has no verified factor.
class MfaEnrollScreen extends StatefulWidget {
  final AuthService authService;
  final VoidCallback onEnrolled;

  const MfaEnrollScreen({
    super.key,
    required this.authService,
    required this.onEnrolled,
  });

  @override
  State<MfaEnrollScreen> createState() => _MfaEnrollScreenState();
}

class _MfaEnrollScreenState extends State<MfaEnrollScreen> {
  final _code = TextEditingController();
  AuthMFAEnrollResponse? _enrollment;
  bool _verifying = false;
  String? _error;
  bool _secretRevealed = false;

  @override
  void initState() {
    super.initState();
    _enroll();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _enroll() async {
    setState(() => _error = null);
    try {
      final response = await widget.authService.enrollTotp();
      if (response.totp == null) {
        throw StateError('Server returned no authenticator details.');
      }
      if (mounted) setState(() => _enrollment = response);
    } catch (e) {
      setState(() => _error = authErrorMessage(e, fallback: 'Could not start setup.'));
    }
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your app');
      return;
    }
    final enrollment = _enrollment;
    if (enrollment == null) return;

    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await widget.authService.verifyTotp(
        factorId: enrollment.id,
        code: code,
      );
      widget.onEnrolled();
    } catch (e) {
      setState(() => _error = authErrorMessage(e, fallback: 'Could not verify the code.'));
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enrollment = _enrollment;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up authenticator'),
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
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Protect your account',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Every sign-in will also ask for a code from an '
                    'authenticator app — Google Authenticator, Authy, '
                    'Microsoft Authenticator, or any similar app.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_error != null) ...[
                    _ErrorBox(_error!),
                    const SizedBox(height: 16),
                  ],
                  if (enrollment == null && _error == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (enrollment == null)
                    FilledButton(
                      onPressed: _enroll,
                      child: const Text('Try again'),
                    )
                  else ...[
                    _Step(
                      number: 1,
                      title: 'Scan this with your authenticator app',
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: QrImageView(
                            data: enrollment.totp!.uri,
                            size: 200,
                            backgroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton(
                        onPressed: () => setState(
                          () => _secretRevealed = !_secretRevealed,
                        ),
                        child: Text(
                          _secretRevealed
                              ? 'Hide setup key'
                              : "Can't scan? Enter the key manually",
                        ),
                      ),
                    ),
                    if (_secretRevealed)
                      _SecretKey(secret: enrollment.totp!.secret),
                    const SizedBox(height: 16),
                    _Step(
                      number: 2,
                      title: 'Enter the 6-digit code the app shows',
                      child: MfaCodeField(
                        controller: _code,
                        onSubmitted: _verify,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _verifying ? null : _verify,
                      child: Text(
                        _verifying ? 'Verifying…' : 'Confirm & Continue',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final String title;
  final Widget child;

  const _Step({required this.number, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: theme.colorScheme.primary,
              child: Text(
                '$number',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

class _SecretKey extends StatelessWidget {
  final String secret;

  const _SecretKey({required this.secret});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Group into blocks of 4 so it can be read off and typed reliably.
    final grouped = RegExp('.{1,4}')
        .allMatches(secret)
        .map((m) => m.group(0))
        .join(' ');
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              grouped,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 1,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: secret));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Setup key copied')),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;

  const _ErrorBox(this.message);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: TextStyle(color: theme.colorScheme.onErrorContainer),
      ),
    );
  }
}
