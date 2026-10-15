import 'dart:async';
import 'dart:convert';
import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'support.dart';

Matcher code(String value) =>
    isA<ChatGptException>().having((e) => e.code, 'code', value);

void main() {
  late FakeOpenAi fake;
  setUp(() => fake = FakeOpenAi());
  tearDown(() => fake.auth.close());

  test('PKCE matches RFC 7636 S256 vector; each attempt has fresh secrets', () {
    expect(
      pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    final a = AuthorizationAttempt(
      redirectUri: Uri.parse('http://127.0.0.1:1/auth/callback'),
    );
    final b = AuthorizationAttempt(redirectUri: a.redirectUri);
    expect(a.state, isNot(b.state));
    expect(a.nonce, isNot(b.nonce));
    expect(a.verifier, matches(RegExp(r'^[a-zA-Z0-9_-]{43,128}$')));
  });

  test(
    'first sign-in uses dynamic registration and issued ID for exchange',
    () async {
      final profile = await fake.auth.signIn();
      final query = fake.authorization!.queryParameters;
      expect(query['client_id'], dynamicClientId);
      expect(query['ext_agent_host_id'], startsWith('urn:uuid:'));
      expect(query['resource'], openAiResource);
      expect(query['scope']!.split(' '), containsAll(requestedScopes));
      expect(query.containsKey('prompt'), false);
      final exchange = fake.tokenForms.single;
      expect(exchange['client_id'], fake.issuedClient);
      expect(exchange['redirect_uri'], query['redirect_uri']);
      expect(
        pkceChallenge(exchange['code_verifier']!),
        query['code_challenge'],
      );
      expect(exchange.containsKey('client_secret'), false);
      expect(profile.subject, 'subject_1');
      expect(profile.planEnabled, true);
      expect(fake.store.value, isNot(contains(dynamicClientId)));
    },
  );

  test(
    'reauthorization reuses host/client and retained hints; logout clears hints',
    () async {
      final first = await fake.auth.signIn();
      final host = fake.authorization!.queryParameters['ext_agent_host_id'];
      fake.omitCallbackClientId = true;
      await fake.auth.signIn(clientId: first.clientId);
      final query = fake.authorization!.queryParameters;
      expect(query['client_id'], first.clientId);
      expect(query['ext_agent_host_id'], host);
      expect(query.containsKey('agent_name_hint'), false);
      expect(query['id_token_hint'], isNotEmpty);
      await fake.auth.signOut(first.clientId);
      await fake.auth.signIn(clientId: first.clientId);
      expect(
        fake.authorization!.queryParameters.containsKey('id_token_hint'),
        false,
      );
      expect(fake.authorization!.queryParameters['ext_agent_host_id'], host);
    },
  );

  test('consent is requested explicitly, never on ordinary sign-in', () async {
    final profile = await fake.auth.signIn();
    await fake.auth.signIn(clientId: profile.clientId, requestConsent: true);
    expect(fake.authorization!.queryParameters['prompt'], 'consent');
    expect(fake.authorization!.queryParameters['scope'], contains(planScope));
  });

  test(
    'callback rejects wrong, absent and duplicated state and mismatched client',
    () {
      final attempt = AuthorizationAttempt(
        redirectUri: Uri.parse('http://127.0.0.1:1/auth/callback'),
        clientId: 'oaiapp_saved',
      );
      for (final query in [
        'code=c',
        'state=wrong&code=c',
        'state=${attempt.state}&state=${attempt.state}&code=c',
      ]) {
        expect(
          () => attempt.readCallback(Uri.parse('/auth/callback?$query')),
          throwsA(code('invalid_state')),
        );
      }
      expect(
        () => attempt.readCallback(
          Uri(
            path: '/auth/callback',
            queryParameters: {
              'state': attempt.state,
              'code': 'c',
              'client_id': 'oaiapp_other',
            },
          ),
        ),
        throwsA(code('invalid_callback')),
      );
      expect(
        () => attempt.readCallback(
          Uri.parse('/auth/callback?state=${attempt.state}&code=a&code=b'),
        ),
        throwsA(code('invalid_callback')),
      );
    },
  );

  test(
    'loopback rejects invalid state/path/method without consuming valid callback',
    () async {
      fake.sendCallback = false;
      final result = fake.auth.signIn();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return fake.authorization == null;
      });
      final state = fake.authorization!.queryParameters['state']!;
      expect(await fake.callback({'state': 'wrong'}), 400);
      expect(await fake.callback({'state': state}, path: '/other'), 404);
      expect(await fake.callback({'state': state}, method: 'POST'), 404);
      expect(fake.tokenForms, isEmpty);
      expect(
        await fake.callback({
          'state': state,
          'code': 'c',
          'client_id': fake.issuedClient,
        }),
        200,
      );
      expect((await result).signedIn, true);
    },
  );

  test('declining authorization never exchanges a code', () async {
    fake.callbackError = 'access_denied';
    await expectLater(fake.auth.signIn(), throwsA(code('access_denied')));
    expect(fake.tokenForms, isEmpty);
    expect(fake.auth.activeProfile, isNull);
  });

  test('cancel closes the listener and does not activate an account', () async {
    fake.sendCallback = false;
    final signIn = fake.auth.signIn();
    final assertion = expectLater(signIn, throwsA(code('cancelled')));
    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return fake.authorization == null;
    });
    await fake.auth.cancelSignIn();
    await assertion;
    expect(fake.tokenForms, isEmpty);
    expect(fake.auth.activeProfile, isNull);
  });

  test(
    'immediate cancellation stops a queued sign-in before opening a browser',
    () async {
      final result = fake.auth.signIn();
      final assertion = expectLater(result, throwsA(code('cancelled')));
      await fake.auth.cancelSignIn();
      await assertion;
      expect(fake.authorizations, isEmpty);
      expect(fake.auth.activeProfile, isNull);
    },
  );

  test(
    'missing plan grant preserves sign-in and prohibits inference',
    () async {
      fake.grantedScope = 'openid profile email';
      final profile = await fake.auth.signIn();
      expect(profile.signedIn, true);
      expect(profile.planEnabled, false);
      await expectLater(
        fake.auth.accessToken(profile.clientId),
        throwsA(code('plan_not_authorized')),
      );
      expect(fake.refreshCount, 0);
    },
  );

  test(
    'same-email registrations remain separate; failed sign-in keeps old active account',
    () async {
      final first = await fake.auth.signIn();
      fake.issuedClient = 'oaiapp_test_2';
      fake.subject = 'subject_2';
      final second = await fake.auth.signIn();
      expect(fake.auth.profiles.length, 2);
      expect(first.email, second.email);
      await fake.auth.selectProfile(first.clientId);
      fake.issuedClient = 'oaiapp_test_3';
      fake.claimOverrides = {'nonce': 'wrong'};
      await expectLater(fake.auth.signIn(), throwsA(code('invalid_id_token')));
      expect(fake.auth.activeProfile!.clientId, first.clientId);
      expect(fake.auth.profiles.length, 2);
    },
  );

  test('returning sign-in rejects a different verified subject', () async {
    final profile = await fake.auth.signIn();
    fake.subject = 'different-subject';
    await expectLater(
      fake.auth.signIn(clientId: profile.clientId),
      throwsA(code('account_mismatch')),
    );
    expect(fake.auth.activeProfile!.subject, profile.subject);
  });

  test(
    'concurrent expired-token requests perform one refresh and commit rotation',
    () async {
      final profile = await fake.auth.signIn();
      fake.now = fake.now.add(const Duration(hours: 2));
      final tokens = await Future.wait(
        List.generate(5, (_) => fake.auth.accessToken(profile.clientId)),
      );
      expect(tokens, everyElement('rotated-access'));
      expect(fake.refreshCount, 1);
      expect(fake.store.value, contains('rotated-refresh'));
      expect(fake.store.value, isNot(contains('synthetic-refresh')));
      final form = fake.tokenForms.last;
      expect(form['client_id'], profile.clientId);
      expect(form['resource'], openAiResource);
      expect(form.containsKey('scope'), false);
    },
  );

  test(
    'terminal refresh error clears tokens but retains registration and host',
    () async {
      final profile = await fake.auth.signIn();
      final host = jsonDecode(fake.store.value!)['host_id'];
      fake.now = fake.now.add(const Duration(hours: 2));
      fake.refreshError = 'invalid_grant';
      await expectLater(
        fake.auth.accessToken(profile.clientId),
        throwsA(code('sign_in_required')),
      );
      expect(fake.auth.activeProfile!.signedIn, false);
      expect(fake.auth.activeProfile!.clientId, profile.clientId);
      expect(jsonDecode(fake.store.value!)['host_id'], host);
      expect(fake.store.value, isNot(contains('synthetic-refresh')));
    },
  );

  test('temporary refresh failure preserves credentials', () async {
    final profile = await fake.auth.signIn();
    final previous = fake.store.value;
    fake.now = fake.now.add(const Duration(hours: 2));
    fake.refreshError = 'temporarily_unavailable';
    fake.refreshStatus = 503;
    await expectLater(
      fake.auth.accessToken(profile.clientId),
      throwsA(code('temporarily_unavailable')),
    );
    expect(fake.store.value, previous);
    expect(fake.auth.activeProfile!.signedIn, true);
  });

  test('sign-out clears all tokens even if remote revocation fails', () async {
    final profile = await fake.auth.signIn();
    fake.revokeStatus = 503;
    expect(await fake.auth.signOut(profile.clientId), false);
    expect(fake.revokeCount, 2);
    expect(fake.auth.activeProfile!.signedIn, false);
    expect(fake.store.value, isNot(contains('synthetic-access')));
    expect(fake.store.value, isNot(contains('synthetic-refresh')));
    expect(fake.store.value, contains(profile.clientId));
  });

  test(
    'corrupt secure vault fails closed without overwriting saved data',
    () async {
      fake.store.value = 'damaged';
      await expectLater(
        fake.auth.initialize(),
        throwsA(code('vault_unavailable')),
      );
      expect(fake.store.value, 'damaged');
    },
  );

  test('failed secure write never activates the new account', () async {
    final first = await fake.auth.signIn();
    fake.store.failWrites = true;
    fake.issuedClient = 'oaiapp_second';
    await expectLater(fake.auth.signIn(), throwsA(code('vault_unavailable')));
    expect(fake.auth.activeProfile!.clientId, first.clientId);
  });

  group('cryptographic ID token verification', () {
    for (final entry in <String, Map<String, dynamic>>{
      'wrong issuer': {'iss': 'https://example.test'},
      'wrong audience': {'aud': 'other-client'},
      'expired': {'exp': 1},
      'missing expiration': {'exp': null},
      'future issued-at': {'iat': 9999999999},
      'missing subject': {'sub': ''},
      'wrong nonce': {'nonce': 'other-nonce'},
      'multiple audiences without authorized party': {
        'aud': ['oaiapp_test_1', 'other'],
      },
    }.entries) {
      test('rejects ${entry.key}', () async {
        final verifier = OpenAiIdentityVerifier(
          MockClient(fake.handle),
          now: () => fake.now,
        );
        await expectLater(
          verifier.verify(
            fake.idToken(nonce: 'n', overrides: entry.value),
            clientId: fake.issuedClient,
            jwksUri: Uri.parse('$openAiIssuer/.well-known/jwks.json'),
            expectedNonce: 'n',
          ),
          throwsA(code('invalid_id_token')),
        );
      });
    }

    test('rejects a tampered signature and unsigned token', () async {
      final verifier = OpenAiIdentityVerifier(
        MockClient(fake.handle),
        now: () => fake.now,
      );
      final parts = fake.idToken(nonce: 'n').split('.');
      final signature = base64Url.decode(base64Url.normalize(parts[2]));
      signature[0] ^= 1;
      parts[2] = base64Url.encode(signature).replaceAll('=', '');
      await expectLater(
        verifier.verify(
          parts.join('.'),
          clientId: fake.issuedClient,
          jwksUri: Uri.parse('$openAiIssuer/.well-known/jwks.json'),
          expectedNonce: 'n',
        ),
        throwsA(code('invalid_id_token')),
      );
      parts[0] = base64Url
          .encode(utf8.encode('{"alg":"none","kid":"test-key"}'))
          .replaceAll('=', '');
      await expectLater(
        verifier.verify(
          parts.join('.'),
          clientId: fake.issuedClient,
          jwksUri: Uri.parse('$openAiIssuer/.well-known/jwks.json'),
          expectedNonce: 'n',
        ),
        throwsA(code('invalid_id_token')),
      );
    });
  });
}
