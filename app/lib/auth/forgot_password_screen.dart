import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_error_message.dart';
import 'email_rate_limit.dart';
import 'auth_service.dart';

class ForgotPasswordScreen extends StatefulWidget {
  final AuthService authService;

  const ForgotPasswordScreen({super.key, required this.authService});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _sent = false;

  /// Set when the server refused because the hourly email limit is hit:
  /// the exact moment it frees (from this device's own record) or, when
  /// the limit was used up elsewhere, the latest it can be.
  DateTime? _retryAt;
  bool _retryExact = true;

  Future<void> _noteRateLimit(Object error) async {
    final fromReply = error is AuthException
        ? EmailRateLimit.fromMessage(error.message)
        : null;
    final own = await EmailRateLimit.retryAt();
    if (!mounted) return;
    setState(() {
      if (fromReply != null) {
        _retryAt = DateTime.now().add(fromReply);
        _retryExact = true;
      } else if (own != null) {
        _retryAt = own.toLocal();
        _retryExact = true;
      } else {
        _retryAt = EmailRateLimit.latestPossible().toLocal();
        _retryExact = false;
      }
    });
  }

  Widget _retryNotice(ThemeData theme) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: RetryCountdown(
          until: _retryAt!,
          exact: _retryExact,
          onDone: () => setState(() => _retryAt = null),
        ),
      );

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.authService.sendPasswordResetEmail(_email.text.trim());
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (isEmailRateLimitError(e)) {
        await _noteRateLimit(e);
      } else {
        setState(() => _error =
            authErrorMessage(e, fallback: 'Could not send the reset email.'));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Reset Password')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: _sent
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.mark_email_read_outlined,
                          size: 48,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Check your email',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'If ${_email.text.trim()} has an account, a reset '
                          'link has been sent to it.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Back to sign in'),
                        ),
                      ],
                    )
                  : Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            "Enter the email on your account and we'll send "
                            'a link to reset your password.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 20),
                          if (_retryAt != null) ...[
                            _retryNotice(theme),
                            const SizedBox(height: 16),
                          ] else if (_error != null) ...[
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
                          TextFormField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            decoration:
                                const InputDecoration(labelText: 'Email'),
                            validator: (v) => (v == null || !v.contains('@'))
                                ? 'Enter a valid email'
                                : null,
                            onFieldSubmitted: (_) => _submit(),
                          ),
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed:
                                _loading || _retryAt != null ? null : _submit,
                            child: Text(
                              _loading ? 'Sending…' : 'Send Reset Link',
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
