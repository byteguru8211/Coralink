import 'package:flutter/material.dart';

/// Coralink brand palette from the product specification.
abstract final class BrandColors {
  static const emerald = Color(0xFF1A9C7A);
  static const emeraldLight = Color(0xFF7FCDB5);
  static const emeraldDeep = Color(0xFF0D4F3C);
  static const backgroundDark = Color(0xFF0D2E1F);
  static const backgroundLight = Color(0xFFF0F7F4);
  static const coral = Color(0xFFFF6B5A);
  static const textMuted = Color(0xFFA0C4B4);
  static const white = Color(0xFFFFFFFF);
}

@immutable
class CoralinkPalette extends ThemeExtension<CoralinkPalette> {
  const CoralinkPalette({
    required this.background,
    required this.appBar,
    required this.surface,
    required this.surfaceElevated,
    required this.textPrimary,
    required this.textMuted,
    required this.accent,
    required this.accentSoft,
    required this.outgoingBubble,
    required this.outgoingText,
    required this.incomingBubble,
    required this.incomingText,
    required this.coral,
    required this.halo,
    required this.divider,
    required this.inputFill,
    required this.navBackground,
    required this.shadow,
  });

  final Color background;
  final Color appBar;
  final Color surface;
  final Color surfaceElevated;
  final Color textPrimary;
  final Color textMuted;
  final Color accent;
  final Color accentSoft;
  final Color outgoingBubble;
  final Color outgoingText;
  final Color incomingBubble;
  final Color incomingText;
  final Color coral;
  final Color halo;
  final Color divider;
  final Color inputFill;
  final Color navBackground;
  final Color shadow;

  static const dark = CoralinkPalette(
    background: BrandColors.backgroundDark,
    appBar: BrandColors.emeraldDeep,
    surface: Color(0xFF10382A),
    surfaceElevated: Color(0xFF17493A),
    textPrimary: BrandColors.white,
    textMuted: BrandColors.textMuted,
    accent: BrandColors.emerald,
    accentSoft: BrandColors.emeraldLight,
    outgoingBubble: BrandColors.emerald,
    outgoingText: BrandColors.white,
    incomingBubble: BrandColors.emeraldLight,
    incomingText: BrandColors.emeraldDeep,
    coral: BrandColors.coral,
    halo: Color(0xFF3FD3A8),
    divider: Color(0x1FFFFFFF),
    inputFill: Color(0x330D4F3C),
    navBackground: Color(0xFF0A2418),
    shadow: Color(0x66000000),
  );

  static const light = CoralinkPalette(
    background: BrandColors.backgroundLight,
    appBar: BrandColors.white,
    surface: BrandColors.white,
    surfaceElevated: Color(0xFFE4F2EC),
    textPrimary: BrandColors.emeraldDeep,
    textMuted: Color(0xFF5C8577),
    accent: BrandColors.emerald,
    accentSoft: Color(0xFFD0E8E0),
    outgoingBubble: BrandColors.emerald,
    outgoingText: BrandColors.white,
    incomingBubble: Color(0xFFD0E8E0),
    incomingText: BrandColors.emeraldDeep,
    coral: BrandColors.coral,
    halo: BrandColors.emerald,
    divider: Color(0x140D4F3C),
    inputFill: Color(0xFFE4F2EC),
    navBackground: BrandColors.white,
    shadow: Color(0x1A0D4F3C),
  );

  @override
  CoralinkPalette copyWith() => this;

  @override
  CoralinkPalette lerp(ThemeExtension<CoralinkPalette>? other, double t) {
    if (other is! CoralinkPalette) return this;
    return CoralinkPalette(
      background: Color.lerp(background, other.background, t)!,
      appBar: Color.lerp(appBar, other.appBar, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      outgoingBubble: Color.lerp(outgoingBubble, other.outgoingBubble, t)!,
      outgoingText: Color.lerp(outgoingText, other.outgoingText, t)!,
      incomingBubble: Color.lerp(incomingBubble, other.incomingBubble, t)!,
      incomingText: Color.lerp(incomingText, other.incomingText, t)!,
      coral: Color.lerp(coral, other.coral, t)!,
      halo: Color.lerp(halo, other.halo, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      inputFill: Color.lerp(inputFill, other.inputFill, t)!,
      navBackground: Color.lerp(navBackground, other.navBackground, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

extension PaletteX on BuildContext {
  CoralinkPalette get palette =>
      Theme.of(this).extension<CoralinkPalette>() ?? CoralinkPalette.dark;
}

/// Deterministic seed-avatar gradient for a user id.
List<Color> seedGradient(String seed) {
  final palettes = <List<Color>>[
    [const Color(0xFF1A9C7A), const Color(0xFF0D4F3C)],
    [const Color(0xFF2FB894), const Color(0xFF146955)],
    [const Color(0xFF7FCDB5), const Color(0xFF1A9C7A)],
    [const Color(0xFF3E9C6B), const Color(0xFF164E37)],
    [const Color(0xFF58C3A2), const Color(0xFF236B57)],
    [const Color(0xFF0F8F71), const Color(0xFF57B99B)],
  ];
  var h = 0;
  for (final code in seed.codeUnits) {
    h = (h * 31 + code) & 0x7fffffff;
  }
  return palettes[h % palettes.length];
}
