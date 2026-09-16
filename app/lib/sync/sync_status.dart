/// What the owner sees about sync at a glance (Home status line).
enum SyncPhase { idle, syncing, error }

class SyncStatus {
  final SyncPhase phase;

  /// Realtime channel connected: other devices' changes arrive on their own.
  final bool live;
  final DateTime? lastSuccess;
  final int pending;
  final String? message;

  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.live = false,
    this.lastSuccess,
    this.pending = 0,
    this.message,
  });

  SyncStatus copyWith({
    SyncPhase? phase,
    bool? live,
    DateTime? lastSuccess,
    int? pending,
    String? message,
    bool clearMessage = false,
  }) {
    return SyncStatus(
      phase: phase ?? this.phase,
      live: live ?? this.live,
      lastSuccess: lastSuccess ?? this.lastSuccess,
      pending: pending ?? this.pending,
      message: clearMessage ? null : (message ?? this.message),
    );
  }
}

/// Turns transport-level exceptions into something the owner can act on.
String friendlySyncError(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset') ||
      lower.contains('network is unreachable') ||
      lower.contains('clientexception') ||
      lower.contains('xmlhttprequest')) {
    return 'No internet connection';
  }
  if (lower.contains('jwt') || lower.contains('401')) {
    return 'Signed out on the server — sign in again';
  }
  return raw.length > 160 ? '${raw.substring(0, 160)}…' : raw;
}
