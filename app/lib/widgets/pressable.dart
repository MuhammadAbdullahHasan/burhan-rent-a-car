import 'package:flutter/material.dart';

/// Press feedback on touch-DOWN, not on release: the card settles slightly
/// under the finger the instant it is touched and springs back when let go
/// or when the finger drags away. The scale re-targets from wherever it
/// currently is, so a quick tap or a cancelled press never jumps. Under
/// reduced motion the scale is skipped and only the ink highlight remains.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;

  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedScale(
      scale: _down && !reduced ? 0.975 : 1,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: widget.borderRadius,
          onTap: widget.onTap,
          onHighlightChanged: _set,
          child: widget.child,
        ),
      ),
    );
  }
}
