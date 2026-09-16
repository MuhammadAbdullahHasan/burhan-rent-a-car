import '../app_services.dart';
import 'sync_status.dart';

/// Runs the real cloud sync when this build has one wired up (production);
/// falls back to the local rental-numbering stand-in otherwise (widget
/// tests, which inject services with no auth/network layer at all).
/// Returns a short message for a SnackBar either way, keeps
/// [AppServices.syncStatus] current, and bumps [AppServices.dataChanged]
/// when local rows changed so open screens reload.
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

  services.syncStatus.value = services.syncStatus.value.copyWith(
    phase: SyncPhase.syncing,
    clearMessage: true,
  );
  final summary = await cloud.syncNow();
  final pending = await services.pendingChanges();
  if (summary.changedAnything) services.dataChanged.value++;

  final parts = <String>[
    if (summary.pushed > 0) '${summary.pushed} sent',
    if (summary.pulled > 0) '${summary.pulled} received',
  ];
  final String message;
  final problem =
      summary.error == null ? null : friendlySyncError(summary.error!);
  if (summary.failed > 0) {
    final n = summary.failed;
    message = '${parts.isEmpty ? '' : '${parts.join(', ')}. '}'
        '$n change${n == 1 ? '' : 's'} could not be sent and will be '
        'retried: $problem';
  } else if (summary.hasError) {
    message = summary.changedAnything
        ? 'Synced partially, will retry the rest: $problem'
        : "Couldn't sync: $problem";
  } else if (summary.conflicts > 0) {
    final n = summary.conflicts;
    message = '$n change${n == 1 ? '' : 's'} on this device '
        '${n == 1 ? 'was' : 'were'} overridden by a newer edit from another '
        'device — see Home.';
  } else if (!summary.changedAnything) {
    message = 'Already up to date.';
  } else {
    message = 'Synced — ${parts.join(', ')}.';
  }

  services.syncStatus.value = services.syncStatus.value.copyWith(
    phase: summary.hasError ? SyncPhase.error : SyncPhase.idle,
    lastSuccess: summary.hasError ? null : DateTime.now(),
    pending: pending,
    message: problem,
    clearMessage: !summary.hasError,
  );
  return message;
}
