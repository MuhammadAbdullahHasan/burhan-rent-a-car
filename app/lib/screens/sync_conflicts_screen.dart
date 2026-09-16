import 'dart:convert';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../widgets/common.dart';

/// Edits made on this device that lost to a newer edit of the same record
/// from another device. The cloud's version was kept; the values that were
/// overridden are shown here so the owner can re-apply them deliberately.
class SyncConflictsScreen extends StatefulWidget {
  const SyncConflictsScreen({super.key});

  @override
  State<SyncConflictsScreen> createState() => _SyncConflictsScreenState();
}

class _SyncConflictsScreenState extends State<SyncConflictsScreen> {
  late Future<List<Map<String, Object?>>> _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
  }

  Future<List<Map<String, Object?>>> _load() {
    return AppScope.of(context).db.query(
          'sync_conflicts',
          where: 'resolved = 0',
          orderBy: 'created_at DESC',
        );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _dismiss(Map<String, Object?> conflict) async {
    await AppScope.of(context).db.update(
          'sync_conflicts',
          {'resolved': 1},
          where: 'id = ?',
          whereArgs: [conflict['id']],
        );
    _reload();
  }

  /// Re-applies the overridden values as a fresh edit on top of the cloud's
  /// current version -- it then syncs like any other change.
  Future<void> _reapply(Map<String, Object?> conflict, _Diff diff) async {
    final services = AppScope.of(context);
    final db = services.db;
    final entityId = conflict['entity_id'] as String;
    final fields = {for (final d in diff.changes) d.field: d.mine};
    switch (conflict['entity_type']) {
      case 'rental':
        await services.engine.queueUpdate(db, entityId, fields);
      case 'customer':
        await services.engine.updateCustomer(db, entityId, fields);
      case 'vehicle':
        await services.engine.updateVehicle(db, entityId, fields);
      default:
        return;
    }
    await _dismiss(conflict);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Your values were re-applied and queued.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Overridden changes')),
      body: FutureBuilder<List<Map<String, Object?>>>(
        future: _future,
        builder: (context, snapshot) {
          final rows = snapshot.data;
          if (rows == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.check_circle_outline,
              message: 'No overridden changes.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text(
                'These edits were made here while another device changed the '
                'same record. The other device\'s version was kept. Re-apply '
                'yours if it should win, or dismiss.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              for (final row in rows)
                _ConflictCard(
                  conflict: row,
                  onDismiss: () => _dismiss(row),
                  onReapply: (diff) => _reapply(row, diff),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  final Map<String, Object?> conflict;
  final VoidCallback onDismiss;
  final void Function(_Diff) onReapply;

  const _ConflictCard({
    required this.conflict,
    required this.onDismiss,
    required this.onReapply,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diff = _Diff.of(conflict);
    final type = conflict['entity_type'] as String;
    final label = switch (type) {
      'rental' => 'Rental ${rentalDisplayNumber(diff.theirs)}',
      'customer' => 'Customer ${displayOrNA(diff.theirs['full_name'])}',
      'vehicle' => 'Vehicle ${displayOrNA(diff.theirs['registration_no'])}',
      _ => 'Agreement photo',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleMedium),
            Text(
              displayOrNA(conflict['created_at']),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (diff.changes.isEmpty)
              const Text('Same values on both sides.')
            else
              for (final c in diff.changes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(
                      text: '${c.field}: ',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: 'mine ${displayOrNA(c.mine)} · '),
                    TextSpan(text: 'kept ${displayOrNA(c.theirs)}'),
                  ])),
                ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
                if (diff.changes.isNotEmpty && type != 'attachment')
                  FilledButton.tonal(
                    onPressed: () => onReapply(diff),
                    child: const Text('Re-apply mine'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Change {
  final String field;
  final Object? mine;
  final Object? theirs;
  _Change(this.field, this.mine, this.theirs);
}

class _Diff {
  final Map<String, Object?> mine;
  final Map<String, Object?> theirs;
  final List<_Change> changes;
  _Diff(this.mine, this.theirs, this.changes);

  static const _ignored = {
    'id',
    'version',
    'updated_at',
    'created_at',
    'synced_at',
    'owner_id',
    'rental_no',
    'image',
    'thumbnail',
    'image_base64',
    'thumbnail_base64',
  };

  static _Diff of(Map<String, Object?> conflict) {
    final mine = (jsonDecode(conflict['local_row'] as String) as Map)
        .cast<String, Object?>();
    final theirs = (jsonDecode(conflict['server_row'] as String) as Map)
        .cast<String, Object?>();
    final changes = <_Change>[];
    for (final key in mine.keys) {
      if (_ignored.contains(key)) continue;
      final a = _norm(mine[key]);
      final b = _norm(theirs[key]);
      if (a != b) changes.add(_Change(key, mine[key], theirs[key]));
    }
    return _Diff(mine, theirs, changes);
  }

  /// SQLite ints vs Postgres bools/numerics.
  static String _norm(Object? v) {
    if (v == null) return '';
    if (v == true || v == 1) return '1';
    if (v == false || v == 0) return '0';
    if (v is num) return v.toString();
    return v.toString();
  }
}
