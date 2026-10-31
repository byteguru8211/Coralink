import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../core/strings.dart';
import '../../data/api_client.dart';
import '../../core/utils.dart';
import '../widgets/coral_widgets.dart';
import 'privacy_policy_screen.dart';

class AuthFlowScreen extends ConsumerStatefulWidget {
  const AuthFlowScreen({super.key});

  @override
  ConsumerState<AuthFlowScreen> createState() => _AuthFlowScreenState();
}

class _AuthFlowScreenState extends ConsumerState<AuthFlowScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _codeFocus = FocusNode();
  int _step = 0;
  bool _loading = false;
  String? _error;
  String? _devCode;
  int _resendIn = 0;
  String _phone = '';
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    setState(() => _resendIn = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _resendIn--;
        if (_resendIn <= 0) timer.cancel();
      });
    });
  }

  Future<void> _requestCode() async {
    final normalized = normalizePhone(_phoneController.text);
    if (!isValidPhone(normalized)) {
      setState(() => _error = ref.read(stringsProvider).get('invalidPhone'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref.read(sessionProvider.notifier).requestCode(normalized);
      if (!mounted) return;
      _phone = normalized;
      _devCode = result.devCode;
      _step = 1;
      _codeController.clear();
      _startCountdown(result.retryAfter);
      WidgetsBinding.instance.addPostFrameCallback((_) => _codeFocus.requestFocus());
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.isRateLimited
            ? '${ref.read(stringsProvider).get('resendIn')} ${error.message}'
            : error.message;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.length != 6) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).verifyCode(_phone, code);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.isRateLimited
            ? error.message
            : ref.read(stringsProvider).get('invalidCode');
        _codeController.clear();
        _codeFocus.requestFocus();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    return Scaffold(
      body: CoralBackground(
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 380),
            child: _step == 0
                ? _buildPhoneStep(context, strings, palette)
                : _buildCodeStep(context, strings, palette),
          ),
        ),
      ),
    );
  }

  Widget _buildPhoneStep(BuildContext context, AppStrings strings, CoralinkPalette palette) {
    return SingleChildScrollView(
      key: const ValueKey('phone'),
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          const CoralMark(size: 64),
          const SizedBox(height: 34),
          Text(
            strings.get('welcomeTitle'),
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 30,
              height: 1.16,
              fontWeight: FontWeight.w300,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            strings.get('welcomeSubtitle'),
            style: TextStyle(color: palette.textMuted, fontSize: 14.5, height: 1.4),
          ),
          const SizedBox(height: 40),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            autofocus: true,
            style: TextStyle(color: palette.textPrimary, fontSize: 17, letterSpacing: 0.5),
            decoration: InputDecoration(
              hintText: strings.get('phonePlaceholder'),
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 18, right: 10),
                child: Text(
                  '+',
                  style: TextStyle(color: palette.accentSoft, fontSize: 18),
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
              errorText: _error,
            ),
            onSubmitted: (_) => _requestCode(),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: _loading ? null : _requestCode,
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(strings.get('continue')),
          ),
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
              ),
              child: Text(
                strings.get('privacyPolicy'),
                style: TextStyle(color: palette.textMuted, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded, size: 13, color: palette.textMuted),
                const SizedBox(width: 6),
                Text(
                  strings.get('encryptionNotice'),
                  style: TextStyle(color: palette.textMuted, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCodeStep(BuildContext context, AppStrings strings, CoralinkPalette palette) {
    final code = _codeController.text;
    return SingleChildScrollView(
      key: const ValueKey('code'),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            onPressed: () => setState(() {
              _step = 0;
              _error = null;
              _codeController.clear();
            }),
            icon: Icon(Icons.arrow_back_rounded, color: palette.textPrimary),
          ),
          const SizedBox(height: 18),
          Text(
            strings.get('codeTitle'),
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w300,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${strings.get('codeSubtitle')} ${maskPhone(_phone)}',
            style: TextStyle(color: palette.textMuted, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 34),
          Stack(
            children: [
              Row(
                children: List.generate(6, (index) {
                  final active = code.length == index && _codeFocus.hasFocus;
                  final filled = index < code.length;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: index == 5 ? 0 : 8),
                      child: GestureDetector(
                        onTap: () => _codeFocus.requestFocus(),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          height: 58,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: palette.inputFill,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: active
                                  ? palette.accent
                                  : filled
                                      ? palette.accent.withValues(alpha: 0.5)
                                      : palette.divider,
                              width: active ? 1.6 : 1,
                            ),
                          ),
                          child: Text(
                            filled ? code[index] : '',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
              Positioned.fill(
                child: Opacity(
                  opacity: 0.01,
                  child: TextField(
                    controller: _codeController,
                    focusNode: _codeFocus,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    showCursor: false,
                    style: const TextStyle(color: Colors.transparent),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      counterText: '',
                      fillColor: Colors.transparent,
                      filled: false,
                    ),
                    onChanged: (value) {
                      setState(() {});
                      if (value.length == 6 && !_loading) _verify();
                    },
                  ),
                ),
              ),
            ],
          ),
          if (_devCode != null) ...[
            const SizedBox(height: 18),
            GlassPanel(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              margin: EdgeInsets.zero,
              child: Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 18, color: palette.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${strings.get('devCode')}: $_devCode',
                      style: TextStyle(color: palette.textMuted, fontSize: 12.5, letterSpacing: 1),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(
              _error!,
              style: TextStyle(color: palette.coral, fontSize: 13),
            ),
          ],
          const SizedBox(height: 26),
          FilledButton(
            onPressed: _loading || code.length != 6 ? null : _verify,
            child: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(strings.get('continue')),
          ),
          const SizedBox(height: 18),
          Center(
            child: TextButton(
              onPressed: _resendIn > 0 || _loading
                  ? null
                  : () async {
                      await _requestCode();
                    },
              child: Text(
                _resendIn > 0
                    ? '${strings.get('resendIn')} $_resendIn'
                    : strings.get('resend'),
                style: TextStyle(
                  color: _resendIn > 0 ? palette.textMuted : palette.accent,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
