import 'package:flutter/material.dart';

/// The Home / Search / Library frame: the studio car photograph, darkened,
/// behind the app bar and a short strip beneath it, fading into the flat
/// page colour where the content begins. The content scrolls in its own
/// region below the band, so nothing ever slides over the photo and the
/// white title always sits on a dark ground.
class ShowroomScaffold extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  final Widget body;
  final Widget? floatingActionButton;

  /// How much photograph shows beneath the toolbar before the content.
  static const double reveal = 96;

  const ShowroomScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topInset = MediaQuery.paddingOf(context).top;
    final bandHeight = topInset + kToolbarHeight + reveal;
    final page = theme.scaffoldBackgroundColor;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
          color: Colors.white,
        ),
        title: Text(title),
        actions: actions,
      ),
      floatingActionButton: floatingActionButton,
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: bandHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF0B0F14),
                image: const DecorationImage(
                  image: AssetImage('assets/brand/login_bg.jpg'),
                  fit: BoxFit.cover,
                  alignment: Alignment(0, -0.55),
                ),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.55, 1],
                    colors: [
                      const Color(0xFF060A0E).withValues(alpha: 0.45),
                      const Color(0xFF060A0E).withValues(alpha: 0.72),
                      page,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            top: bandHeight,
            child: body,
          ),
        ],
      ),
    );
  }
}
