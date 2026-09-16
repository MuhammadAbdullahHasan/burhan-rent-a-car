import '../app_services.dart';

/// Runs the real cloud sync when this build has one wired up (production);
/// falls back to the local rental-numbering stand-in otherwise (widget
/// tests, which inject services with no auth/network layer at all).
/// Returns a short message for a SnackBar either way, so both "Sync Now"
/// call sites behave identically, and bumps [AppServices.dataChanged] when
/// local rows changed so open screens reload.
Future<String> runSync(AppServices services) async {
  final cloud = services.cloudSync;
  if (cloud == null) {
    final processed = await services.engine.syncPending(services.db);
    if (processed > 0) services.dataChanged.value++;
    return processed == 0
        ? 'Nothing to sync.'
        : '$processed rental${processed == 1 ? '' : 's'} assigned a '
            'permanent number.';
  }

  final summary = await cloud.syncNow();
  if (summary.changedAnything) services.dataChanged.value++;

  final parts = <String>[
    if (summary.pushed > 0) '${summary.pushed} sent',
    if (summary.pulled > 0) '${summary.pulled} received',
  ];
  if (summary.failed > 0) {
    final n = summary.failed;
    return '${parts.isEmpty ? '' : '${parts.join(', ')}. '}'
        '$n change${n == 1 ? '' : 's'} could not be sent and will be '
        'retried: ${summary.error}';
  }
  if (summary.hasError) {
    return summary.changedAnything
        ? 'Synced partially, will retry the rest: ${summary.error}'
        : "Couldn't sync: ${summary.error}";
  }
  if (!summary.changedAnything) return 'Already up to date.';
  return 'Synced — ${parts.join(', ')}.';
}
