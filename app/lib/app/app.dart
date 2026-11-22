import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_colors.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../data/settings_store.dart';
import '../domain/models.dart';
import 'dependencies.dart';
import 'session.dart';
import '../presentation/screens/auth_flow_screen.dart';
import '../presentation/screens/chat_screen.dart';
import '../presentation/screens/error_screen.dart';
import '../presentation/screens/home_shell.dart';
import '../presentation/screens/profile_setup_screen.dart';
import '../presentation/screens/splash_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class CoralinkApp extends ConsumerStatefulWidget {
  const CoralinkApp({super.key});

  @override
  ConsumerState<CoralinkApp> createState() => _CoralinkAppState();
}

class _CoralinkAppState extends ConsumerState<CoralinkApp> with WidgetsBindingObserver {
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final notifications = ref.read(notificationProvider);
    notifications.onOpenChat = (chatId) {
      final state = ref.read(sessionProvider);
      if (!state.isAuthenticated) return;
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)),
      );
    };
    // Initialize and, on Android/iOS, ask for the notification permission once
    // the first frame is on screen. Asking earlier can be ignored by the
    // platform, which leaves the app with sound but no notification in the
    // shade. The check also runs whenever the app comes back to the foreground.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureNotifications());
    });
    _resetIdle();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idleTimer?.cancel();
    super.dispose();
  }

  void _resetIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(minutes: 5), () {
      ref.read(sessionProvider.notifier).setPresence('away');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final session = ref.read(sessionProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
        session.setPresence('active');
        _resetIdle();
        unawaited(_ensureNotifications());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        session.setPresence('away');
    }
  }

  Future<void> _ensureNotifications() async {
    final notifications = ref.read(notificationProvider);
    if (ref.read(settingsProvider).notificationMode == NotificationMode.offline) {
      return;
    }
    await notifications.init();
    if (await notifications.areEnabled()) return;
    await notifications.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    ref.listen(sessionProvider, (previous, next) {
      if (next.status == SessionStatus.unauthenticated ||
          next.status == SessionStatus.onboarding) {
        navigatorKey.currentState?.popUntil((route) => route.isFirst);
      }
    });
    return MaterialApp(
      title: 'Coralink',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: AppTheme.build(Brightness.light),
      darkTheme: AppTheme.build(Brightness.dark),
      themeMode: settings.themeMode,
      locale: Locale(settings.localeCode),
      supportedLocales: AppStrings.supported,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(minScaleFactor: 0.9, maxScaleFactor: 1.4),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final widget = switch (session.status) {
      SessionStatus.booting => const SplashScreen(),
      SessionStatus.unauthenticated => const AuthFlowScreen(),
      SessionStatus.onboarding => ProfileSetupScreen(user: session.user!),
      SessionStatus.authenticated => const HomeShell(),
      SessionStatus.error => ErrorScreen(
          message: session.message ?? '',
          onRetry: () => ref.read(sessionProvider.notifier).retryRestore(),
          onSignOut: () => ref.read(sessionProvider.notifier).logout(),
        ),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: KeyedSubtree(
        key: ValueKey(session.status),
        child: widget,
      ),
    );
  }
}

class AuthenticatedScope extends ConsumerWidget {
  const AuthenticatedScope({super.key, required this.builder});
  final Widget Function(BuildContext, User) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).user;
    if (user == null) {
      return Scaffold(backgroundColor: context.palette.background);
    }
    return builder(context, user);
  }
}
