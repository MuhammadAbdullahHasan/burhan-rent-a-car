import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../screens/agreement_viewer_screen.dart';
import 'common.dart';

/// The rental's paper-agreement photo, or a clear invitation to add one.
///
/// Photo state shows the image large enough to read at a glance and opens
/// a zoomable viewer on tap. Empty state gives the two capture routes
/// (camera, gallery) as first-class actions rather than a bare icon.
class AgreementCard extends StatelessWidget {
  final Uint8List? image;
  final String title;

  /// Rental label used in the viewer's title and the shared file name.
  final String rentalLabel;
  final bool busy;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onChooseFromGallery;
  final VoidCallback? onRemove;

  const AgreementCard({
    super.key,
    required this.image,
    required this.rentalLabel,
    this.title = 'RENTAL AGREEMENT',
    this.busy = false,
    this.onTakePhoto,
    this.onChooseFromGallery,
    this.onRemove,
  });

  bool get _canEdit => onTakePhoto != null || onChooseFromGallery != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image = this.image;

    return SectionCard(
      title: title,
      action: image != null && _canEdit
          ? PopupMenuButton<String>(
              tooltip: 'Photo options',
              icon: const Icon(Icons.more_horiz),
              onSelected: (value) {
                switch (value) {
                  case 'camera':
                    onTakePhoto?.call();
                  case 'gallery':
                    onChooseFromGallery?.call();
                  case 'remove':
                    onRemove?.call();
                }
              },
              itemBuilder: (context) => [
                if (onTakePhoto != null)
                  const PopupMenuItem(
                    value: 'camera',
                    child: ListTile(
                      leading: Icon(Icons.photo_camera_outlined),
                      title: Text('Retake photo'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (onChooseFromGallery != null)
                  const PopupMenuItem(
                    value: 'gallery',
                    child: ListTile(
                      leading: Icon(Icons.photo_library_outlined),
                      title: Text('Replace from gallery'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (onRemove != null)
                  PopupMenuItem(
                    value: 'remove',
                    child: ListTile(
                      leading: Icon(
                        Icons.delete_outline,
                        color: theme.colorScheme.error,
                      ),
                      title: Text(
                        'Remove photo',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
            )
          : null,
      child: busy
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          : image == null
              ? _EmptyAgreement(
                  onTakePhoto: onTakePhoto,
                  onChooseFromGallery: onChooseFromGallery,
                )
              : _AgreementPreview(
                  image: image,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AgreementViewerScreen(
                        image: image,
                        rentalLabel: rentalLabel,
                      ),
                    ),
                  ),
                ),
    );
  }
}

class _AgreementPreview extends StatelessWidget {
  final Uint8List image;
  final VoidCallback onTap;

  const _AgreementPreview({required this.image, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Material(
            color: theme.colorScheme.surfaceContainerHighest,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: Hero(
                  tag: image.hashCode,
                  child: Image.memory(
                    image,
                    fit: BoxFit.contain,
                    width: double.infinity,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              Icons.zoom_in,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              'Tap to view full size, zoom, or share',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _EmptyAgreement extends StatelessWidget {
  final VoidCallback? onTakePhoto;
  final VoidCallback? onChooseFromGallery;

  const _EmptyAgreement({this.onTakePhoto, this.onChooseFromGallery});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canAdd = onTakePhoto != null || onChooseFromGallery != null;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
          style: BorderStyle.solid,
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.description_outlined,
            size: 40,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 10),
          Text(
            'No agreement photo yet',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            canAdd
                ? 'Photograph the signed paper agreement so it stays with '
                    'this rental.'
                : 'No photo was attached to this rental.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (canAdd) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                if (onTakePhoto != null)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onTakePhoto,
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Take photo'),
                    ),
                  ),
                if (onTakePhoto != null && onChooseFromGallery != null)
                  const SizedBox(width: 12),
                if (onChooseFromGallery != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onChooseFromGallery,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Gallery'),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
