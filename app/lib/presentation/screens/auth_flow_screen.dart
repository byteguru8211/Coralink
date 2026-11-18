import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/dependencies.dart';
import '../../app/session.dart';
import '../../core/app_colors.dart';
import '../../data/api_client.dart';
import '../widgets/coral_widgets.dart';
import 'privacy_policy_screen.dart';

enum _AuthMode { register, login }

class AuthFlowScreen extends ConsumerStatefulWidget {
  const AuthFlowScreen({super.key});

  @override
  ConsumerState<AuthFlowScreen> createState() => _AuthFlowScreenState();
}

class _AuthFlowScreenState extends ConsumerState<AuthFlowScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _password;
  late final TextEditingController _confirm;
  _AuthMode _mode = _AuthMode.register;
  bool _loading = false;
  bool _showPassword = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final savedUrl = ref.read(settingsProvider).serverUrl;
    final fallback = ref.read(configProvider).apiBaseUrl;
    _url = TextEditingController(text: savedUrl.isNotEmpty ? savedUrl : fallback);
    _username = TextEditingController();
    _firstName = TextEditingController();
    _lastName = TextEditingController();
    _password = TextEditingController();
    _confirm = TextEditingController();
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _firstName.dispose();
    _lastName.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? _validateUsername(String? value) {
    final username = (value ?? '').trim().toLowerCase();
    if (username.isEmpty) {
      return ref.read(stringsProvider).get('usernameRequired');
    }
    if (username.length < 3 || username.length > 32) {
      return ref.read(stringsProvider).get('invalidUsername');
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9._]*[a-z0-9]$').hasMatch(username)) {
      return ref.read(stringsProvider).get('invalidUsername');
    }
    return null;
  }

  String? _validateUrl(String? value) {
    final url = (value ?? '').trim();
    if (url.isEmpty) return ref.read(stringsProvider).get('serverUrlRequired');
    final withScheme =
        url.startsWith('http://') || url.startsWith('https://') ? url : 'https://$url';
    final parsed = Uri.tryParse(withScheme);
    if (parsed == null || !parsed.hasAuthority || parsed.host.isEmpty) {
      return ref.read(stringsProvider).get('invalidServerUrl');
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.length < 6) {
      return ref.read(stringsProvider).get('passwordTooShort');
    }
    return null;
  }

  String? _validateConfirm(String? value) {
    if (value != _password.text) {
      return ref.read(stringsProvider).get('passwordsDiffer');
    }
    return null;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(settingsProvider.notifier).setServerUrl(_url.text.trim());
      final username = _username.text.trim().toLowerCase();
      if (_mode == _AuthMode.register) {
        final name = '${_firstName.text.trim()} ${_lastName.text.trim()}'.trim();
        await ref.read(sessionProvider.notifier).register(
              username,
              password: _password.text,
              name: name.isEmpty ? null : name,
            );
      } else {
        await ref
            .read(sessionProvider.notifier)
            .login(username, _password.text);
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(stringsProvider);
    final palette = context.palette;
    final isRegister = _mode == _AuthMode.register;
    return Scaffold(
      body: CoralBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 6),
                      const Center(child: CoralMark(size: 56)),
                      const SizedBox(height: 22),
                      Center(
                        child: SegmentedButton<_AuthMode>(
                          segments: [
                            ButtonSegment(
                              value: _AuthMode.register,
                              label: Text(strings.get('createAccount')),
                            ),
                            ButtonSegment(
                              value: _AuthMode.login,
                              label: Text(strings.get('signIn')),
                            ),
                          ],
                          selected: {_mode},
                          onSelectionChanged: (s) => setState(() {
                            _mode = s.first;
                            _error = null;
                          }),
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: _url,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        enabled: !_loading,
                        validator: _validateUrl,
                        style: TextStyle(color: palette.textPrimary, fontSize: 15),
                        decoration: InputDecoration(
                          labelText: strings.get('serverLink'),
                          hintText: 'https://host.tailnet.ts.net',
                          prefixIcon: Icon(Icons.link_rounded, color: palette.accent),
                          helperText: strings.get('serverLinkNote'),
                          helperMaxLines: 3,
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _username,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        enabled: !_loading,
                        validator: _validateUsername,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9._]')),
                        ],
                        style: TextStyle(color: palette.textPrimary),
                        decoration: InputDecoration(
                          labelText: strings.get('nickname'),
                          hintText: strings.get('nicknamePlaceholder'),
                          prefixIcon: Icon(
                            Icons.alternate_email_rounded,
                            color: palette.accent,
                          ),
                        ),
                      ),
                      if (isRegister) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _firstName,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          enabled: !_loading,
                          style: TextStyle(color: palette.textPrimary),
                          decoration: InputDecoration(
                            labelText: strings.get('firstName'),
                            prefixIcon: Icon(
                              Icons.person_outline_rounded,
                              color: palette.accent,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _lastName,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          enabled: !_loading,
                          style: TextStyle(color: palette.textPrimary),
                          decoration: InputDecoration(
                            labelText: strings.get('lastName'),
                            prefixIcon: Icon(
                              Icons.person_outline_rounded,
                              color: palette.accentSoft,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        obscureText: !_showPassword,
                        textInputAction: isRegister ? TextInputAction.next : TextInputAction.done,
                        enabled: !_loading,
                        validator: _validatePassword,
                        style: TextStyle(color: palette.textPrimary),
                        decoration: InputDecoration(
                          labelText: strings.get('password'),
                          prefixIcon: Icon(Icons.lock_outline_rounded, color: palette.accent),
                          suffixIcon: IconButton(
                            onPressed: () => setState(() => _showPassword = !_showPassword),
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: palette.textMuted,
                            ),
                          ),
                        ),
                      ),
                      if (isRegister) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirm,
                          obscureText: !_showPassword,
                          textInputAction: TextInputAction.done,
                          enabled: !_loading,
                          validator: _validateConfirm,
                          onFieldSubmitted: (_) => _submit(),
                          style: TextStyle(color: palette.textPrimary),
                          decoration: InputDecoration(
                            labelText: strings.get('confirmPassword'),
                            prefixIcon: Icon(
                              Icons.lock_outline_rounded,
                              color: palette.accentSoft,
                            ),
                          ),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(_error!, style: TextStyle(color: palette.coral, fontSize: 13)),
                      ],
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: _loading ? null : _submit,
                        child: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(isRegister
                                ? strings.get('createAccount')
                                : strings.get('signIn')),
                      ),
                      const SizedBox(height: 14),
                      Center(
                        child: TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const PrivacyPolicyScreen(),
                            ),
                          ),
                          child: Text(
                            strings.get('privacyPolicy'),
                            style: TextStyle(color: palette.textMuted, fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
