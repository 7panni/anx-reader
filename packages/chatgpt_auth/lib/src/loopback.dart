import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'types.dart';

String randomOAuthValue([int bytes = 32]) => base64Url
    .encode(List<int>.generate(bytes, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

String pkceChallenge(String verifier) => base64Url
    .encode(sha256.convert(ascii.encode(verifier)).bytes)
    .replaceAll('=', '');

bool _equal(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

class AuthorizationAttempt {
  AuthorizationAttempt({
    required this.redirectUri,
    this.clientId = dynamicClientId,
  })  : state = randomOAuthValue(),
        nonce = randomOAuthValue(),
        verifier = randomOAuthValue(64);
  final Uri redirectUri;
  final String clientId;
  final String state;
  final String nonce;
  final String verifier;

  Uri authorizationUri({
    required Uri endpoint,
    required String hostId,
    required String appName,
    String? idTokenHint,
    String? loginHint,
    bool requestConsent = false,
  }) =>
      endpoint.replace(
        queryParameters: {
          'client_id': clientId,
          if (clientId == dynamicClientId) 'agent_name_hint': appName,
          'ext_agent_host_id': hostId,
          'response_type': 'code',
          'redirect_uri': redirectUri.toString(),
          'scope': requestedScopes.join(' '),
          'resource': openAiResource,
          'state': state,
          'nonce': nonce,
          'code_challenge_method': 'S256',
          'code_challenge': pkceChallenge(verifier),
          if (idTokenHint != null) 'id_token_hint': idTokenHint,
          if (loginHint != null) 'login_hint': loginHint,
          if (requestConsent) 'prompt': 'consent',
        },
      );

  void validateState(Uri callback) {
    final states = callback.queryParametersAll['state'];
    if (states == null || states.length != 1 || !_equal(states.single, state)) {
      throw const ChatGptException(
        'invalid_state',
        'Sign-in could not be verified.',
      );
    }
    for (final key in ['code', 'error', 'client_id']) {
      if ((callback.queryParametersAll[key]?.length ?? 0) > 1) {
        throw const ChatGptException(
          'invalid_callback',
          'Ambiguous sign-in callback.',
        );
      }
    }
  }

  ({String code, String clientId}) readCallback(Uri callback) {
    validateState(callback);
    final query = callback.queryParameters;
    if (query.containsKey('error')) {
      throw const ChatGptException(
        'access_denied',
        'Sign-in was cancelled or declined.',
      );
    }
    final code = query['code'];
    final issuedId = query['client_id'];
    if (code == null ||
        code.isEmpty ||
        (clientId == dynamicClientId &&
            (issuedId == null ||
                issuedId.isEmpty ||
                issuedId == dynamicClientId)) ||
        (clientId != dynamicClientId &&
            issuedId != null &&
            issuedId != clientId)) {
      throw const ChatGptException(
        'invalid_callback',
        'Incomplete or mismatched registration.',
      );
    }
    return (code: code, clientId: issuedId ?? clientId);
  }
}

/// Identical loopback protocol on macOS, Windows and Linux. No custom scheme,
/// LAN listener, embedded browser, clipboard token, or fixed occupied port.
class LoopbackCallback {
  LoopbackCallback._(this._server);
  final HttpServer _server;
  final _result = Completer<Uri>();
  bool _consumed = false;
  static Future<LoopbackCallback> bind() async => LoopbackCallback._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false),
      );
  Uri get redirectUri =>
      Uri.parse('http://127.0.0.1:${_server.port}/auth/callback');

  Future<Uri> receive(
    AuthorizationAttempt attempt, {
    Duration timeout = const Duration(minutes: 3),
  }) {
    _server.listen(
      (request) async {
        request.response.headers
          ..contentType = ContentType.html
          ..set('Cache-Control', 'no-store')
          ..set(
            'Content-Security-Policy',
            "default-src 'none'; frame-ancestors 'none'",
          )
          ..set('Referrer-Policy', 'no-referrer');
        if (request.method != 'GET' ||
            request.uri.path != '/auth/callback' ||
            request.headers.value(HttpHeaders.hostHeader) !=
                redirectUri.authority ||
            _consumed) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          try {
            attempt.validateState(request.uri);
            _consumed = true;
            request.response.write(
              '<!doctype html><meta charset="utf-8">'
              '<title>Anx Reader</title><p>Authorization received. '
              'Return to Anx Reader to see the sign-in result.</p>',
            );
            if (!_result.isCompleted) _result.complete(request.uri);
          } on ChatGptException {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write('Invalid sign-in callback.');
          }
        }
        await request.response.close();
      },
      onError: (Object _) {
        if (!_result.isCompleted)
          _result.completeError(
            const ChatGptException(
              'callback_failed',
              'The sign-in callback failed.',
            ),
          );
      },
    );
    return _result.future.timeout(
      timeout,
      onTimeout: () => throw const ChatGptException(
        'sign_in_timeout',
        'Sign-in timed out. Try again.',
      ),
    );
  }

  Future<void> close() async {
    if (!_result.isCompleted)
      _result.completeError(
        const ChatGptException('cancelled', 'Sign-in was cancelled.'),
      );
    await _server.close(force: true);
  }
}
