import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import 'web_camera_screen.dart';

/// A captured agreement photo, ready to store: a display-size JPEG plus a
/// small thumbnail for lists.
class AgreementPhoto {
  final Uint8List image;
  final Uint8List thumbnail;
  static const mimeType = 'image/jpeg';

  const AgreementPhoto({required this.image, required this.thumbnail});
}

/// Camera-or-gallery capture of a paper agreement.
///
/// Phone cameras produce 3-8 MB originals; a legible photo of an A4 sheet
/// needs nowhere near that. The picker is asked for a bounded size up
/// front, then the result is normalised to JPEG (orientation baked in, so
/// it never displays sideways) and a thumbnail is cut for list tiles.
class AgreementPhotoPicker {
  final ImagePicker _picker;

  AgreementPhotoPicker({ImagePicker? picker})
      : _picker = picker ?? ImagePicker();

  /// Offers camera / gallery, then returns the processed photo -- or null
  /// if the user backed out at any point.
  Future<AgreementPhoto?> pick(BuildContext context) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              subtitle: const Text('Use the camera'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              subtitle: const Text('Pick an existing picture'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return null;
    return pickFrom(source, context: context);
  }

  /// Captures from a specific source without asking.
  ///
  /// In a browser, [ImageSource.camera] opens the in-page camera view
  /// ([WebCameraScreen]) when a [context] is given: the file input's
  /// camera hint only works in phones' browsers, and a desktop browser
  /// would otherwise just show a file picker. If the camera cannot be
  /// used there, the owner is offered the file picker instead.
  Future<AgreementPhoto?> pickFrom(
    ImageSource source, {
    BuildContext? context,
  }) async {
    if (kIsWeb && source == ImageSource.camera && context != null) {
      final bytes = await WebCameraScreen.capture(context);
      if (bytes != null) return process(bytes);
      if (!context.mounted) return null;
      // Backed out (or no camera): fall through to the file picker.
      source = ImageSource.gallery;
    }
    final picked = await _picker.pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    if (picked == null) return null;

    final bytes = await picked.readAsBytes();
    return process(bytes);
  }

  /// Decoding and re-encoding is CPU-bound; keep it off the UI thread on
  /// platforms that have isolates (on web `compute` runs inline).
  static Future<AgreementPhoto?> process(Uint8List bytes) =>
      compute(_processSync, bytes);
}

AgreementPhoto? _processSync(Uint8List bytes) {
  // decodeImage can throw on malformed input (its format sniffer reads
  // headers optimistically), not just return null. A bad file from the
  // gallery must produce "couldn't read the photo", never a crash.
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  final oriented = img.bakeOrientation(decoded);

  final main = oriented.width > 1600 || oriented.height > 1600
      ? img.copyResize(
          oriented,
          width: oriented.width >= oriented.height ? 1600 : null,
          height: oriented.height > oriented.width ? 1600 : null,
        )
      : oriented;
  final thumb = img.copyResize(
    oriented,
    width: oriented.width >= oriented.height ? 320 : null,
    height: oriented.height > oriented.width ? 320 : null,
  );

  return AgreementPhoto(
    image: Uint8List.fromList(img.encodeJpg(main, quality: 85)),
    thumbnail: Uint8List.fromList(img.encodeJpg(thumb, quality: 70)),
  );
}
