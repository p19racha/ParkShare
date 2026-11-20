import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'main.dart';

const googleCallback = 'com.parkshare.parkshare://auth-callback';

bool isGoogleCallback(Uri uri) =>
    uri.scheme == 'com.parkshare.parkshare' && uri.host == 'auth-callback';

bool validUsername(String value) =>
    RegExp(r'^[A-Za-z0-9_]{3,24}$').hasMatch(value);

const usernameHint =
    'Use 3 to 24 letters, numbers, or underscores for your username.';

String authMessage(Object error) {
  if (error is AuthRetryableFetchException) {
    final httpStatus = int.tryParse(error.statusCode ?? '');
    if (httpStatus != null && httpStatus >= 500) {
      return 'Supabase received the request but is temporarily unavailable. Try again shortly.';
    }
    final detail = error.message.toLowerCase();
    if (detail.contains('failed host lookup')) {
      return 'Your device could not find the ParkShare server. Try switching between Wi-Fi and mobile data.';
    }
    if (detail.contains('handshakeexception') ||
        detail.contains('certificate_verify_failed')) {
      return 'Your device could not establish a secure connection. Check automatic date and time, then try another network.';
    }
    if (detail.contains('timed out') || detail.contains('timeoutexception')) {
      return 'The sign-in request timed out. Try again or switch networks.';
    }
    return 'Could not reach the sign-in service. Check your connection and try again.';
  }
  if (error is AuthUnknownException) {
    return 'The sign-in service returned an unexpected response. Try again or switch networks.';
  }
  if (error is AuthException) {
    return switch (error.code) {
      'invalid_credentials' => 'Check your email and password and try again.',
      'email_not_confirmed' => 'This account is pending confirmation. Contact the ParkShare administrator.',
      'over_request_rate_limit' =>
        'Too many attempts. Wait a moment before trying again.',
      _ => error.message,
    };
  }
  return 'ParkShare could not complete the account request. Try again.';
}

class SignIn extends StatelessWidget {
  const SignIn({super.key, required this.client, this.callbackError});
  final String? callbackError;
  final SupabaseClient client;

  @override
  Widget build(BuildContext context) =>
      _CredentialsPage(client: client, callbackError: callbackError);
}

class SignUp extends StatelessWidget {
  const SignUp({super.key, required this.client});
  final SupabaseClient client;

  @override
  Widget build(BuildContext context) =>
      _CredentialsPage(client: client, register: true);
}

class _CredentialsPage extends StatefulWidget {
  const _CredentialsPage({
    required this.client,
    this.register = false,
    this.callbackError,
  });
  final String? callbackError;
  final SupabaseClient client;
  final bool register;

  @override
  State<_CredentialsPage> createState() => _CredentialsPageState();
}

class _CredentialsPageState extends State<_CredentialsPage> {
  final username = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final confirmation = TextEditingController();
  bool busy = false;
  bool showPassword = false;
  String? status;

  @override
  void dispose() {
    username.dispose();
    email.dispose();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    final address = email.text.trim();
    final handle = username.text.trim();
    if (widget.register && !validUsername(handle)) {
      setState(() => status = usernameHint);
      return;
    }
    if (!address.contains('@') ||
        password.text.isEmpty ||
        (widget.register && password.text.length < 6)) {
      setState(
        () => status = widget.register
            ? 'Enter your email and a password of at least 6 characters.'
            : 'Enter your email and password.',
      );
      return;
    }
    if (widget.register && password.text != confirmation.text) {
      setState(() => status = 'Passwords do not match.');
      return;
    }
    setState(() {
      busy = true;
      status = null;
    });
    try {
      final auth = widget.client.auth;
      if (widget.register) {
        final result = await auth.signUp(
          email: address,
          password: password.text,
          data: {'username': handle},
        );
        if (!mounted) return;
        if (result.session != null) {
          Navigator.pop(context);
        } else {
          setState(
            () => status = 'The account was created, but sign-in is pending. Ask the ParkShare administrator to check the Supabase email confirmation setting.',
          );
        }
      } else {
        await auth.signInWithPassword(email: address, password: password.text);
      }
    } catch (error) {
      if (mounted) {
        setState(() => status = authMessage(error));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> continueWithGoogle() async {
    setState(() {
      busy = true;
      status = null;
    });
    try {
      final launched = await widget.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: googleCallback,
        authScreenLaunchMode: LaunchMode.externalApplication,
        scopes: 'openid email profile',
      );
      if (!mounted) return;
      if (!launched) {
        setState(
          () => status = 'Could not open Google sign-in. Check that a browser is available.',
        );
      } else if (widget.register) {
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) setState(() => status = authMessage(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.register ? 'Create an account' : 'Sign in';
    return _AuthLayout(
      title: title,
      back: widget.register,
      children: [
        if (widget.register) ...[
          TextField(
            controller: username,
            enabled: !busy,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: email,
          enabled: !busy,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: password,
          enabled: !busy,
          obscureText: !showPassword,
          autofillHints: [
            widget.register
                ? AutofillHints.newPassword
                : AutofillHints.password,
          ],
          textInputAction: widget.register
              ? TextInputAction.next
              : TextInputAction.done,
          onSubmitted: widget.register ? null : (_) => submit(),
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              tooltip: showPassword ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => showPassword = !showPassword),
              icon: Icon(
                showPassword ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
        ),
        if (widget.register) ...[
          const SizedBox(height: 12),
          TextField(
            controller: confirmation,
            enabled: !busy,
            obscureText: !showPassword,
            autofillHints: const [AutofillHints.newPassword],
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => submit(),
            decoration: const InputDecoration(labelText: 'Confirm password'),
          ),
        ],
        const SizedBox(height: 18),
        FilledButton(
          onPressed: busy ? null : submit,
          child: Text(busy ? 'Working…' : title),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: busy ? null : continueWithGoogle,
          child: const Text('Continue with Google'),
        ),
        if ((status ?? widget.callbackError) case final message?)
          _Notice(message),
        if (!widget.register)
          TextButton(
            onPressed: busy
                ? null
                : () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SignUp(client: widget.client),
                    ),
                  ),
            child: const Text('Create an account'),
          ),
      ],
    );
  }
}

bool needsGoogleUsername(User? user) {
  if (user?.appMetadata['provider'] != 'google') return false;
  final username = user?.userMetadata?['username'];
  return username is! String || username.trim().isEmpty;
}

class ChooseUsername extends StatefulWidget {
  const ChooseUsername({super.key, required this.client});
  final SupabaseClient client;

  @override
  State<ChooseUsername> createState() => _ChooseUsernameState();
}

class _ChooseUsernameState extends State<ChooseUsername> {
  final username = TextEditingController();
  bool busy = false;
  String? status;

  @override
  void dispose() {
    username.dispose();
    super.dispose();
  }

  Future<void> submit(bool signOut) async {
    if (busy) return;
    final value = username.text.trim();
    if (!signOut && !validUsername(value)) {
      setState(() => status = usernameHint);
      return;
    }
    setState(() {
      busy = true;
      status = null;
    });
    try {
      if (signOut) {
        await widget.client.auth.signOut(scope: SignOutScope.local);
      } else {
        await widget.client.auth.updateUser(
          UserAttributes(data: {'username': value}),
        );
      }
    } catch (error) {
      if (mounted) setState(() => status = authMessage(error));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthLayout(
    title: 'Choose a username',
    children: [
      TextField(
        controller: username,
        enabled: !busy,
        autocorrect: false,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => submit(false),
        decoration: const InputDecoration(labelText: 'Username'),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: busy ? null : () => submit(false),
        child: const Text('Save username'),
      ),
      TextButton(
        onPressed: busy ? null : () => submit(true),
        child: const Text('Sign out'),
      ),
      if (status case final message?) _Notice(message),
    ],
  );
}

class _AuthLayout extends StatelessWidget {
  const _AuthLayout({
    required this.title,
    this.back = false,
    required this.children,
  });
  final String title;
  final bool back;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: back ? AppBar(title: const Brand()) : null,
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!back) ...[
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Brand(),
                    ),
                    const SizedBox(height: 32),
                  ],
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 22),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Semantics(liveRegion: true, child: Text(message)),
  );
}
