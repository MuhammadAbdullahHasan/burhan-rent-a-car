import 'dart:io';

import 'package:image/image.dart' as img;

/// Prepares launcher-icon sources from the business logo:
///  - icon.png            full logo, 1024², for legacy launchers / web
///  - icon_foreground.png logo scaled into the adaptive-icon safe zone on
///                        black, so circular/squircle masks never clip the
///                        shield
void main(List<String> args) {
  final src = img.decodeImage(File(args[0]).readAsBytesSync())!;
  const size = 1024;

  final full = img.copyResize(src, width: size, height: size,
      interpolation: img.Interpolation.cubic);
  File('assets/icon/icon.png').writeAsBytesSync(img.encodePng(full));

  // Adaptive foreground: 108dp canvas, ~66dp guaranteed visible. Use 68%.
  final inner = (size * 0.68).round();
  final scaled = img.copyResize(src, width: inner, height: inner,
      interpolation: img.Interpolation.cubic);
  final fg = img.Image(width: size, height: size);
  img.fill(fg, color: img.ColorRgb8(0, 0, 0));
  img.compositeImage(fg, scaled,
      dstX: (size - inner) ~/ 2, dstY: (size - inner) ~/ 2);
  File('assets/icon/icon_foreground.png').writeAsBytesSync(img.encodePng(fg));

  stdout.writeln('wrote assets/icon/icon.png and icon_foreground.png');
}
