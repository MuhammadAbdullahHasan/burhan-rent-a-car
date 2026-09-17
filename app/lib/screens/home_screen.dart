import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../sync/cloud_sync_engine.dart';
import '../sync/sync_actions.dart';
import '../widgets/sync_status_bar.dart';
import '../auth/biometric_service.dart';
import '../widgets/common.dart';
import '../widgets/pressable.dart';
import '../widgets/showroom_scaffold.dart';
import 'rental_detail_screen.dart';
import 'rental_form_screen.dart';
import 'backup_screen.dart';
import 'shell_screen.dart';
import 'sync_conflicts_screen.dart';
import 'vehicle_detail_screen.dart';
import 'vehicle_form_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Insurance is flagged this far ahead of its due date -- a month, so
/// there is time to pay before it lapses.
const _insuranceNoticeDays = 30;

class _HomeScreenState extends State<HomeScreen> {
  late Future<_Dashboard> _future;
  ValueNotifier<int>? _dataChanged;
  bool _insuranceChecked = false;

  /// Every time the app is opened: the vehicles whose insurance is due
  /// within the next month or already overdue, so it can be paid in
  /// time. It comes back on every launch until the due date is moved on.
  /// "Done" (and tapping a vehicle) opens the vehicle's form with the
  /// insurance date ready to update; "Later" just closes it for now.
  Future<void> _alertInsurance(List<Map<String, Object?>> due) async {
    if (due.isEmpty || !mounted) return;
    final theme = Theme.of(context);
    final now = DateTime.now();
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: Icon(Icons.shield_outlined, color: theme.colorScheme.error),
        title: const Text('Insurance due'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final vehicle in due)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.directions_car),
                title: Text(displayOrNA(vehicle['registration_no'])),
                subtitle: Text(_insuranceLine(vehicle, now)),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () {
                  Navigator.pop(dialog);
                  _updateInsurance(vehicle);
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialog);
              _updateInsurance(due.first);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  /// The vehicle's form, where the next insurance date is entered.
  Future<void> _updateInsurance(Map<String, Object?> vehicle) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => VehicleFormScreen(vehicle: vehicle),
      ),
    );
    if (saved == true) _reload();
  }

  static String _insuranceLine(Map<String, Object?> vehicle, DateTime now) {
    final raw = vehicle['insurance_due_on'] as String?;
    final due = raw == null ? null : DateTime.tryParse(raw);
    if (due == null) return 'Due ${displayOrNA(raw)}';
    final days = due.difference(DateTime(now.year, now.month, now.day)).inDays;
    if (days < 0) return 'Overdue since $raw';
    if (days == 0) return 'Due today ($raw)';
    return 'Due $raw  ·  in $days day${days == 1 ? '' : 's'}';
  }

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
    final insuranceDue = await services.vehicles.insuranceDue(
      db,
      withinDays: _insuranceNoticeDays,
    );
    if (!_insuranceChecked) {
      _insuranceChecked = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _alertInsurance(insuranceDue),
      );
    }
    return _Dashboard(
      lastRental: await services.rentals.latestNumbered(db),
      insuranceDue: insuranceDue,
      awaitingFirstDownload:
          services.cloudSync != null && !await CloudSyncEngine.isHydrated(db),
      conflicts: (await db
              .rawQuery(
                'SELECT COUNT(*) AS c FROM sync_conflicts WHERE resolved = 0',
              )
              .then((r) => r.first['c'] as int?)) ??
          0,
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

  Future<void> _openConflicts() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SyncConflictsScreen()),
    );
    _reload();
  }

  Future<void> _openBackup() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BackupScreen()),
    );
    _reload();
  }

  Future<void> _newRental() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RentalFormScreen()),
    );
    if (created == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return ShowroomScaffold(
      title: 'Burhan Rent-A-Car',
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
            onBackup: _openBackup,
          ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newRental,
        icon: const Icon(Icons.add),
        label: const Text('New Rental'),
      ),
      onRefresh: () async => _reload(),
      slivers: [
        FutureBuilder<_Dashboard>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.error_outline,
                  message: 'Could not load this record:\n${snapshot.error}',
                ),
              );
            }
            if (!snapshot.hasData) {
              return const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final data = snapshot.data!;
            return SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                ShowroomScaffold.bottomInset(context, hasFab: true),
              ),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  if (AppScope.of(context).cloudSync != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SyncStatusBar(
                        status: AppScope.of(context).syncStatus,
                        onTap: _syncNow,
                      ),
                    ),
                  _Tiles(
                    data: data,
                    onSearch: () => _shell(context)?.goToTab(1),
                    onLibrary: () => _shell(context)?.goToTab(2),
                    onAttention: () => _showAttention(data),
                    onLastRental: data.lastRental == null
                        ? null
                        : () => _openRental(data.lastRental!),
                  ),
                ]),
              ),
            );
          },
        ),
      ],
    );
  }

  /// The Needs Attention tile opens its items in a sheet. Each row closes
  /// the sheet before acting so the action lands on the dashboard itself.
  Future<void> _showAttention(_Dashboard data) async {
    final notes = data.notifications;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) {
        final theme = Theme.of(sheet);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Needs Attention',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                if (notes.isEmpty)
                  const EmptyState(
                    icon: Icons.check_circle_outline,
                    message: 'Nothing needs attention right now.',
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final note in notes)
                          _NotificationRow(
                            note: note,
                            onTap: _attentionAction(note) == null
                                ? null
                                : () {
                                    Navigator.pop(sheet);
                                    _attentionAction(note)!();
                                  },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  VoidCallback? _attentionAction(_Note note) {
    if (note.isSyncPrompt) return _syncNow;
    if (note.isConflictPrompt) return _openConflicts;
    final vehicle = note.vehicle;
    if (vehicle == null) return null;
    return () async {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VehicleDetailScreen(
            vehicleId: vehicle['id'] as String,
          ),
        ),
      );
      _reload();
    };
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
  final VoidCallback onBackup;

  const _AccountMenu({
    required this.biometrics,
    required this.onSignOut,
    required this.onBackup,
  });

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
        if (value == 'backup') widget.onBackup();
        if (value == 'signout') widget.onSignOut();
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'backup',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.backup_outlined),
            title: Text('Backup & restore'),
          ),
        ),
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

/// The dashboard: four tiles, two per row. Search and Library jump to
/// their tabs; Needs Attention and Last Rental carry a live figure so the
/// owner sees at a glance what needs doing and which number they are on.
class _Tiles extends StatelessWidget {
  final _Dashboard data;
  final VoidCallback onSearch;
  final VoidCallback onLibrary;
  final VoidCallback onAttention;
  final VoidCallback? onLastRental;

  const _Tiles({
    required this.data,
    required this.onSearch,
    required this.onLibrary,
    required this.onAttention,
    required this.onLastRental,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = data.notifications;
    final urgent = notes.any((n) => n.urgent);
    final last = data.lastRental;
    return Column(
      children: [
        _TileRow(
          left: _NavCard(
            icon: Icons.search,
            label: 'Search',
            caption: 'Name, number, phone, CNIC',
            onTap: onSearch,
          ),
          right: _NavCard(
            icon: Icons.directions_car,
            label: 'Library',
            caption: 'Vehicle inventory',
            onTap: onLibrary,
          ),
        ),
        const SizedBox(height: 12),
        _TileRow(
          left: _NavCard(
            icon: notes.isEmpty
                ? Icons.check_circle_outline
                : Icons.notifications_active_outlined,
            tint: notes.isEmpty
                ? null
                : urgent
                    ? theme.colorScheme.error
                    : theme.colorScheme.tertiary,
            label: 'Needs Attention',
            value: notes.isEmpty ? null : '${notes.length}',
            caption: data.attentionSummary,
            onTap: onAttention,
          ),
          right: _NavCard(
            icon: Icons.receipt_long,
            label: 'Last Rental',
            value: last == null ? '—' : '#${last['rental_no']}',
            caption: last == null
                ? (data.awaitingFirstDownload
                    ? 'Downloading records…'
                    : 'No rentals yet')
                : [last['start_date'], last['status']]
                    .where((v) => v != null)
                    .join('  ·  '),
            onTap: onLastRental,
          ),
        ),
      ],
    );
  }
}

class _TileRow extends StatelessWidget {
  final Widget left;
  final Widget right;

  const _TileRow({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: left),
          const SizedBox(width: 12),
          Expanded(child: right),
        ],
      ),
    );
  }
}

class _NavCard extends StatelessWidget {
  final IconData icon;
  final Color? tint;
  final String label;
  final String caption;

  /// A figure shown large beside the icon (a count, a rental number).
  final String? value;
  final VoidCallback? onTap;

  const _NavCard({
    required this.icon,
    this.tint,
    required this.label,
    required this.caption,
    this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tint ?? theme.colorScheme.primary;
    return Pressable(
      onTap: onTap,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: color),
                  const Spacer(),
                  if (value != null)
                    Text(
                      value!,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w800,
                        height: 1,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
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
  final bool isConflictPrompt;
  final Map<String, Object?>? vehicle;

  _Note({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.urgent = false,
    this.isSyncPrompt = false,
    this.isConflictPrompt = false,
    this.vehicle,
  });

  Color color(ThemeData theme) =>
      urgent ? theme.colorScheme.error : theme.colorScheme.tertiary;
}

class _Dashboard {
  /// The rental with the highest number -- "which number are we on".
  final Map<String, Object?>? lastRental;
  final List<Map<String, Object?>> insuranceDue;
  final int pendingSync;
  final bool awaitingFirstDownload;
  final int conflicts;

  _Dashboard({
    required this.lastRental,
    required this.insuranceDue,
    required this.pendingSync,
    this.awaitingFirstDownload = false,
    this.conflicts = 0,
  });

  /// One line for the Needs Attention tile.
  String get attentionSummary {
    final parts = <String>[
      if (insuranceDue.isNotEmpty)
        'Insurance due${insuranceDue.length == 1 ? '' : ' ×${insuranceDue.length}'}',
      if (pendingSync > 0) 'Changes to sync',
      if (conflicts > 0) 'Overridden changes',
    ];
    return parts.isEmpty ? 'All clear' : parts.join('  ·  ');
  }

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
        subtitle: 'Sent automatically when online. Tap to send now.',
        isSyncPrompt: true,
      ));
    }

    if (conflicts > 0) {
      notes.add(_Note(
        icon: Icons.merge_type,
        title: '$conflicts change${conflicts == 1 ? '' : 's'} overridden by '
            'another device',
        subtitle: 'Review the values that were replaced.',
        isConflictPrompt: true,
        urgent: true,
      ));
    }

    return notes;
  }
}
