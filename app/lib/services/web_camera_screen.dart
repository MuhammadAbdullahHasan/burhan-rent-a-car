import 'dart:async';
import 'dart:typed_data';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';

/// A live camera view for the browser. Phones' browsers open the native
/// camera from the file input, but desktop browsers only ever offer a file
/// picker that way, so on the web "Take a photo" comes here instead: the
/// page asks for the webcam (or the phone's rear camera), shows the live
/// picture, and one tap captures it. Returns the JPEG bytes, or null when
/// the owner backs out or no camera can be used.
class WebCameraScreen extends StatefulWidget {
  const WebCameraScreen({super.key});

  static Future<Uint8List?> capture(BuildContext context) {
    return Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const WebCameraScreen(),
      ),
    );
  }

  @override
  State<WebCameraScreen> createState() => _WebCameraScreenState();
}

class _WebCameraScreenState extends State<WebCameraScreen> {
  int? _cameraId;
  String? _error;
  bool _busy = false;
  StreamSubscription<CameraInitializedEvent>? _init;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final cameras = await CameraPlatform.instance.availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'No camera was found on this device.');
        return;
      }
      // Prefer the rear camera on a phone; a laptop has just the one.
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final id = await CameraPlatform.instance.createCameraWithSettings(
        camera,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      final ready = CameraPlatform.instance.onCameraInitialized(id).first;
      await CameraPlatform.instance.initializeCamera(id);
      await ready;
      if (!mounted) {
        await CameraPlatform.instance.dispose(id);
        return;
      }
      setState(() => _cameraId = id);
    } on CameraException catch (e) {
      setState(() => _error = _explain(e));
    } catch (e) {
      setState(() => _error = 'The camera could not be started: $e');
    }
  }

  static String _explain(CameraException e) {
    final code = e.code.toLowerCase();
    final message = (e.description ?? '').toLowerCase();
    if (code.contains('permission') ||
        code.contains('notallowed') ||
        message.contains('permission') ||
        message.contains('denied')) {
      return 'The browser did not allow the camera. Click the camera icon in '
          'the address bar (or the site settings) to allow it, then try '
          'again.';
    }
    if (code.contains('notfound') || message.contains('not found')) {
      return 'No camera was found on this device.';
    }
    if (code.contains('notreadable') || message.contains('in use')) {
      return 'The camera is in use by another app or tab.';
    }
    return 'The camera could not be started: ${e.description ?? e.code}';
  }

  Future<void> _take() async {
    final id = _cameraId;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await CameraPlatform.instance.takePicture(id);
      final bytes = await file.readAsBytes();
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'The photo could not be taken: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _init?.cancel();
    final id = _cameraId;
    if (id != null) CameraPlatform.instance.dispose(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = _cameraId;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Take a photo'),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_off_outlined,
                        size: 48, color: Colors.white70),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() => _error = null);
                        _open();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Choose a file instead',
                          style: TextStyle(color: Colors.white70)),
                    ),
                  ],
                ),
              ),
            )
          : id == null
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white))
              : Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: CameraPlatform.instance.buildPreview(id),
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : _take,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 28, vertical: 16),
                            ),
                            icon: _busy
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.photo_camera),
                            label: const Text('Capture'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
