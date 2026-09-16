import 'package:flutter/material.dart';

import '../sync/sync_status.dart';

/// One line on Home: is this device live with the cloud, when it last
/// synced, and whether anything is waiting or wrong. Tapping syncs now.
class SyncStatusBar extends StatelessWidget {
  final ValueNotifier<SyncStatus> status;
  final VoidCallback onTap;

  const SyncStatusBar({super.key, required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: status,
      builder: (context, s, _) {
        final (icon, text, color) = _describe(s, theme);
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              children: [
                if (s.phase == SyncPhase.syncing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodySmall?.copyWith(color: color),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  (IconData, String, Color) _describe(SyncStatus s, ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    if (s.phase == SyncPhase.syncing) {
      return (Icons.sync, 'Syncing…', muted);
    }
    if (s.phase == SyncPhase.error) {
      final waiting = s.pending > 0 ? ' · ${s.pending} waiting' : '';
      return (
        Icons.cloud_off_outlined,
        'Not synced$waiting — ${s.message ?? 'will retry'}',
        theme.colorScheme.error,
      );
    }
    final when = s.lastSuccess == null ? 'not yet' : _ago(s.lastSuccess!);
    final waiting = s.pending > 0 ? ' · ${s.pending} waiting' : '';
    if (s.message != null) {
      return (Icons.info_outline, s.message!, theme.colorScheme.tertiary);
    }
    if (s.live) {
      return (Icons.cloud_done_outlined, 'Live · synced $when$waiting', muted);
    }
    return (Icons.cloud_queue, 'Synced $when$waiting · reconnecting…', muted);
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}
