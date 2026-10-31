import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../core/app_colors.dart';
import '../widgets/coral_widgets.dart';

class SplashScreen extends ConsumerWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final strings = ref.watch(stringsProvider);
    return Scaffold(
      body: CoralBackground(
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 3),
              Column(
                children: [
                  const CoralMark(size: 128)
                      .animate()
                      .fadeIn(duration: 700.ms, curve: Curves.easeOut)
                      .scale(
                        begin: const Offset(0.82, 0.82),
                        end: const Offset(1, 1),
                        duration: 1100.ms,
                        curve: Curves.easeOutBack,
                      ),
                  const SizedBox(height: 28),
                  Text(
                    'Coralink',
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: 34,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 5,
                      shadows: [
                        Shadow(color: palette.accent.withValues(alpha: 0.45), blurRadius: 22),
                      ],
                    ),
                  ).animate().fadeIn(delay: 520.ms, duration: 800.ms),
                  const SizedBox(height: 10),
                  Text(
                    strings.get('slogan'),
                    style: TextStyle(
                      color: palette.textMuted,
                      fontSize: 13,
                      letterSpacing: 1.6,
                    ),
                  ).animate().fadeIn(delay: 900.ms, duration: 800.ms),
                ],
              ),
              const Spacer(flex: 3),
              TypingDots(color: palette.accentSoft)
                  .animate()
                  .fadeIn(delay: 1200.ms, duration: 600.ms),
              const SizedBox(height: 18),
              Text(
                strings.get('loading'),
                style: TextStyle(color: palette.textMuted, fontSize: 12, letterSpacing: 1),
              ).animate().fadeIn(delay: 1300.ms),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
