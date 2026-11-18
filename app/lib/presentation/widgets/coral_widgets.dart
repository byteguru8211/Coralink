import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../core/utils.dart';
import '../../network/realtime.dart';

class CoralBackground extends StatelessWidget {
  const CoralBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            palette.background,
            Color.lerp(palette.background, palette.appBar, 0.55)!,
            palette.background,
          ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -120,
            right: -90,
            child: _GlowBlob(size: 300, color: palette.accent.withValues(alpha: 0.10)),
          ),
          Positioned(
            bottom: -140,
            left: -110,
            child: _GlowBlob(size: 340, color: palette.halo.withValues(alpha: 0.07)),
          ),
          child,
        ],
      ),
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
          ),
        ),
      );
}

/// The Coralink mark: a glass "C" with a sprout, drawn with a painter so it
/// stays crisp at any size and adapts to the palette.
class CoralMark extends StatelessWidget {
  const CoralMark({super.key, this.size = 48, this.glow = true});
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CoralMarkPainter(
          start: palette.accentSoft,
          end: palette.accent,
          leaf: palette.halo,
          glow: glow,
        ),
      ),
    );
  }
}

class _CoralMarkPainter extends CustomPainter {
  _CoralMarkPainter({
    required this.start,
    required this.end,
    required this.leaf,
    required this.glow,
  });

  final Color start;
  final Color end;
  final Color leaf;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.46, size.height * 0.54);
    final radius = size.width * 0.31;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final stroke = size.width * 0.14;

    final shader = SweepGradient(
      startAngle: -math.pi * 0.25,
      endAngle: math.pi * 1.6,
      colors: [end, start, end],
    ).createShader(rect);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = shader;

    if (glow) {
      canvas.drawArc(
        rect,
        math.pi * 0.32,
        math.pi * 1.36,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.35
          ..strokeCap = StrokeCap.round
          ..color = end.withValues(alpha: 0.22)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.width * 0.06),
      );
    }
    canvas.drawArc(rect, math.pi * 0.32, math.pi * 1.36, false, paint);

    // Water highlight on the letter.
    canvas.drawArc(
      rect,
      math.pi * 0.55,
      math.pi * 0.32,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 0.24
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.35),
    );

    // Sprout.
    final base = Offset(center.dx + radius * 0.74, center.dy - radius * 0.74);
    final stem = Paint()
      ..color = leaf
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.035
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(base, base.translate(size.width * 0.02, -size.height * 0.16), stem);

    final leafPaint = Paint()..color = leaf.withValues(alpha: 0.92);
    final leafPath = Path()
      ..moveTo(base.dx + size.width * 0.015, base.dy - size.height * 0.15)
      ..quadraticBezierTo(
        base.dx + size.width * 0.15,
        base.dy - size.height * 0.30,
        base.dx + size.width * 0.22,
        base.dy - size.height * 0.20,
      )
      ..quadraticBezierTo(
        base.dx + size.width * 0.13,
        base.dy - size.height * 0.10,
        base.dx + size.width * 0.015,
        base.dy - size.height * 0.15,
      );
    canvas.drawPath(leafPath, leafPaint);
    final leafPath2 = Path()
      ..moveTo(base.dx + size.width * 0.02, base.dy - size.height * 0.17)
      ..quadraticBezierTo(
        base.dx - size.width * 0.10,
        base.dy - size.height * 0.28,
        base.dx - size.width * 0.15,
        base.dy - size.height * 0.16,
      )
      ..quadraticBezierTo(
        base.dx - size.width * 0.07,
        base.dy - size.height * 0.08,
        base.dx + size.width * 0.02,
        base.dy - size.height * 0.17,
      );
    canvas.drawPath(
      leafPath2,
      Paint()..color = leaf.withValues(alpha: 0.72),
    );
  }

  @override
  bool shouldRepaint(covariant _CoralMarkPainter oldDelegate) =>
      oldDelegate.start != start || oldDelegate.end != end || oldDelegate.leaf != leaf;
}

class PulseHalo extends StatefulWidget {
  const PulseHalo({
    super.key,
    required this.child,
    this.active = true,
    this.color,
    this.size = 64,
  });

  final Widget child;
  final bool active;
  final Color? color;
  final double size;

  @override
  State<PulseHalo> createState() => _PulseHaloState();
}

class _PulseHaloState extends State<PulseHalo> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant PulseHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.palette.halo;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.active)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = Curves.easeOut.transform(_controller.value);
                return Container(
                  width: widget.size * (0.82 + 0.28 * t),
                  height: widget.size * (0.82 + 0.28 * t),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color.withValues(alpha: 0.55 * (1 - t)),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.25 * (1 - t)),
                        blurRadius: 18 * t,
                        spreadRadius: 2 * t,
                      ),
                    ],
                  ),
                );
              },
            ),
          widget.child,
        ],
      ),
    );
  }
}

Uint8List _decodeAvatar(String value) {
  final comma = value.indexOf(',');
  final raw = value.startsWith('data:') && comma >= 0 ? value.substring(comma + 1) : value;
  return base64Decode(raw);
}

class SeedAvatar extends StatelessWidget {
  const SeedAvatar({
    super.key,
    required this.seedId,
    required this.name,
    this.size = 52,
    this.colorHex,
    this.avatar,
    this.online = false,
    this.pulse = false,
  });

  final String seedId;
  final String name;
  final double size;
  final String? colorHex;
  final String? avatar;
  final bool online;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final colors = colorHex != null
        ? [colorFromHex(colorHex!), colorFromHex(colorHex!).withValues(alpha: 0.55)]
        : seedGradient(seedId);
    final base = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.first.withValues(alpha: 0.35),
            blurRadius: size * 0.25,
            offset: Offset(0, size * 0.06),
          ),
        ],
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.34,
          letterSpacing: 0.4,
        ),
      ),
    );
    final photo = avatar;
    final face = (photo != null && photo.isNotEmpty)
        ? ClipOval(
            child: Image.memory(
              _decodeAvatar(photo),
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => base,
            ),
          )
        : base;
    final withBadge = Stack(
      clipBehavior: Clip.none,
      children: [
        face,
        if (online)
          Positioned(
            right: 1,
            bottom: 1,
            child: Container(
              width: size * 0.26,
              height: size * 0.26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.palette.halo,
                border: Border.all(color: context.palette.background, width: 2),
              ),
            ),
          ),
      ],
    );
    return PulseHalo(
      active: pulse && online,
      size: size * 1.25,
      child: withBadge,
    );
  }
}

class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color});
  final Color? color;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.palette.accent;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (index) {
          final phase = (_controller.value - index * 0.16) % 1.0;
          final scale = 0.6 + 0.4 * math.sin(phase * math.pi).clamp(0.0, 1.0);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class ConnectionPill extends StatelessWidget {
  const ConnectionPill({
    super.key,
    required this.status,
    required this.strings,
    this.direct = false,
    this.compact = true,
  });

  final RealtimeStatus status;
  final AppStrings strings;
  final bool direct;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final connected = status == RealtimeStatus.connected;
    final color = connected ? (direct ? palette.halo : palette.accent) : palette.coral;
    final label = connected
        ? (direct ? strings.get('p2pDirect') : strings.get('relayMode'))
        : strings.get('reconnecting');
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14, vertical: compact ? 5 : 7),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(color: color, pulsing: !connected),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(color: palette.textMuted, fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color, this.pulsing = false});
  final Color color;
  final bool pulsing;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: widget.pulsing
            ? Tween(begin: 0.35, end: 1.0).animate(_controller)
            : const AlwaysStoppedAnimation(1),
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.6), blurRadius: 6)],
          ),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
    this.icon = Icons.spa_outlined,
  });

  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [palette.accent.withValues(alpha: 0.20), Colors.transparent],
                ),
              ),
              child: Icon(icon, size: 46, color: palette.accentSoft),
            ),
            const SizedBox(height: 22),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: palette.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, height: 1.45, color: palette.textMuted),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 26),
              SizedBox(
                width: 220,
                child: FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.label, {super.key, this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: TextStyle(
                color: palette.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.1,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: (danger ? palette.coral : palette.accent).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 20, color: danger ? palette.coral : palette.accent),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: danger ? palette.coral : palette.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: TextStyle(color: palette.textMuted, fontSize: 12.5)),
      trailing: trailing ??
          (onTap == null
              ? null
              : Icon(Icons.chevron_right_rounded, color: palette.textMuted, size: 22)),
    );
  }
}

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
  });

  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      margin: margin ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: padding,
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: palette.divider),
        boxShadow: [
          BoxShadow(
            color: palette.shadow.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}
