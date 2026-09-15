import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_service.dart';

/// Second factor: a 6-digit code emailed to the already-authenticated
/// user, required before the app unlocks. Sends the code automatically on
/// first appearance.
class OtpVerificationScreen extends StatefulWidget {
  final AuthService authService;
  final String email;
  final VoidCallback onVerified;

  const OtpVerificationScreen({
    super.key,
    required this.authService,
    required this.email,
    required this.onVerified,
  });

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  final _code = TextEditingController();
  bool _sending = true;
  bool _verifying = false;
  String? _error;
  int _resendCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _send();
  }

  @override
  void dispose() {
    _code.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.authService.sendOtp();
      _startCooldown();
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not send the code: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _startCooldown() {
    setState(() => _resendCooldown = 30);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _resendCooldown -= 1;
        if (_resendCooldown <= 0) timer.cancel();
      });
    });
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code');
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await widget.authService.verifyOtp(code);
      widget.onVerified();
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not verify the code: $e');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify it\'s you'),
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
                    Icons.mark_email_unread_outlined,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Enter verification code',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _sending
                        ? 'Sending a code to ${widget.email}…'
                        : 'We sent a 6-digit code to ${widget.email}.',
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
                  TextField(
                    controller: _code,
                    enabled: !_sending,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      letterSpacing: 8,
                    ),
                    decoration: const InputDecoration(
                      hintText: '••••••',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _verify(),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: (_sending || _verifying) ? null : _verify,
                    child: Text(_verifying ? 'Verifying…' : 'Verify'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed:
                        (_sending || _resendCooldown > 0) ? null : _send,
                    child: Text(
                      _resendCooldown > 0
                          ? 'Resend code in ${_resendCooldown}s'
                          : 'Resend code',
                    ),
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
