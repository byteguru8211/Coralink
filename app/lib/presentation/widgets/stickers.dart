import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_colors.dart';
import '../../core/strings.dart';

/// The Coralink sticker set: eight little reef neighbours drawn as vectors, so
/// they stay crisp on every screen and follow the app palette. Each one carries
/// a tiny living detail — drifting bubbles or a glint — so a sticker feels like
/// a piece of the reef rather than a static emoji.
enum CoralSticker { wave, hug, moon, star, laugh, miss, yay, thanks }

class StickerSpec {
  const StickerSpec(this.id, this.nameKey);
  final CoralSticker id;
  final String nameKey;
}

const List<StickerSpec> kCoralStickers = [
  StickerSpec(CoralSticker.wave, 'stickerWave'),
  StickerSpec(CoralSticker.hug, 'stickerHug'),
  StickerSpec(CoralSticker.moon, 'stickerMoon'),
  StickerSpec(CoralSticker.star, 'stickerStar'),
  StickerSpec(CoralSticker.laugh, 'stickerLaugh'),
  StickerSpec(CoralSticker.miss, 'stickerMiss'),
  StickerSpec(CoralSticker.yay, 'stickerYay'),
  StickerSpec(CoralSticker.thanks, 'stickerThanks'),
];

CoralSticker? stickerFromId(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final sticker in CoralSticker.values) {
    if (sticker.name == id) return sticker;
  }
  return null;
}

String stickerIdOf(CoralSticker sticker) => sticker.name;

String stickerNameKey(CoralSticker sticker) =>
    kCoralStickers.firstWhere((s) => s.id == sticker).nameKey;

/// A live sticker: the artwork plus a slow drift of bubbles. Tapping makes it
/// "bloom" once, which is the small signature of the Coralink set.
class StickerView extends StatefulWidget {
  const StickerView({
    super.key,
    required this.sticker,
    this.size = 120,
    this.animate = true,
  });

  final CoralSticker sticker;
  final double size;
  final bool animate;

  @override
  State<StickerView> createState() => _StickerViewState();
}

class _StickerViewState extends State<StickerView>
    with TickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();
  late final AnimationController _bloom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final Animation<double> _bloomScale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: 1.12), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.12, end: 1), weight: 60),
  ]).animate(CurvedAnimation(parent: _bloom, curve: Curves.easeOut));

  @override
  void dispose() {
    _controller.dispose();
    _bloom.dispose();
    super.dispose();
  }

  void _bloomOnce() {
    if (_bloom.isAnimating) return;
    _bloom.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final artwork = AnimatedBuilder(
      animation: Listenable.merge([_controller, _bloom]),
      builder: (context, _) => Transform.scale(
        scale: _bloomScale.value,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _StickerPainter(
            sticker: widget.sticker,
            t: widget.animate ? _controller.value : 0.4,
          ),
        ),
      ),
    );
    return Semantics(
      label: widget.sticker.name,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _bloomOnce,
        child: SizedBox.square(dimension: widget.size, child: artwork),
      ),
    );
  }
}

class _StickerPainter extends CustomPainter {
  _StickerPainter({required this.sticker, required this.t});

  final CoralSticker sticker;
  final double t;

  static const _coral = Color(0xFFFF8A73);
  static const _coralDeep = Color(0xFFF2604F);
  static const _pearl = Color(0xFFFFF3E2);
  static const _emerald = Color(0xFF2FB894);
  static const _emeraldDeep = Color(0xFF14735C);
  static const _gold = Color(0xFFFFC96B);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 120, size.height / 120);
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [Colors.white.withValues(alpha: 0.16), Colors.transparent],
      ).createShader(const Rect.fromLTWH(10, 10, 100, 100));
    canvas.drawCircle(const Offset(60, 60), 58, glow);
    switch (sticker) {
      case CoralSticker.wave:
        _wave(canvas);
      case CoralSticker.hug:
        _hug(canvas);
      case CoralSticker.moon:
        _moon(canvas);
      case CoralSticker.star:
        _star(canvas);
      case CoralSticker.laugh:
        _laugh(canvas);
      case CoralSticker.miss:
        _miss(canvas);
      case CoralSticker.yay:
        _yay(canvas);
      case CoralSticker.thanks:
        _thanks(canvas);
    }
    _bubbles(canvas, seedOffset: sticker.index * 7);
    canvas.restore();
  }

  Paint _fill(Color color) => Paint()..color = color;

  Paint _gradient(List<Color> colors) => Paint()
    ..shader = LinearGradient(colors: colors).createShader(
      const Rect.fromLTWH(0, 0, 120, 120),
    );

  Paint _stroke(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  // ---------------------------------------------------------------- drawings

  void _wave(Canvas canvas) {
    // A little coral polyp waving one branch, sitting on a dark reef stone.
    canvas.drawOval(
      const Rect.fromLTWH(24, 88, 74, 22),
      _fill(const Color(0xFF0B3A2C)),
    );
    canvas.drawOval(
      const Rect.fromLTWH(34, 88, 40, 12),
      _fill(_emeraldDeep.withValues(alpha: 0.8)),
    );
    final body = Path()
      ..moveTo(52, 90)
      ..cubicTo(50, 72, 54, 58, 60, 50)
      ..cubicTo(66, 58, 70, 72, 68, 90)
      ..close();
    canvas.drawPath(body, _gradient([_coral, _coralDeep]));
    final arm = Path()
      ..moveTo(60, 58)
      ..cubicTo(72, 54, 80, 44, 82, 32);
    canvas.drawPath(arm, _stroke(_coral, 7));
    canvas.drawCircle(const Offset(83, 29), 8, _fill(_pearl));
    canvas.drawCircle(const Offset(83, 29), 8, _stroke(_coralDeep, 2.5));
    // Face
    canvas.drawCircle(const Offset(56, 68), 2.3, _fill(const Color(0xFF6B2B25)));
    canvas.drawCircle(const Offset(64, 68), 2.3, _fill(const Color(0xFF6B2B25)));
    canvas.drawArc(
      const Rect.fromLTWH(56, 69, 8, 7),
      0.25,
      math.pi - 0.5,
      false,
      _stroke(const Color(0xFF6B2B25), 1.8),
    );
  }

  void _hug(Canvas canvas) {
    // Two coral branches leaning into a heart.
    final left = Path()
      ..moveTo(36, 92)
      ..cubicTo(34, 74, 40, 58, 52, 50);
    final right = Path()
      ..moveTo(84, 92)
      ..cubicTo(86, 74, 80, 58, 68, 50);
    canvas.drawPath(left, _stroke(_coralDeep, 10));
    canvas.drawPath(left, _stroke(_coral, 6));
    canvas.drawPath(right, _stroke(_emeraldDeep, 10));
    canvas.drawPath(right, _stroke(_emerald, 6));
    final heart = Path()
      ..moveTo(60, 66)
      ..cubicTo(48, 56, 44, 42, 53, 38)
      ..cubicTo(58, 36, 60, 40, 60, 43)
      ..cubicTo(60, 40, 62, 36, 67, 38)
      ..cubicTo(76, 42, 72, 56, 60, 66)
      ..close();
    canvas.drawPath(heart, _gradient([_pearl, _gold]));
    canvas.drawPath(heart, _stroke(_coralDeep.withValues(alpha: 0.45), 1.6));
    _sparkle(canvas, const Offset(60, 44), 5, _pearl);
  }

  void _moon(Canvas canvas) {
    // A sleepy jellyfish with a glowing dome.
    final dome = Path()
      ..moveTo(30, 68)
      ..cubicTo(30, 38, 90, 38, 90, 68)
      ..cubicTo(82, 76, 38, 76, 30, 68)
      ..close();
    canvas.drawPath(dome, _gradient([_pearl, _emerald.withValues(alpha: 0.85)]));
    canvas.drawPath(dome, _stroke(_emeraldDeep.withValues(alpha: 0.55), 2));
    for (var i = 0; i < 4; i++) {
      final x = 40.0 + i * 13;
      final tentacle = Path()
        ..moveTo(x, 72)
        ..cubicTo(x - 5, 82, x + 6, 88, x - 1, 98);
      canvas.drawPath(
        tentacle,
        _stroke(_emerald.withValues(alpha: 0.75), 4),
      );
    }
    // Closed, content eyes and a tiny mouth.
    canvas.drawArc(
      const Rect.fromLTWH(50, 54, 8, 7),
      math.pi,
      math.pi,
      false,
      _stroke(_emeraldDeep, 2),
    );
    canvas.drawArc(
      const Rect.fromLTWH(64, 54, 8, 7),
      math.pi,
      math.pi,
      false,
      _stroke(_emeraldDeep, 2),
    );
    canvas.drawArc(
      const Rect.fromLTWH(58, 61, 6, 5),
      0.1,
      math.pi - 0.2,
      false,
      _stroke(_emeraldDeep, 1.6),
    );
    _sparkle(canvas, const Offset(84, 36), 6, _pearl);
    _sparkle(canvas, const Offset(24, 46), 4, _pearl);
  }

  void _star(Canvas canvas) {
    // A starfish with a warm centre and little pearls on its arms.
    final star = Path();
    for (var i = 0; i < 10; i++) {
      final angle = -math.pi / 2 + i * math.pi / 5;
      final radius = i.isEven ? 44.0 : 19.0;
      final point = Offset(
        60 + math.cos(angle) * radius,
        62 + math.sin(angle) * radius,
      );
      i == 0 ? star.moveTo(point.dx, point.dy) : star.lineTo(point.dx, point.dy);
    }
    star.close();
    canvas.drawPath(star, _gradient([_gold, _coralDeep]));
    canvas.drawPath(star, _stroke(_coralDeep.withValues(alpha: 0.4), 2));
    canvas.drawCircle(const Offset(60, 62), 13, _fill(_pearl.withValues(alpha: 0.9)));
    canvas.drawCircle(const Offset(55, 59), 2, _fill(const Color(0xFF6B2B25)));
    canvas.drawCircle(const Offset(65, 59), 2, _fill(const Color(0xFF6B2B25)));
    canvas.drawArc(
      const Rect.fromLTWH(55, 61, 10, 8),
      0.15,
      math.pi - 0.3,
      false,
      _stroke(const Color(0xFF6B2B25), 1.8),
    );
    _sparkle(canvas, const Offset(88, 34), 5, _pearl);
  }

  void _laugh(Canvas canvas) {
    // A scallop shell giggling bubbles.
    final shell = Path()
      ..moveTo(28, 86)
      ..cubicTo(28, 54, 92, 54, 92, 86)
      ..cubicTo(74, 94, 46, 94, 28, 86)
      ..close();
    canvas.drawPath(shell, _gradient([_coral, _gold]));
    canvas.drawPath(shell, _stroke(_coralDeep.withValues(alpha: 0.5), 2));
    for (var i = -2; i <= 2; i++) {
      final rib = Path()
        ..moveTo(60, 88)
        ..quadraticBezierTo(60 + i * 14, 72, 60 + i * 12, 58);
      canvas.drawPath(rib, _stroke(_coralDeep.withValues(alpha: 0.35), 1.6));
    }
    canvas.drawCircle(const Offset(60, 72), 9, _fill(_pearl));
    canvas.drawArc(
      const Rect.fromLTWH(52, 68, 16, 13),
      0.1,
      math.pi - 0.2,
      false,
      _stroke(const Color(0xFF6B2B25), 2),
    );
    _bubble(canvas, const Offset(90, 44), 5 + 2 * t);
    _bubble(canvas, const Offset(80, 30), 3 + 2 * t);
  }

  void _miss(Canvas canvas) {
    // A seahorse curling around a small heart.
    final body = Path()
      ..moveTo(58, 30)
      ..cubicTo(74, 30, 80, 48, 70, 62)
      ..cubicTo(62, 74, 58, 82, 62, 94)
      ..cubicTo(50, 90, 46, 76, 52, 64)
      ..cubicTo(58, 52, 52, 44, 46, 42)
      ..cubicTo(46, 34, 50, 30, 58, 30)
      ..close();
    canvas.drawPath(body, _gradient([_gold, _coral]));
    canvas.drawPath(body, _stroke(_coralDeep.withValues(alpha: 0.35), 1.6));
    // Snout and crest.
    canvas.drawCircle(const Offset(47, 40), 6, _fill(_gold));
    canvas.drawCircle(const Offset(45, 39), 1.8, _fill(const Color(0xFF6B2B25)));
    canvas.drawPath(
      Path()
        ..moveTo(58, 30)
        ..quadraticBezierTo(56, 20, 66, 22)
        ..quadraticBezierTo(64, 28, 64, 32),
      _fill(_coralDeep),
    );
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(Offset(60 + i * 5, 50 + i * 6), 2, _fill(_pearl));
    }
    final heart = Path()
      ..moveTo(84, 54)
      ..cubicTo(76, 48, 74, 38, 81, 36)
      ..cubicTo(84, 35, 85, 38, 85, 40)
      ..cubicTo(85, 38, 86, 35, 89, 36)
      ..cubicTo(96, 38, 94, 48, 84, 54)
      ..close();
    canvas.drawPath(heart, _fill(_coralDeep));
  }

  void _yay(Canvas canvas) {
    // A crab throwing both claws up.
    final claws = Paint()
      ..color = _coralDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(38, 70)
        ..cubicTo(24, 60, 22, 44, 30, 34),
      claws,
    );
    canvas.drawPath(
      Path()
        ..moveTo(82, 70)
        ..cubicTo(96, 60, 98, 44, 90, 34),
      claws,
    );
    for (final point in const [Offset(28, 30), Offset(92, 30)]) {
      canvas.drawCircle(point, 9, _fill(_coral));
      canvas.drawArc(
        Rect.fromCircle(center: point, radius: 9),
        -2.6,
        1.5,
        false,
        _stroke(_coralDeep, 3),
      );
    }
    canvas.drawOval(
      const Rect.fromLTWH(34, 62, 52, 34),
      _gradient([_coral, _coralDeep]),
    );
    canvas.drawCircle(const Offset(52, 72), 3, _fill(_pearl));
    canvas.drawCircle(const Offset(68, 72), 3, _fill(_pearl));
    canvas.drawCircle(const Offset(52, 72), 1.5, _fill(const Color(0xFF3A1712)));
    canvas.drawCircle(const Offset(68, 72), 1.5, _fill(const Color(0xFF3A1712)));
    canvas.drawArc(
      const Rect.fromLTWH(54, 77, 12, 9),
      0.15,
      math.pi - 0.3,
      false,
      _stroke(const Color(0xFF3A1712), 1.8),
    );
    for (final offset in const [Offset(40, 92), Offset(80, 92)]) {
      canvas.drawPath(
        Path()
          ..moveTo(offset.dx, 90)
          ..lineTo(offset.dx - 6, 100),
        claws,
      );
    }
  }

  void _thanks(Canvas canvas) {
    // A pearl inside a heart-shaped shell — gratitude with a shine.
    final heart = Path()
      ..moveTo(60, 94)
      ..cubicTo(30, 74, 26, 52, 40, 44)
      ..cubicTo(50, 38, 58, 44, 60, 52)
      ..cubicTo(62, 44, 70, 38, 80, 44)
      ..cubicTo(94, 52, 90, 74, 60, 94)
      ..close();
    canvas.drawPath(heart, _gradient([_coral, _coralDeep]));
    canvas.drawPath(heart, _stroke(_gold.withValues(alpha: 0.75), 2));
    for (var i = -1; i <= 1; i++) {
      canvas.drawPath(
        Path()
          ..moveTo(60 + i * 14, 86)
          ..quadraticBezierTo(60 + i * 20, 68, 60 + i * 16, 54),
        _stroke(_gold.withValues(alpha: 0.28), 1.6),
      );
    }
    canvas.drawCircle(const Offset(60, 66), 15, _fill(_pearl));
    canvas.drawCircle(
      const Offset(55, 61),
      5,
      _fill(Colors.white.withValues(alpha: 0.85)),
    );
    _sparkle(canvas, const Offset(78, 52), 5, _pearl);
  }

  // ---------------------------------------------------------------- helpers

  void _bubbles(Canvas canvas, {required int seedOffset}) {
    final random = math.Random(seedOffset);
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1;
      final x = 22 + random.nextDouble() * 76;
      final y = 100 - phase * 66;
      final radius = 1.6 + random.nextDouble() * 2.6;
      canvas.drawCircle(
        Offset(x, y),
        radius,
        _fill(_pearl.withValues(alpha: (1 - phase) * 0.55)),
      );
    }
  }

  void _bubble(Canvas canvas, Offset center, double radius) {
    canvas.drawCircle(
      center,
      radius,
      _fill(_pearl.withValues(alpha: 0.55)),
    );
    canvas.drawCircle(
      center.translate(-radius * 0.3, -radius * 0.3),
      radius * 0.28,
      _fill(Colors.white.withValues(alpha: 0.8)),
    );
  }

  void _sparkle(Canvas canvas, Offset center, double radius, Color color) {
    final paint = _stroke(color, 1.8);
    canvas.drawLine(
      center.translate(-radius, 0),
      center.translate(radius, 0),
      paint,
    );
    canvas.drawLine(
      center.translate(0, -radius),
      center.translate(0, radius),
      paint,
    );
    canvas.drawCircle(center, 1.3, _fill(color));
  }

  @override
  bool shouldRepaint(covariant _StickerPainter oldDelegate) =>
      oldDelegate.sticker != sticker || oldDelegate.t != t;
}

/// The sticker tray opened from a chat. Each tile is a live preview, so the
/// picker feels like a little reef shelf.
class StickerPicker extends StatelessWidget {
  const StickerPicker({super.key, required this.strings, required this.onPick});

  final AppStrings strings;
  final ValueChanged<CoralSticker> onPick;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: palette.accent, size: 18),
                const SizedBox(width: 8),
                Text(
                  strings.get('stickersTitle'),
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              strings.get('stickersHint'),
              style: TextStyle(color: palette.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 8,
              children: [
                for (final spec in kCoralStickers)
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => onPick(spec.id),
                    child: Container(
                      width: (MediaQuery.sizeOf(context).width - 32 - 18) / 4,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: palette.surface.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: palette.divider),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StickerView(sticker: spec.id, size: 68),
                          const SizedBox(height: 2),
                          Text(
                            strings.get(spec.nameKey),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
