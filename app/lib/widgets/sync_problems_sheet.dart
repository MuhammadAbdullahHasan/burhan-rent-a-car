import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../sync/sync_status.dart';

/// What the owner sees when the sync bar is red: the last error in full,
/// every change still waiting to reach the cloud with how often it was
/// tried and why it failed, a Retry, and -- for a change the server
/// rejects every time -- a Discard that has to be confirmed. Nothing is
/// ever dropped on its own.
Future<void> showSyncProblemsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _SyncProblemsSheet(),
  );
}

class _SyncProblemsSheet extends StatefulWidget {
  const _SyncProblemsSheet();

  @override
  State<_SyncProblemsSheet> createState() => _SyncProblemsSheetState();
}

class _SyncProblemsSheetState extends State<_SyncProblemsSheet> {
  late Future<List<Map<String, Object?>>> _items;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _items = Outbox().pendingDetails(AppScope.of(context).db);
  }

  void _reload() {
    setState(() {
      _items = Outbox().pendingDetails(AppScope.of(context).db);
    });
  }

  Future<void> _retry() async {
    final services = AppScope.of(context);
    setState(() => _busy = true);
    final message = await services.syncNow();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    _reload();
  }

  Future<void> _discard(Map<String, Object?> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Discard this change?'),
        content: Text(
          'The cloud will keep its own version of ${_describe(item)} and this '
          'device will follow it on the next sync. Only do this if the change '
          'is wrong or no longer needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final services = AppScope.of(context);
    await Outbox().discard(services.db, item['id'] as String);
    final left = await services.pendingChanges();
    services.syncStatus.value =
        services.syncStatus.value.copyWith(pending: left);
    services.cloudSync?.requestSync();
    _reload();
  }

  static String _describe(Map<String, Object?> item) {
    final op = switch (item['operation'] as String) {
      'insert' => 'new',
      'update' => 'edit of',
      'delete' => 'removal of',
      'restore' => 'restore of',
      final other => other,
    };
    final what = switch (item['entity_type'] as String) {
      'rental' => item['rental_no'] == null
          ? 'a rental (pending number)'
          : 'Rental #${item['rental_no']}',
      'customer' => 'customer ${displayOrNA(item['customer_name'])}',
      'vehicle' => 'vehicle ${displayOrNA(item['vehicle_registration'])}',
      'attachment' => item['attachment_rental_no'] == null
          ? 'an agreement photo'
          : 'the photo of Rental #${item['attachment_rental_no']}',
      final other => other,
    };
    return '$op $what';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = AppScope.of(context).syncStatus.value;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Sync problems', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (status.message != null)
              SelectableText(
                status.message!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            const SizedBox(height: 12),
            Flexible(
              child: FutureBuilder<List<Map<String, Object?>>>(
                future: _items,
                builder: (context, snapshot) {
                  final items = snapshot.data;
                  if (items == null) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Nothing is waiting to be sent. If the bar is still '
                        'red, the problem is the connection or the sign-in.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final tries = item['retry_count'] as int;
                      final error = item['last_error'] as String?;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_describe(item)),
                        subtitle: Text(
                          error == null
                              ? 'Not tried yet'
                              : 'Tried $tries time${tries == 1 ? '' : 's'} — '
                                  '${friendlySyncError(error)}',
                        ),
                        trailing: IconButton(
                          tooltip: 'Discard this change',
                          icon: Icon(Icons.delete_outline,
                              color: theme.colorScheme.error),
                          onPressed: _busy ? null : () => _discard(item),
                        ),
                        onLongPress: error == null
                            ? null
                            : () {
                                Clipboard.setData(ClipboardData(text: error));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Error copied.')),
                                );
                              },
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _retry,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              label: const Text('Retry now'),
            ),
          ],
        ),
      ),
    );
  }
}
