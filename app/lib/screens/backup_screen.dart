import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../backup/backup_codec.dart';
import '../backup/backup_file.dart';
import '../backup/cloud_backup.dart';
import '../widgets/common.dart';

/// Backup & restore, in both forms the locked spec calls for: automatic
/// snapshots in the owner's private cloud folder, and a password-protected
/// file the owner keeps wherever they like.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  late Future<_Overview> _future;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future = _load();
  }

  Future<_Overview> _load() async {
    final services = AppScope.of(context);
    final cloud = services.cloudBackup;
    final counts = BackupCodec.countsOf(await exportSnapshot(services.db));
    if (cloud == null) {
      return _Overview(counts: counts, lastCloud: null, cloudEntries: const []);
    }
    List<CloudBackupEntry> entries;
    try {
      entries = await cloud.list();
    } catch (_) {
      entries = const [];
    }
    return _Overview(
      counts: counts,
      lastCloud: await cloud.lastBackupAt(),
      cloudEntries: entries,
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final message = await action();
      if (message != null) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload();
      }
    }
  }

  Future<void> _backupToCloud() => _run(() async {
        final cloud = AppScope.of(context).cloudBackup!;
        await cloud.backupNow();
        return 'Backed up to the cloud.';
      });

  Future<void> _saveFile() => _run(() async {
        final services = AppScope.of(context);
        final password = await _askPassword(
          title: 'Backup password',
          hint: 'Needed to open this file later. Keep it safe — it cannot '
              'be recovered.',
          confirm: true,
        );
        if (password == null) return null;
        final snapshot = await exportSnapshot(services.db);
        final bytes = await BackupCodec.encrypt(snapshot, password);
        final date = DateTime.now().toIso8601String().substring(0, 10);
        await saveBackupFile(bytes, 'Burhan_Rent_A_Car_Backup_$date.bak');
        return 'Backup file ready.';
      });

  Future<void> _restoreFromFile() => _run(() async {
        final picked = await FilePicker.platform.pickFiles(withData: true);
        final file = picked?.files.single;
        final Uint8List? bytes = file?.bytes;
        if (bytes == null) return null;
        final password = await _askPassword(
          title: 'Backup password',
          hint: 'The password this file was saved with.',
        );
        if (password == null) return null;
        final Snapshot snapshot;
        try {
          snapshot = await BackupCodec.decrypt(bytes, password);
        } on WrongPasswordException {
          return 'Wrong password — nothing was changed.';
        } on BackupFormatException catch (e) {
          return '$e Nothing was changed.';
        }
        return _confirmAndRestore(snapshot, file!.name);
      });

  Future<void> _restoreFromCloud(CloudBackupEntry entry) => _run(() async {
        final cloud = AppScope.of(context).cloudBackup!;
        final snapshot = await cloud.download(entry.name);
        return _confirmAndRestore(snapshot, entry.name);
      });

  Future<String?> _confirmAndRestore(Snapshot snapshot, String source) async {
    final counts = BackupCodec.countsOf(snapshot);
    if (!mounted) return null;
    final services = AppScope.of(context);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Text(
          '$source holds ${counts.rentals} rentals, ${counts.customers} '
          'customers, ${counts.vehicles} vehicles and ${counts.attachments} '
          'agreement photos.\n\n'
          'Records missing here or in the cloud are put back. Records the '
          'cloud already has are kept as they are, so nothing newer is '
          'overwritten and no rental is ever duplicated.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (proceed != true) return null;
    await restoreIntoApp(services, snapshot);
    return 'Restored ${counts.rentals} rentals. Syncing with the cloud…';
  }

  Future<String?> _askPassword({
    required String title,
    required String hint,
    bool confirm = false,
  }) async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        String? error;
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(hint),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                if (confirm)
                  TextField(
                    controller: confirmController,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'Confirm password'),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final value = controller.text;
                  if (value.length < 6) {
                    setState(() => error = 'Use at least 6 characters.');
                    return;
                  }
                  if (confirm && value != confirmController.text) {
                    setState(() => error = 'Passwords do not match.');
                    return;
                  }
                  Navigator.pop(context, value);
                },
                child: const Text('Continue'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    confirmController.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCloud = AppScope.of(context).cloudBackup != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: FutureBuilder<_Overview>(
        future: _future,
        builder: (context, snapshot) {
          final data = snapshot.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (data != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    'On this device: ${data.counts.rentals} rentals, '
                    '${data.counts.customers} customers, '
                    '${data.counts.vehicles} vehicles, '
                    '${data.counts.attachments} agreement photos.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              if (hasCloud)
                SectionCard(
                  title: 'CLOUD BACKUPS',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'All records (without agreement photos) are saved '
                        'automatically once a day to your private cloud '
                        'folder. The last 7 are kept.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        data?.lastCloud == null
                            ? 'No cloud backup yet.'
                            : 'Last backup: ${_when(data!.lastCloud!)}',
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _backupToCloud,
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: const Text('Back up to cloud now'),
                      ),
                      if (data != null && data.cloudEntries.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text('Restore from a cloud backup',
                            style: theme.textTheme.labelLarge),
                        for (final entry in data.cloudEntries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.history),
                            title: Text(
                              entry.createdAt == null
                                  ? entry.name
                                  : _when(entry.createdAt!.toLocal()),
                            ),
                            subtitle: entry.size == null
                                ? null
                                : Text('${(entry.size! / 1024).round()} KB'),
                            trailing: TextButton(
                              onPressed:
                                  _busy ? null : () => _restoreFromCloud(entry),
                              child: const Text('Restore'),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              SectionCard(
                title: 'BACKUP FILE',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'A password-protected file you keep yourself — on '
                      'Google Drive, a USB stick, or another phone. It can be '
                      'restored on any device with the password.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _busy ? null : _saveFile,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Save backup file…'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _restoreFromFile,
                      icon: const Icon(Icons.restore),
                      label: const Text('Restore from file…'),
                    ),
                  ],
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          );
        },
      ),
    );
  }

  String _when(DateTime t) {
    final local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _Overview {
  final BackupCounts counts;
  final DateTime? lastCloud;
  final List<CloudBackupEntry> cloudEntries;
  _Overview({
    required this.counts,
    required this.lastCloud,
    required this.cloudEntries,
  });
}
