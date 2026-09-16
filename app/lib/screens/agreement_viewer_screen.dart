import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Full-screen, pinch-to-zoom view of an agreement photo, with Share (to
/// WhatsApp, email, printing apps -- whatever the device offers).
class AgreementViewerScreen extends StatelessWidget {
  final Uint8List image;
  final String rentalLabel;

  const AgreementViewerScreen({
    super.key,
    required this.image,
    required this.rentalLabel,
  });

  Future<void> _share(BuildContext context) async {
    final safeName = rentalLabel.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            image,
            name: 'agreement-$safeName.jpg',
            mimeType: 'image/jpeg',
          ),
        ],
        subject: 'Rental agreement $rentalLabel',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Agreement · $rentalLabel'),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => _share(context),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 6,
          child: Hero(
            tag: image.hashCode,
            child: Image.memory(image, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}
