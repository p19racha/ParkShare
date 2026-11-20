import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parkshare/auth.dart';
import 'package:parkshare/account.dart';
import 'package:parkshare/market.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth implements GoTrueClient {
  Object error = const AuthException(
    'Invalid credentials',
    code: 'invalid_credentials',
  );
  String? registeredEmail;
  Map<String, dynamic>? signupData;

  Object? profileUpdate;

  @override
  User get currentUser => const User(
    id: 'test-user',
    appMetadata: {},
    userMetadata: {'username': 'original_user'},
    aud: 'authenticated',
    createdAt: '2026-01-01',
    email: 'pilot@example.test',
  );

  @override
  Future<UserResponse> updateUser(
    UserAttributes attributes, {
    String? emailRedirectTo,
  }) async {
    profileUpdate = attributes.data;
    return UserResponse.fromJson(currentUser.toJson());
  }

  @override
  Future<AuthResponse> signInWithPassword({
    String? email,
    String? phone,
    required String password,
    String? captchaToken,
  }) async => throw error;

  @override
  Future<AuthResponse> signUp({
    String? email,
    String? phone,
    required String password,
    String? emailRedirectTo,
    Map<String, dynamic>? data,
    String? captchaToken,
    OtpChannel channel = OtpChannel.sms,
  }) async {
    registeredEmail = email;
    signupData = data;
    return AuthResponse(
      session: Session(
        accessToken: 'test-token',
        tokenType: 'bearer',
        user: currentUser,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements SupabaseClient {
  _Client(this.fixture);
  final _Auth fixture;

  @override
  GoTrueClient get auth => fixture;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Sign-in reports errors and signup requires matching passwords', (
    tester,
  ) async {
    final auth = _Auth();
    final client = _Client(auth);
    await tester.pumpWidget(MaterialApp(home: SignIn(client: client)));
    await tester.enterText(
      find.byType(TextField).first,
      ' pilot@example.test ',
    );
    await tester.enterText(find.byType(TextField).last, 'test-password');

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Check your email and password and try again.'),
      findsOneWidget,
    );

    auth.error = AuthRetryableFetchException();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Could not reach the sign-in service. Check your connection and try again.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    expect(find.byType(SignUp), findsOneWidget);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(4));
    await tester.enterText(fields.at(1), ' pilot@example.test ');
    await tester.enterText(fields.at(2), 'test-password');
    await tester.enterText(fields.at(3), 'different-password');
    final register = find.widgetWithText(FilledButton, 'Create an account');
    await tester.tap(register);
    await tester.pumpAndSettle();
    expect(auth.registeredEmail, isNull);
    await tester.enterText(fields.first, ' pilot_user ');
    await tester.tap(register);
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(auth.registeredEmail, isNull);
    await tester.enterText(fields.at(3), 'test-password');
    await tester.tap(register);
    await tester.pumpAndSettle();
    expect(auth.signupData, {'username': 'pilot_user'});
    expect(auth.registeredEmail, 'pilot@example.test');
    expect(find.byType(SignIn), findsOneWidget);
  });

  testWidgets(
    'Profile shows the account email and saves the edited display name',
    (tester) async {
      final auth = _Auth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Profile(client: _Client(auth), signOut: () async {}),
          ),
        ),
      );
      expect(find.text('pilot@example.test'), findsOneWidget);
      expect(find.text('Username'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'original_user',
      );
      await tester.enterText(find.byType(TextField), ' Updated name ');
      await tester.tap(find.text('Save profile'));
      await tester.pumpAndSettle();
      expect(auth.profileUpdate, {'display_name': 'Updated name'});
      expect(find.text('Profile saved.'), findsOneWidget);
    },
  );

  testWidgets('Google onboarding saves a valid username', (tester) async {
    final auth = _Auth();
    await tester.pumpWidget(
      MaterialApp(home: ChooseUsername(client: _Client(auth))),
    );
    await tester.tap(find.text('Save username'));
    await tester.pumpAndSettle();
    expect(find.text(usernameHint), findsOneWidget);
    expect(auth.profileUpdate, isNull);
    await tester.enterText(find.byType(TextField), ' google_user ');
    await tester.tap(find.text('Save username'));
    await tester.pumpAndSettle();
    expect(auth.profileUpdate, {'username': 'google_user'});
  });

  test('Google callback and first-sign-in checks are scoped', () {
    expect(isGoogleCallback(Uri.parse('$googleCallback?code=example')), isTrue);
    expect(
      isGoogleCallback(Uri.parse('other.app://auth-callback?code=example')),
      isFalse,
    );
    final data = _Auth().currentUser.toJson();
    expect(
      needsGoogleUsername(
        User.fromJson({
          ...data,
          'app_metadata': {'provider': 'google'},
        }),
      ),
      isFalse,
    );
    expect(
      needsGoogleUsername(
        User.fromJson({
          ...data,
          'app_metadata': {'provider': 'google'},
          'user_metadata': <String, dynamic>{},
        }),
      ),
      isTrue,
    );
    expect(
      needsGoogleUsername(
        User.fromJson({
          ...data,
          'app_metadata': {'provider': 'email'},
          'user_metadata': <String, dynamic>{},
        }),
      ),
      isFalse,
    );
  });

  test('Auth failures distinguish server, DNS, TLS, and unexpected errors', () {
    expect(
      authMessage(AuthRetryableFetchException(statusCode: '503')),
      contains('temporarily unavailable'),
    );
    expect(
      authMessage(AuthRetryableFetchException(message: 'Failed host lookup')),
      contains('could not find'),
    );
    expect(
      authMessage(AuthRetryableFetchException(message: 'HandshakeException')),
      contains('secure connection'),
    );
    expect(
      authMessage(StateError('internal detail')),
      contains('could not complete the account request'),
    );
  });

  test('Gateway and application errors keep an actionable message', () {
    expect(
      marketErrorMessage(
        const FunctionException(
          status: 404,
          details: {
            'code': 'NOT_FOUND',
            'message': 'Requested function was not found',
          },
        ),
      ),
      contains('Deploy the market Edge Function'),
    );
    expect(
      marketErrorMessage(
        const FunctionException(
          status: 409,
          details: {'error': 'Enter a valid IANA time zone.'},
        ),
      ),
      'Enter a valid IANA time zone.',
    );
    expect(
      marketErrorMessage(
        const FunctionException(
          status: 500,
          details: {'message': 'Service unavailable.'},
        ),
      ),
      'Service unavailable.',
    );
  });
}
