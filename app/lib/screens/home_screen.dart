import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../sync/cloud_sync_engine.dart';
import '../sync/sync_actions.dart';
import '../auth/biometric_service.dart';
import '../widgets/common.dart';
import '../widgets/rental_tile.dart';
import 'rental_detail_screen.dart';
import 'rental_form_screen.dart';
import 'shell_screen.dart';
import 'vehicle_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<_Dashboard> _future;
  ValueNotifier<int>? _dataChanged;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
    final notifier = AppScope.of(context).dataChanged;
    if (!identical(notifier, _dataChanged)) {
      _dataChanged?.removeListener(_reload);
      _dataChanged = notifier..addListener(_reload);
    }
  }

  @override
  void dispose() {
    _dataChanged?.removeListener(_reload);
    super.dispose();
  }

  Future<_Dashboard> _load() async {
    final services = AppScope.of(context);
    final db = services.db;
    return _Dashboard(
      unclosed: await services.rentals.unclosed(db, limit: 5),
      unclosedTotal: await services.rentals.countWhere(
        db,
        "is_deleted = 0 AND is_placeholder = 0 "
        "AND LOWER(COALESCE(status, '')) != 'closed'",
      ),
      recent: await services.rentals.recent(db, limit: 5),
      insuranceDue: await services.vehicles.insuranceDue(db, withinDays: 60),
      awaitingFirstDownload:
          services.cloudSync != null && !await CloudSyncEngine.isHydrated(db),
      pendingSync: (await db
              .rawQuery(
                "SELECT COUNT(*) AS c FROM sync_queue WHERE status = 'pending'",
              )
              .then((r) => r.first['c'] as int?)) ??
          0,
    );
  }

  void _reload() {
    // Block body on purpose: `setState(() => _future = _load())` would
    // return the Future from the callback, which trips a framework
    // assertion in debug builds.
    setState(() {
      _future = _load();
    });
  }

  Future<void> _syncNow() async {
    final services = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final message = await runSync(services);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
    _reload();
  }

  Future<void> _signOut() async {
    final signOut = AppScope.of(context).signOut;
    if (signOut == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your data stays on this device. You\'ll need your email and '
          'password to sign back in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed == true) await signOut();
  }

  Future<void> _newRental() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RentalFormScreen()),
    );
    if (created == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Burhan Rent-A-Car'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          if (AppScope.of(context).signOut != null)
            _AccountMenu(
              biometrics: AppScope.of(context).biometrics,
              onSignOut: _signOut,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newRental,
        icon: const Icon(Icons.add),
        label: const Text('New Rental'),
      ),
      body: FutureBuilder<_Dashboard>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.error_outline,
              message: 'Could not load this record:\n${snapshot.error}',
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: [
                _QuickNav(
                  onSearch: () => _shell(context)?.goToTab(1),
                  onLibrary: () => _shell(context)?.goToTab(2),
                ),
                const SizedBox(height: 16),
                if (data.notifications.isNotEmpty) ...[
                  SectionCard(
                    title: 'NEEDS ATTENTION',
                    child: Column(
                      children: [
                        for (final note in data.notifications)
                          _NotificationRow(
                            note: note,
                            onTap: note.isSyncPrompt
                                ? _syncNow
                                : note.vehicle == null
                                    ? null
                                    : () async {
                                        await Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => VehicleDetailScreen(
                                              vehicleId:
                                                  note.vehicle!['id'] as String,
                                            ),
                                          ),
                                        );
                                        _reload();
                                      },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                SectionCard(
                  title: 'ACTIVE / UNCLOSED RENTALS',
                  action: Text(
                    '${data.unclosedTotal}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  child: data.unclosed.isEmpty
                      ? const EmptyState(
                          icon: Icons.check_circle_outline,
                          message: 'No unclosed rentals.',
                        )
                      : Column(
                          children: [
                            for (final rental in data.unclosed)
                              RentalTile(
                                rental: rental,
                                onTap: () => _openRental(rental),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 16),
                SectionCard(
                  title: 'RECENT RENTALS',
                  child: data.recent.isEmpty
                      ? EmptyState(
                          icon: data.awaitingFirstDownload
                              ? Icons.cloud_download_outlined
                              : Icons.history,
                          message: data.awaitingFirstDownload
                              ? 'Downloading your records from the cloud… '
                                  'If this takes long, check the internet '
                                  'connection and tap Sync Now.'
                              : 'No rentals recorded yet.',
                        )
                      : Column(
                          children: [
                            for (final rental in data.recent)
                              RentalTile(
                                rental: rental,
                                onTap: () => _openRental(rental),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _openRental(Map<String, Object?> rental) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RentalDetailScreen(rentalId: rental['id'] as String),
      ),
    );
    _reload();
  }

  ShellScreenState? _shell(BuildContext context) =>
      context.findAncestorStateOfType<ShellScreenState>();
}

/// Account actions: the fingerprint/face switch (only when the phone
/// supports it) and sign-out.
class _AccountMenu extends StatefulWidget {
  final BiometricService? biometrics;
  final VoidCallback onSignOut;

  const _AccountMenu({required this.biometrics, required this.onSignOut});

  @override
  State<_AccountMenu> createState() => _AccountMenuState();
}

class _AccountMenuState extends State<_AccountMenu> {
  bool _supported = false;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final b = widget.biometrics;
    if (b == null) return;
    final supported = await b.isSupported();
    final enabled = await b.isEnabled() ?? false;
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _enabled = enabled;
    });
  }

  Future<void> _toggle() async {
    final b = widget.biometrics!;
    final messenger = ScaffoldMessenger.of(context);
    if (_enabled) {
      await b.setEnabled(false);
      messenger.showSnackBar(const SnackBar(
        content: Text('Fingerprint / face sign-in turned off.'),
      ));
    } else {
      final ok =
          await b.authenticate('Confirm to turn on fingerprint / face sign-in');
      if (!ok) {
        messenger.showSnackBar(const SnackBar(
          content:
              Text("Couldn't verify — fingerprint / face sign-in stays off."),
        ));
        return;
      }
      await b.setEnabled(true);
      messenger.showSnackBar(const SnackBar(
        content: Text('Fingerprint / face sign-in turned on.'),
      ));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Account',
      icon: const Icon(Icons.account_circle_outlined),
      onSelected: (value) {
        if (value == 'biometric') _toggle();
        if (value == 'signout') widget.onSignOut();
      },
      itemBuilder: (context) => [
        if (_supported)
          PopupMenuItem(
            value: 'biometric',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.fingerprint),
              title: const Text('Fingerprint / face sign-in'),
              trailing: Switch(value: _enabled, onChanged: null),
            ),
          ),
        const PopupMenuItem(
          value: 'signout',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Sign out'),
          ),
        ),
      ],
    );
  }
}

class _QuickNav extends StatelessWidget {
  final VoidCallback onSearch;
  final VoidCallback onLibrary;

  const _QuickNav({required this.onSearch, required this.onLibrary});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _NavCard(
            icon: Icons.search,
            label: 'Search',
            caption: 'Name, number, phone, CNIC',
            onTap: onSearch,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _NavCard(
            icon: Icons.directions_car,
            label: 'Library',
            caption: 'Vehicle inventory',
            onTap: onLibrary,
          ),
        ),
      ],
    );
  }
}

class _NavCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String caption;
  final VoidCallback onTap;

  const _NavCard({
    required this.icon,
    required this.label,
    required this.caption,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(height: 10),
              Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                caption,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  final _Note note;
  final VoidCallback? onTap;

  const _NotificationRow({required this.note, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      leading: Icon(note.icon, color: note.color(theme)),
      title: Text(note.title, style: theme.textTheme.bodyMedium),
      subtitle: Text(note.subtitle, style: theme.textTheme.bodySmall),
      trailing: onTap == null
          ? null
          : note.isSyncPrompt
              ? FilledButton.tonal(
                  onPressed: onTap,
                  child: const Text('Sync Now'),
                )
              : const Icon(Icons.chevron_right, size: 20),
    );
  }
}

class _Note {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool urgent;
  final bool isSyncPrompt;
  final Map<String, Object?>? vehicle;

  _Note({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.urgent = false,
    this.isSyncPrompt = false,
    this.vehicle,
  });

  Color color(ThemeData theme) =>
      urgent ? theme.colorScheme.error : theme.colorScheme.tertiary;
}

class _Dashboard {
  final List<Map<String, Object?>> unclosed;
  final int unclosedTotal;
  final List<Map<String, Object?>> recent;
  final List<Map<String, Object?>> insuranceDue;
  final int pendingSync;
  final bool awaitingFirstDownload;

  _Dashboard({
    required this.unclosed,
    required this.unclosedTotal,
    required this.recent,
    required this.insuranceDue,
    required this.pendingSync,
    this.awaitingFirstDownload = false,
  });

  /// Only things the data can actually support: insurance dates that are
  /// due or overdue, and rentals still waiting for a backend number.
  List<_Note> get notifications {
    final today = DateTime.now();
    final notes = <_Note>[];

    for (final vehicle in insuranceDue) {
      final dueRaw = vehicle['insurance_due_on'] as String?;
      final due = dueRaw == null ? null : DateTime.tryParse(dueRaw);
      final overdue = due != null && due.isBefore(today);
      final days = due?.difference(today).inDays;
      notes.add(_Note(
        icon: Icons.shield_outlined,
        title: 'Insurance ${overdue ? 'overdue' : 'due soon'}: '
            '${displayOrNA(vehicle['registration_no'])}',
        subtitle: overdue
            ? 'Was due ${displayOrNA(dueRaw)}'
            : 'Due ${displayOrNA(dueRaw)}${days == null ? '' : '  ·  in $days days'}',
        urgent: overdue,
        vehicle: vehicle,
      ));
    }

    if (pendingSync > 0) {
      notes.add(_Note(
        icon: Icons.cloud_upload_outlined,
        title:
            '$pendingSync change${pendingSync == 1 ? '' : 's'} waiting to sync',
        subtitle: 'Tap Sync Now to send them to the cloud.',
        isSyncPrompt: true,
      ));
    }

    return notes;
  }
}
