import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Supabase's built-in mailer allows only a few auth emails per hour for
/// the whole project, and its "rate limit exceeded" reply carries no
/// retry time. This keeps the device's own record of the emails it asked
/// for, so when the limit hits the app can say exactly when the hour's
/// window frees instead of "try again in a few minutes".
class EmailRateLimit {
  static const perHour = 2;
  static const window = Duration(hours: 1);
  static const _key = 'auth_email_sends';

  /// Call after an email-sending request the server ACCEPTED.
  static Future<void> recordSend() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc();
    final kept = (await _sends(prefs))
        .where((t) => now.difference(t) < window)
        .toList()
      ..add(now);
    await prefs.setString(
      _key,
      jsonEncode(kept.map((t) => t.toIso8601String()).toList()),
    );
  }

  /// When the next email can go out, judged from this device's record.
  /// Null when this device has not used its share of the hour -- the
  /// limit was consumed elsewhere (another device, or attempts before an
  /// update) and the true reset time is unknowable; [latestPossible] is
  /// the bound to show then.
  static Future<DateTime?> retryAt() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc();
    final recent = (await _sends(prefs))
        .where((t) => now.difference(t) < window)
        .toList()
      ..sort();
    if (recent.length < perHour) return null;
    return recent[recent.length - perHour].add(window);
  }

  static DateTime latestPossible() => DateTime.now().toUtc().add(window);

  /// Some replies do say how long: "For security purposes, you can only
  /// request this after 42 seconds."
  static Duration? fromMessage(String message) {
    final m = RegExp(r'after (\d+) seconds?').firstMatch(message);
    return m == null ? null : Duration(seconds: int.parse(m.group(1)!));
  }

  static Future<List<DateTime>> _sends(SharedPreferences prefs) async {
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    try {
      return (jsonDecode(raw) as List)
          .map((s) => DateTime.parse(s as String).toUtc())
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// A live countdown to [until] with the exact clock time, ticking every
/// second; calls [onDone] when it reaches zero.
class RetryCountdown extends StatefulWidget {
  final DateTime until;
  final bool exact;
  final VoidCallback onDone;

  const RetryCountdown({
    super.key,
    required this.until,
    required this.exact,
    required this.onDone,
  });

  @override
  State<RetryCountdown> createState() => _RetryCountdownState();
}

class _RetryCountdownState extends State<RetryCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (DateTime.now().isAfter(widget.until)) {
        _timer?.cancel();
        widget.onDone();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = widget.until.difference(DateTime.now());
    final local = widget.until.toLocal();
    final clock = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final text = widget.exact
        ? 'Email limit reached — try again in ${formatRemaining(remaining)} '
            '(at $clock).'
        : 'Email limit reached by another device — try again within '
            '${formatRemaining(remaining)} (by $clock at the latest).';
    return Text(
      text,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onErrorContainer,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

String formatRemaining(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  if (m == 0) return '$s s';
  return '$m min ${s.toString().padLeft(2, '0')} s';
}
