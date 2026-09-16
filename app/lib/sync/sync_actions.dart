import '../app_services.dart';

/// Runs the real cloud sync when this build has one wired up (production);
/// falls back to the local rental-numbering stand-in otherwise (widget
/// tests, which inject services with no auth/network layer at all).
/// Returns a short message for a SnackBar either way, so both "Sync Now"
/// call sites behave identically.
Future<String> runSync(AppServices services) async {
  final cloud = services.cloudSync;
  if (cloud == null) {
    final processed = await services.engine.syncPending(services.db);
    return processed == 0
        ? 'Nothing to sync.'
        : '$processed rental${processed == 1 ? '' : 's'} assigned a '
            'permanent number.';
  }

  final summary = await cloud.syncNow();
  if (summary.hasError) {
    return summary.changedAnything
        ? 'Synced partially, will retry the rest: ${summary.error}'
        : "Couldn't sync: ${summary.error}";
  }
  if (!summary.changedAnything) return 'Already up to date.';
  final parts = <String>[
    if (summary.pushed > 0) '${summary.pushed} sent',
    if (summary.pulled > 0) '${summary.pulled} received',
  ];
  return 'Synced — ${parts.join(', ')}.';
}
