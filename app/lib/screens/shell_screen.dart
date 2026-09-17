import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';

/// The three top-level sections: Home, Universal Search, Library (vehicle
/// inventory). Nothing else lives at this level.
///
/// The bar is a translucent material the content scrolls beneath -- a
/// floating layer of chrome, not an opaque strip that eats the bottom of
/// every screen. The bright hairline on its top edge is light catching the
/// material. Under reduced transparency it goes near-solid.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => ShellScreenState();
}

class ShellScreenState extends State<ShellScreen> {
  int _index = 0;

  void goToTab(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frosted = !MediaQuery.disableAnimationsOf(context);
    final bar = NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: goToTab,
      backgroundColor: kShowroomGround.withValues(alpha: frosted ? 0.74 : 0.97),
      surfaceTintColor: Colors.transparent,
      indicatorColor: theme.colorScheme.primary.withValues(alpha: 0.22),
      elevation: 0,
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.dashboard_outlined),
          selectedIcon: Icon(Icons.dashboard),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.search_outlined),
          selectedIcon: Icon(Icons.search),
          label: 'Search',
        ),
        NavigationDestination(
          icon: Icon(Icons.directions_car_outlined),
          selectedIcon: Icon(Icons.directions_car),
          label: 'Library',
        ),
      ],
    );

    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _index,
        children: const [
          HomeScreen(),
          SearchScreen(),
          LibraryScreen(),
        ],
      ),
      bottomNavigationBar: ClipRect(
        child: BackdropFilter(
          filter: frosted
              ? ImageFilter.blur(sigmaX: 18, sigmaY: 18)
              : ImageFilter.blur(sigmaX: 0, sigmaY: 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                height: 1,
                child: ColoredBox(color: kShowroomEdgeBright),
              ),
              bar,
            ],
          ),
        ),
      ),
    );
  }
}
