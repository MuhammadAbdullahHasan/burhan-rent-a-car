import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// The Home / Search / Library frame.
///
/// The studio photograph is a real header, not a fixed band: it collapses
/// as the content scrolls up (parallax, so touch and content move
/// together), settles into a compact dark toolbar the content slides
/// under, and stretches when pulled past the top -- a soft boundary, not
/// a hard stop. All of it is driven by the scroll position itself, so it
/// tracks the finger 1:1 and can be reversed at any instant.
///
/// The photo fades into the page colour, so there is no seam between
/// header and content. Under reduced motion the parallax and stretch are
/// off; the header still collapses, just without the depth effects.
class ShowroomScaffold extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  final List<Widget> slivers;
  final Widget? floatingActionButton;
  final Future<void> Function()? onRefresh;

  static const double expandedHeight = 236;

  const ShowroomScaffold({
    super.key,
    required this.title,
    required this.slivers,
    this.actions,
    this.floatingActionButton,
    this.onRefresh,
  });

  /// Bottom inset content needs so the last item clears the floating
  /// navigation bar and, when present, the action button.
  static double bottomInset(BuildContext context, {bool hasFab = false}) =>
      MediaQuery.paddingOf(context).bottom + 20 + (hasFab ? 72 : 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = MediaQuery.disableAnimationsOf(context);
    final ground = theme.scaffoldBackgroundColor;

    final scroll = CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        SliverAppBar(
          pinned: true,
          stretch: !reduced,
          expandedHeight: expandedHeight,
          backgroundColor: ground,
          surfaceTintColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          actions: actions,
          flexibleSpace: FlexibleSpaceBar(
            collapseMode: reduced ? CollapseMode.none : CollapseMode.parallax,
            stretchModes: const [
              StretchMode.zoomBackground,
              StretchMode.fadeTitle,
            ],
            centerTitle: false,
            expandedTitleScale: 1.45,
            titlePadding: const EdgeInsetsDirectional.only(
              start: 16,
              bottom: 14,
              end: 16,
            ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                height: 1.1,
                shadows: [
                  Shadow(color: Color(0x99000000), blurRadius: 12),
                ],
              ),
            ),
            background: DecoratedBox(
              decoration: const BoxDecoration(
                color: kShowroomGround,
                image: DecorationImage(
                  image: AssetImage('assets/brand/login_bg.jpg'),
                  fit: BoxFit.cover,
                  alignment: Alignment(0, -0.45),
                ),
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0, 0.45, 1],
                    colors: [
                      const Color(0xFF060A0E).withValues(alpha: 0.42),
                      const Color(0xFF060A0E).withValues(alpha: 0.30),
                      ground,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        ...slivers,
      ],
    );

    // This frame sits inside the shell's Scaffold, whose translucent bar
    // extends under it; a nested Scaffold does not lift its own action
    // button above that bar, so the inset is applied here.
    final barInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      extendBody: true,
      floatingActionButton: floatingActionButton == null
          ? null
          : Padding(
              padding: EdgeInsets.only(bottom: barInset),
              child: floatingActionButton,
            ),
      body: onRefresh == null
          ? scroll
          : RefreshIndicator(
              onRefresh: onRefresh!,
              edgeOffset: MediaQuery.paddingOf(context).top + kToolbarHeight,
              color: theme.colorScheme.primary,
              backgroundColor: kShowroomSurfaceHigh,
              child: scroll,
            ),
    );
  }
}
