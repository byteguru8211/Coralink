import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop integration for the Windows build. Coralink on the desktop is a
/// first-class client, not a preview: it owns a real resizable window, lives in
/// the system tray and keeps running (and receiving) when the window is closed.
class DesktopShell with WindowListener, TrayListener {
  DesktopShell._();

  static final DesktopShell instance = DesktopShell._();

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get _hasTray =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  bool _windowReady = false;
  bool _trayReady = false;
  bool _trayHealthy = false;
  bool _quitting = false;
  bool _closeToTray = true;
  String _locale = 'ru';
  String? _iconPath;

  Future<void> init({bool closeToTray = true}) async {
    if (!_isDesktop || _windowReady) return;
    _windowReady = true;
    _closeToTray = closeToTray;
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1240, 820),
      minimumSize: Size(430, 620),
      center: true,
      title: 'Coralink',
      backgroundColor: Color(0xFF0B1512),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
    );
    // Not awaited: waiting for the platform window from `main` can deadlock
    // before the first frame.
    unawaited(
      windowManager.waitUntilReadyToShow(options, () async {
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setPreventClose(true);
      }),
    );
    windowManager.addListener(this);
  }

  void setCloseToTray(bool value) {
    _closeToTray = value;
  }

  /// Builds the tray icon (asset -> temp .ico file, which is what the Windows
  /// shell can load) and its context menu. Safe to call after `runApp`.
  Future<void> attachTray({String locale = 'ru'}) async {
    if (!_hasTray) return;
    _locale = locale;
    if (_trayReady) {
      await _applyMenu();
      return;
    }
    _trayReady = true;
    try {
      final icon = await _ensureIconFile();
      if (icon != null) await trayManager.setIcon(icon);
      await trayManager.setToolTip('Coralink');
      await _applyMenu();
      trayManager.addListener(this);
      _trayHealthy = icon != null;
    } catch (error) {
      debugPrint('desktop.tray: $error');
    }
  }

  /// Localizes the tray menu. Called when the interface language changes.
  Future<void> setLocale(String locale) async {
    if (!_hasTray || locale == _locale) return;
    _locale = locale;
    await _applyMenu();
  }

  Future<void> showWindow() async {
    if (!_isDesktop) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    _quitting = true;
    try {
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  String get _openLabel =>
      _locale == 'en' ? 'Open Coralink' : 'Открыть Coralink';

  String get _quitLabel => _locale == 'en' ? 'Quit' : 'Выход';

  Future<void> _applyMenu() async {
    if (!_hasTray) return;
    try {
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: _openLabel),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: _quitLabel),
          ],
        ),
      );
    } catch (error) {
      debugPrint('desktop.tray.menu: $error');
    }
  }

  Future<String?> _ensureIconFile() async {
    final cached = _iconPath;
    if (cached != null && File(cached).existsSync()) return cached;
    try {
      final data = await rootBundle.load('assets/images/tray_icon.ico');
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'coralink_tray.ico'));
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      _iconPath = file.path;
      return file.path;
    } catch (error) {
      debugPrint('desktop.tray.icon: $error');
      return null;
    }
  }

  @override
  void onWindowClose() async {
    if (!_isDesktop || _quitting) return;
    // Without a working tray icon, hiding the window would leave the user with
    // a running app they cannot reach: in that case close normally.
    if (_closeToTray && _trayHealthy) {
      await windowManager.hide();
    } else {
      await quit();
    }
  }

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'quit') {
      quit();
    } else if (menuItem.key == 'show') {
      showWindow();
    }
  }
}
