import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';
import 'types.dart';

class OpenAiDiscovery {
  OpenAiDiscovery(Map<String, dynamic> json)
    : authorizationEndpoint = _endpoint(json['authorization_endpoint']),
      tokenEndpoint = _endpoint(json['token_endpoint']),
      jwksUri = _endpoint(json['jwks_uri']),
      revocationEndpoint = json['revocation_endpoint'] == null
          ? null
          : _endpoint(json['revocation_endpoint']) {
    if (json['issuer'] != openAiIssuer) {
      throw const ChatGptException(
        'invalid_issuer',
        'Unexpected OpenAI issuer.',
      );
    }
  }
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri jwksUri;
  final Uri? revocationEndpoint;

  static Uri _endpoint(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'auth.openai.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.hasQuery) {
      throw const ChatGptException(
        'invalid_endpoint',
        'Unexpected OpenAI endpoint.',
      );
    }
    return uri;
  }
}

class VerifiedIdentity {
  const VerifiedIdentity({required this.subject, this.email, this.name});
  final String subject;
  final String? email;
  final String? name;
}

/// Only asymmetric signatures from the pinned issuer's JWKS are accepted.
/// A token's jku/x5u is never followed. Unknown kids trigger one JWKS refresh.
class OpenAiIdentityVerifier {
  OpenAiIdentityVerifier(this.client, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final http.Client client;
  final DateTime Function() _now;
  List<Map<String, dynamic>> _keys = [];
  DateTime? _keysFetched;

  Future<VerifiedIdentity> verify(
    String encoded, {
    required String clientId,
    required Uri jwksUri,
    String? expectedNonce,
  }) async {
    try {
      final jws = JsonWebSignature.fromCompactSerialization(encoded);
      final header = jws.unverifiedPayload.protectedHeader;
      if (header == null) throw const FormatException();
      final algorithm = header['alg'];
      final kid = header['kid'];
      if (!['RS256', 'ES256'].contains(algorithm) ||
          kid is! String ||
          kid.isEmpty) {
        throw const FormatException();
      }
      if (_keysFetched == null ||
          _now().difference(_keysFetched!) > const Duration(hours: 1)) {
        await _loadKeys(jwksUri);
      }
      var key = _findKey(kid, algorithm as String);
      if (key == null) {
        await _loadKeys(jwksUri);
        key = _findKey(kid, algorithm);
      }
      if (key == null) throw const FormatException();
      final keyStore = JsonWebKeyStore()..addKey(JsonWebKey.fromJson(key));
      if (!await jws.verify(keyStore)) throw const FormatException();
      final claims = jws.unverifiedPayload.jsonContent as Map<String, dynamic>;
      final audience = claims['aud'];
      final audiences = audience is String ? [audience] : audience;
      final exp = claims['exp'];
      final iat = claims['iat'];
      final nbf = claims['nbf'];
      final seconds = _now().toUtc().millisecondsSinceEpoch / 1000;
      if (claims['iss'] != openAiIssuer ||
          audiences is! List ||
          !audiences.contains(clientId) ||
          (audiences.length > 1 && claims['azp'] != clientId) ||
          (claims['azp'] != null && claims['azp'] != clientId) ||
          exp is! num ||
          !exp.isFinite ||
          exp <= seconds - 5 ||
          iat is! num ||
          !iat.isFinite ||
          iat > seconds + 5 ||
          (nbf != null &&
              (nbf is! num || !nbf.isFinite || nbf > seconds + 5)) ||
          claims['sub'] is! String ||
          (claims['sub'] as String).isEmpty ||
          (expectedNonce != null && claims['nonce'] != expectedNonce)) {
        throw const FormatException();
      }
      return VerifiedIdentity(
        subject: claims['sub'] as String,
        email: claims['email'] is String ? claims['email'] as String : null,
        name: claims['name'] is String ? claims['name'] as String : null,
      );
    } on ChatGptException {
      rethrow;
    } catch (_) {
      throw const ChatGptException(
        'invalid_id_token',
        'The OpenAI identity token could not be verified.',
      );
    }
  }

  Map<String, dynamic>? _findKey(String kid, String algorithm) {
    for (final key in _keys) {
      if (key['kid'] == kid &&
          (key['use'] == null || key['use'] == 'sig') &&
          (key['alg'] == null || key['alg'] == algorithm) &&
          (algorithm == 'RS256' ? key['kty'] == 'RSA' : key['kty'] == 'EC')) {
        return key;
      }
    }
    return null;
  }

  Future<void> _loadKeys(Uri uri) async {
    final response = await sendRequest(client, http.Request('GET', uri));
    final json = readJson(response);
    if (json['keys'] is! List) {
      throw const ChatGptException(
        'invalid_jwks',
        'OpenAI signing keys are unavailable.',
      );
    }
    _keys = (json['keys'] as List)
        .map((k) => Map<String, dynamic>.from(k as Map))
        .toList();
    _keysFetched = _now();
  }
}

Future<http.Response> sendRequest(
  http.Client client,
  http.Request request,
) async {
  request.followRedirects = false;
  try {
    return await client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 20));
  } on ChatGptException {
    rethrow;
  } catch (_) {
    throw const ChatGptException(
      'network_error',
      'Could not connect to OpenAI. Try again.',
    );
  }
}

Map<String, dynamic> readJson(http.Response response) {
  Object? value;
  try {
    value = jsonDecode(response.body);
  } catch (_) {
    /* non-JSON admission error */
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw responseError(
      response.statusCode,
      value,
      response.headers['openai-request-id'] ?? response.headers['x-request-id'],
    );
  }
  if (value is! Map<String, dynamic>) {
    throw const ChatGptException(
      'invalid_response',
      'Unexpected OpenAI response.',
    );
  }
  return value;
}
