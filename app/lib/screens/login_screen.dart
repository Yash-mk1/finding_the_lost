import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../session.dart';
import '../widgets.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();
  final _code = TextEditingController();
  bool _registering = false;
  bool _busy = false;
  bool _hidePassword = true;
  Map<String, dynamic> _fieldErrors = {};

  /// Set while waiting for the 6-digit code from the email.
  PendingVerification? _pending;
  String? _codeError;
  int _resendIn = 0;

  // Hidden server setting: tap the logo 7 times within 3 seconds.
  int _logoTaps = 0;
  DateTime? _firstLogoTap;
  Timer? _resendTimer;

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    _code.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _fieldErrors = {});
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final session = context.read<Session>();
    try {
      if (_registering) {
        final pending = await session.register(
          _username.text.trim(),
          _email.text.trim(),
          _password.text,
          _displayName.text.trim(),
        );
        if (pending != null) _askForCode(pending);
      } else {
        await session.login(_username.text.trim(), _password.text);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      final pending = e.verification;
      if (pending != null) {
        _askForCode(pending); // right password, email not confirmed yet
      } else {
        setState(() => _fieldErrors = e.fieldErrors);
        showSnack(context, e.message, error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------ email code step ---

  void _askForCode(PendingVerification pending) {
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _code.clear();
      _codeError = pending.emailFailed ? pending.message : null;
    });
    // Right after an email goes out, wait a minute before offering another.
    _startResendTimer(pending.emailFailed ? 0 : (pending.resendIn > 0 ? pending.resendIn : 60));
  }

  void _startResendTimer(int seconds) {
    _resendTimer?.cancel();
    setState(() => _resendIn = seconds);
    if (seconds <= 0) return;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _resendIn -= 1);
      if (_resendIn <= 0) timer.cancel();
    });
  }

  Future<void> _verify() async {
    final pending = _pending;
    final code = _code.text.trim();
    if (pending == null) return;
    if (code.length != 6) {
      setState(() => _codeError = 'Enter all 6 digits.');
      return;
    }
    setState(() {
      _busy = true;
      _codeError = null;
    });
    try {
      await context.read<Session>().verifyEmail(pending.username, code);
      // Signed in: the app switches to the home screen by itself.
    } on ApiException catch (e) {
      if (mounted) setState(() => _codeError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    final pending = _pending;
    if (pending == null) return;
    setState(() => _busy = true);
    try {
      final message = await context.read<Session>().api.resendCode(pending.username);
      if (!mounted) return;
      setState(() => _codeError = null);
      showSnack(context, message);
      _startResendTimer(60);
    } on ApiException catch (e) {
      if (!mounted) return;
      final wait = (e.body['resend_in'] as num?)?.toInt();
      if (wait != null && wait > 0) _startResendTimer(wait);
      showSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _backToLogin() {
    _resendTimer?.cancel();
    final username = _pending?.username;
    setState(() {
      _pending = null;
      _registering = false;
      _codeError = null;
      _password.clear();
      if (username != null && username.isNotEmpty) _username.text = username;
    });
  }

  // ------------------------------------------------------- server address ---

  void _onLogoTap() {
    final now = DateTime.now();
    if (_firstLogoTap == null || now.difference(_firstLogoTap!) > const Duration(seconds: 3)) {
      _firstLogoTap = now;
      _logoTaps = 0;
    }
    _logoTaps++;
    if (_logoTaps >= 7) {
      _logoTaps = 0;
      _firstLogoTap = null;
      _editServer();
    }
  }

  Future<void> _editServer() async {
    final session = context.read<Session>();
    final controller = TextEditingController(text: session.api.baseUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          final unencrypted = ApiClient.isUnencryptedPublic(controller.text);
          return AlertDialog(
            title: const Text('Server address'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('For testing only. Normal users never need to change this.'),
                const SizedBox(height: 4),
                Text('Built-in: $kDefaultApiBase', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.url,
                  autofocus: true,
                  onChanged: (_) => setDialog(() {}),
                ),
                if (unencrypted) ...[
                  const SizedBox(height: 8),
                  Text(
                    'This address is not encrypted: passwords would travel over the internet in plain text. '
                    'Use an https:// address.',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, kDefaultApiBase), child: const Text('Use built-in')),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
            ],
          );
        },
      ),
    );
    if (value != null && value.trim().isNotEmpty) {
      await session.setServer(value);
      if (mounted) {
        showSnack(context, session.meta == null ? "Saved, but the server didn't answer." : 'Connected to server.');
      }
    }
  }

  String? _serverError(String field) {
    final error = _fieldErrors[field];
    return error?.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _pending != null ? _codeStep(theme, _pending!) : _loginForm(theme),
          ),
        ),
      ),
    );
  }

  Widget _codeStep(ThemeData theme, PendingVerification pending) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.mark_email_unread_outlined, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text(
          'Check your email',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'We sent a 6-digit code to ${pending.emailHint}. It expires in 10 minutes. '
          "Can't see it? Check spam.",
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 12, fontWeight: FontWeight.w600),
          decoration: InputDecoration(counterText: '', hintText: '------', errorText: _codeError, errorMaxLines: 3),
          onChanged: (value) {
            if (value.length == 6 && !_busy) _verify();
          },
          onSubmitted: (_) => _verify(),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _verify,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: _busy
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Confirm'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy || _resendIn > 0 ? null : _resend,
          child: Text(_resendIn > 0 ? 'Send a new code in ${_resendIn}s' : 'Send a new code'),
        ),
        TextButton(onPressed: _busy ? null : _backToLogin, child: const Text('Back to log in')),
      ],
    );
  }

  Widget _loginForm(ThemeData theme) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: _onLogoTap,
            child: Icon(Icons.travel_explore, size: 64, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 12),
          Text(
            'Finding the Lost',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Found something? Lost something? Your neighbours can help.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 28),
          TextFormField(
            controller: _username,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: _registering ? 'Username' : 'Username or email',
              errorText: _serverError('username'),
            ),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          if (_registering) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Email',
                helperText: "We'll send a code to confirm it's yours.",
                errorText: _serverError('email'),
              ),
              validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _displayName,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Display name (optional)'),
            ),
          ],
          const SizedBox(height: 12),
          TextFormField(
            controller: _password,
            obscureText: _hidePassword,
            onFieldSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              errorText: _serverError('password') ?? _serverError('non_field_errors'),
              errorMaxLines: 3,
              suffixIcon: IconButton(
                icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _hidePassword = !_hidePassword),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Required';
              if (_registering && v.length < 8) return 'At least 8 characters';
              return null;
            },
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(_registering ? 'Create account' : 'Log in'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _registering = !_registering;
                    _fieldErrors = {};
                  }),
            child: Text(_registering ? 'I already have an account' : 'New here? Create an account'),
          ),
        ],
      ),
    );
  }
}
