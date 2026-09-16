import 'package:flutter/material.dart';

/// The sign-in look: the studio photo behind a dark gradient, the business
/// logo, and a translucent card holding whatever the screen needs. Used by
/// the password screen and the fingerprint lock screen so both feel like
/// the same front door.
class BrandBackdrop extends StatelessWidget {
  final Widget child;
  final String? subtitle;

  const BrandBackdrop({super.key, required this.child, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final dark = base.copyWith(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: base.colorScheme.primary,
        brightness: Brightness.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
        ),
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.75)),
        prefixIconColor: Colors.white.withValues(alpha: 0.7),
        suffixIconColor: Colors.white.withValues(alpha: 0.7),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F14),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/brand/login_bg.jpg',
            fit: BoxFit.cover,
            alignment: Alignment.center,
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: Color(0xFF0B0F14),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xB3000000),
                  Color(0x66000000),
                  Color(0xD9000000)
                ],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Theme(
                    data: dark,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Image.asset(
                          'assets/brand/logo.png',
                          height: 120,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.directions_car,
                            size: 64,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Burhan Rent-A-Car',
                          textAlign: TextAlign.center,
                          style: dark.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            textAlign: TextAlign.center,
                            style: dark.textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF0E141B).withValues(alpha: 0.84),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.10),
                            ),
                          ),
                          child: child,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
