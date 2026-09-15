import 'package:flutter/material.dart';

import 'home_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';

/// The three top-level sections: Home, Universal Search, Library (vehicle
/// inventory). Nothing else lives at this level.
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
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          HomeScreen(),
          SearchScreen(),
          LibraryScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: goToTab,
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
      ),
    );
  }
}
