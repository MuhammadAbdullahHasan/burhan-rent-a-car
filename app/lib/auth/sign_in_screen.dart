import 'package:flutter/material.dart';
import 'auth_error_message.dart';
import 'auth_service.dart';
import 'brand_backdrop.dart';
import 'forgot_password_screen.dart';
import 'sign_up_screen.dart';

class SignInScreen extends StatefulWidget {
  final AuthService authService;

  const SignInScreen({super.key, required this.authService});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  String? _error;
  bool _unconfirmed = false;
  bool _resent = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
      _unconfirmed = false;
      _resent = false;
    });
    try {
      await widget.authService.signInWithPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
      // On success the auth stream in main.dart moves the app to the
      // second step on its own -- nothing further to do here.
    } catch (e) {
      // An unconfirmed account gets a resend action; everything else is a
      // plain message the owner can act on.
      setState(() {
        _unconfirmed = isUnconfirmedEmailError(e);
        _error = authErrorMessage(e, fallback: 'Could not sign in.');
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resendConfirmation() async {
    setState(() => _loading = true);
    try {
      await widget.authService.resendConfirmation(_email.text.trim());
      setState(() {
        _resent = true;
        _error = 'Confirmation email sent again to ${_email.text.trim()}.';
      });
    } catch (e) {
      setState(() => _error = authErrorMessage(
            e,
            fallback: 'Could not resend the confirmation email.',
          ));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    return BrandBackdrop(
      subtitle: 'Sign in to continue',
      child: Builder(builder: (context) {
        final theme = Theme.of(context);
        return Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _error!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                      if (_unconfirmed && !_resent)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _loading ? null : _resendConfirmation,
                            child: const Text(
                              'Resend confirmation email',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _email,
                enabled: !_loading,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                autovalidateMode: AutovalidateMode.onUserInteraction,
                onChanged: (_) => _clearError(),
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
                validator: (v) {
                  final value = v?.trim() ?? '';
                  if (value.isEmpty) return 'Enter your email';
                  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
                    return 'Enter a valid email address';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                enabled: !_loading,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                onChanged: (_) => _clearError(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Enter your password' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _loading
                      ? null
                      : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ForgotPasswordScreen(
                                authService: widget.authService,
                              ),
                            ),
                          ),
                  child: const Text('Forgot password?'),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _loading ? null : _submit,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                        ),
                      )
                    : const Text('Sign In'),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _loading
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => SignUpScreen(
                              authService: widget.authService,
                            ),
                          ),
                        ),
                child: const Text("Don't have an account? Sign up"),
              ),
            ],
          ),
        );
      }),
    );
  }
}
