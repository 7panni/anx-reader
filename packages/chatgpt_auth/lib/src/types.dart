/// Implement with the OS credential vault. Never put this value in preferences,
/// WebDAV backups, diagnostics, browser storage, or an exported AI configuration.
abstract interface class CredentialStore {
  Future<String?> read();
  Future<void> write(String value);
}

typedef OpenBrowser = Future<bool> Function(Uri authorizationUri);

const openAiIssuer = 'https://auth.openai.com';
const openAiResource = 'https://api.openai.com/v1';
const dynamicClientId = 'dynamic_agent_client';
const planScope = 'chatgpt.tokens.use.direct';
const requestedScopes = [
  'openid',
  'profile',
  'email',
  'offline_access',
  'resource.invoke',
  planScope,
];

/// Safe to display. Tokens are deliberately absent from the UI model.
class ChatGptProfile {
  const ChatGptProfile({
    required this.clientId,
    required this.subject,
    required this.issuer,
    required this.signedIn,
    required this.planEnabled,
    required this.welcomeSeen,
    this.email,
    this.name,
  });
  final String clientId;
  final String subject;
  final String issuer;
  final String? email;
  final String? name;
  final bool signedIn;
  final bool planEnabled;
  final bool welcomeSeen;
  String get displayName => email ?? name ?? 'ChatGPT';
  String get registrationLabel => clientId.length > 12
      ? clientId.substring(clientId.length - 12)
      : clientId;
}

class ChatGptException implements Exception {
  const ChatGptException(
    this.code,
    this.message, {
    this.status,
    this.requestId,
  });
  final String code;
  final String message;
  final int? status;
  final String? requestId;

  // Never include HTTP bodies, tokens, callback URLs, or authorization URLs.
  @override
  String toString() =>
      '$message ($code${status == null ? '' : ', HTTP $status'})';
}

/// Remote error text is untrusted and can echo credentials. Keep only bounded
/// machine identifiers, HTTP status, and request ID in diagnostic exceptions.
ChatGptException responseError(int status, Object? body, String? requestId) {
  String code = 'http_error';
  if (body is Map && body['error'] is Map) {
    final error = body['error'] as Map;
    final value = error['code'] ?? error['type'];
    if (value is String && RegExp(r'^[a-zA-Z0-9_.-]{1,100}$').hasMatch(value)) {
      code = value;
    }
  } else if (body is Map && body['error'] is String) {
    final value = body['error'] as String;
    if (RegExp(r'^[a-zA-Z0-9_.-]{1,100}$').hasMatch(value)) code = value;
  }
  // Some admission failures use an unstructured detail instead of an error
  // code. Classify only fixed parameter names; never echo the remote text.
  if (code == 'http_error' && status == 400 && body is Map) {
    final detail = body['detail'];
    if (detail is String) {
      final lower = detail.toLowerCase();
      for (final term in [
        'strict',
        'schema',
        'tools',
        'instructions',
        'system',
        'role',
        'input',
        'reasoning',
        'model',
        'stream',
        'store',
      ]) {
        if (lower.contains(term)) {
          code = 'request_rejected_$term';
          break;
        }
      }
    }
  }
  final safeId =
      requestId != null && RegExp(r'^[a-zA-Z0-9_-]{1,200}$').hasMatch(requestId)
          ? requestId
          : null;
  return ChatGptException(
    code,
    'OpenAI could not complete the request.',
    status: status,
    requestId: safeId,
  );
}
