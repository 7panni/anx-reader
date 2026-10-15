import 'dart:convert';
import 'dart:io';
import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jose/jose.dart';

class MemoryStore implements CredentialStore {
  String? value;
  bool failWrites = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    if (failWrites) throw StateError('Locked vault');
    this.value = value;
  }
}

final signingKey = JsonWebKey.fromJson({
  ...JsonWebKey.generate('RS256', keyBitLength: 2048).toJson(),
  'kid': 'test-key',
});
Map<String, dynamic> get publicKey => {
      for (final field in ['kty', 'n', 'e', 'kid'])
        field: signingKey.toJson()[field],
      'alg': 'RS256',
      'use': 'sig',
    };

class FakeOpenAi {
  final store = MemoryStore();
  DateTime now = DateTime.utc(2026, 10, 15, 6);
  Uri? authorization;
  final authorizations = <Uri>[];
  final tokenForms = <Map<String, String>>[];
  String issuedClient = 'oaiapp_test_1';
  String subject = 'subject_1';
  String? grantedScope = requestedScopes.join(' ');
  String? refreshError;
  int refreshStatus = 400;
  int revokeStatus = 200;
  bool omitCallbackClientId = false;
  bool sendCallback = true;
  String? callbackError;
  String? returnedClientId;
  Map<String, dynamic> claimOverrides = {};
  int jwksLoads = 0;
  int refreshCount = 0;
  int revokeCount = 0;
  late final ChatGptAuthClient auth = ChatGptAuthClient(
    store: store,
    openBrowser: open,
    now: () => now,
    httpClient: MockClient(handle),
    signInTimeout: const Duration(seconds: 3),
  );

  String idToken({String? nonce, Map<String, dynamic> overrides = const {}}) {
    final claims = {
      'iss': openAiIssuer,
      'sub': subject,
      'aud': issuedClient,
      'iat': now.millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'nonce': nonce ?? authorization?.queryParameters['nonce'],
      'email': 'same@example.test',
      'name': 'Test reader',
      ...overrides,
    };
    final builder = JsonWebSignatureBuilder()
      ..jsonContent = claims
      ..setProtectedHeader('kid', 'test-key')
      ..addRecipient(signingKey, algorithm: 'RS256');
    return builder.build().toCompactSerialization();
  }

  Future<bool> open(Uri uri) async {
    authorization = uri;
    authorizations.add(uri);
    if (sendCallback) {
      final response = await callback({
        'state': uri.queryParameters['state']!,
        if (callbackError == null) 'code': 'synthetic-code',
        if (callbackError != null) 'error': callbackError!,
        if (!omitCallbackClientId)
          'client_id': returnedClientId ?? issuedClient,
      });
      if (response != 200) throw StateError('Loopback failed: $response');
    }
    return true;
  }

  Future<int> callback(
    Map<String, String> query, {
    String method = 'GET',
    String? path,
  }) async {
    final uri = Uri.parse(
      authorization!.queryParameters['redirect_uri']!,
    ).replace(queryParameters: query, path: path);
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, uri);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path == '/.well-known/openid-configuration') {
      return jsonResponse({
        'issuer': openAiIssuer,
        'authorization_endpoint': '$openAiIssuer/api/accounts/authorize',
        'token_endpoint': '$openAiIssuer/api/accounts/oauth/token',
        'jwks_uri': '$openAiIssuer/.well-known/jwks.json',
        'revocation_endpoint': '$openAiIssuer/oauth/revoke',
      });
    }
    if (request.url.path == '/.well-known/jwks.json') {
      jwksLoads++;
      return jsonResponse({
        'keys': [publicKey],
      });
    }
    if (request.url.path == '/oauth/revoke') {
      revokeCount++;
      return http.Response('', revokeStatus);
    }
    if (request.url.path.endsWith('/oauth/token')) {
      final fields = request.bodyFields;
      tokenForms.add(fields);
      if (fields['grant_type'] == 'refresh_token') {
        refreshCount++;
        if (refreshError != null)
          return jsonResponse({'error': refreshError}, refreshStatus);
        return jsonResponse({
          'access_token': 'rotated-access',
          'refresh_token': 'rotated-refresh',
          'token_type': 'Bearer',
          'expires_in': 3600,
        });
      }
      return jsonResponse({
        'id_token': idToken(overrides: claimOverrides),
        'access_token': 'synthetic-access',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'Bearer',
        'expires_in': 3600,
        if (grantedScope != null) 'scope': grantedScope,
      });
    }
    throw StateError('Unexpected mock endpoint ${request.url.path}');
  }
}

http.Response jsonResponse(Object json, [int status = 200]) => http.Response(
      jsonEncode(json),
      status,
      headers: {'content-type': 'application/json'},
    );
