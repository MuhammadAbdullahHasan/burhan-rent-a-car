import 'package:flutter/material.dart';

import 'app_services.dart';
import 'screens/shell_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BurhanApp());
}

class BurhanApp extends StatefulWidget {
  /// Tests inject an already-open (FFI) database; production passes null and
  /// the app opens the on-device one.
  final AppServices? services;

  const BurhanApp({super.key, this.services});

  @override
  State<BurhanApp> createState() => _BurhanAppState();
}

class _BurhanAppState extends State<BurhanApp> {
  late final Future<AppServices> _servicesFuture;

  @override
  void initState() {
    super.initState();
    _servicesFuture = widget.services != null
        ? Future.value(widget.services)
        : AppServices.bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = buildAppTheme();
    return FutureBuilder<AppServices>(
      future: _servicesFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return MaterialApp(
            theme: theme,
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not open the database:\n${snapshot.error}'),
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return MaterialApp(
            theme: theme,
            debugShowCheckedModeBanner: false,
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        // AppScope must sit ABOVE MaterialApp: the Navigator lives inside
        // MaterialApp, so anything pushed onto it is a sibling of `home`,
        // not a descendant. With the scope below MaterialApp, every pushed
        // detail screen would fail its AppScope lookup.
        return AppScope(
          services: snapshot.data!,
          child: MaterialApp(
            title: 'Burhan Rent-A-Car',
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: const ShellScreen(),
          ),
        );
      },
    );
  }
}
