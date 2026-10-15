import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'loopback.dart';
import 'oidc.dart';
import 'types.dart';

const _unchanged = Object();

/// One client per running application. All credential mutations and refreshes
/// are serialized. Do not share this installation's vault between processes.
class ChatGptAuthClient {
  ChatGptAuthClient({
    required this.store,
    required this.openBrowser,
    this.appName = 'Anx Reader',
    http.Client? httpClient,
    DateTime Function()? now,
    this.signInTimeout = const Duration(minutes: 3),
  })  : _http = httpClient ?? http.Client(),
        _now = now ?? DateTime.now {
    _verifier = OpenAiIdentityVerifier(_http, now: _now);
  }
  final CredentialStore store;
  final OpenBrowser openBrowser;
  final String appName;
  final Duration signInTimeout;
  final http.Client _http;
  final DateTime Function() _now;
  late final OpenAiIdentityVerifier _verifier;
  _Vault? _vault;
  OpenAiDiscovery? _discovery;
  Future<void> _operations = Future.value();
  LoopbackCallback? _callback;
  int _signInGeneration = 0;

  List<ChatGptProfile> get profiles => List.unmodifiable(
        _vault?.records.values.map((r) => r.profile) ?? <ChatGptProfile>[],
      );
  ChatGptProfile? get activeProfile =>
      _vault?.records[_vault?.activeClientId]?.profile;

  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _operations = _operations.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> initialize() => _exclusive(_load);
  Future<void> _load() async {
    if (_vault != null) return;
    try {
      final value = await store.read();
      if (value != null) {
        _vault = _Vault.fromJson(jsonDecode(value) as Map<String, dynamic>);
      } else {
        await _commit(
          _Vault(hostId: 'urn:uuid:${const Uuid().v4()}', records: {}),
        );
      }
    } on ChatGptException {
      rethrow;
    } catch (_) {
      throw const ChatGptException(
        'vault_unavailable',
        'Secure storage could not be read. Unlock the system credential vault and try again.',
      );
    }
  }

  Future<void> _commit(_Vault value) async {
    try {
      await store.write(jsonEncode(value.toJson()));
    } catch (_) {
      throw const ChatGptException(
        'vault_unavailable',
        'Credentials could not be saved securely.',
      );
    }
    _vault = value;
  }

  Future<OpenAiDiscovery> _configuration() async {
    if (_discovery != null) return _discovery!;
    final response = await sendRequest(
      _http,
      http.Request(
        'GET',
        Uri.parse('$openAiIssuer/.well-known/openid-configuration'),
      ),
    );
    return _discovery = OpenAiDiscovery(readJson(response));
  }

  Future<ChatGptProfile> signIn({
    String? clientId,
    bool requestConsent = false,
  }) {
    final generation = _signInGeneration;
    return _exclusive(() async {
      await _load();
      _checkSignIn(generation);
      final existing = clientId == null ? null : _vault!.records[clientId];
      if (clientId != null && existing == null) {
        throw const ChatGptException(
          'unknown_account',
          'Select a saved ChatGPT account.',
        );
      }
      final configuration = await _configuration();
      _checkSignIn(generation);
      final callback = await LoopbackCallback.bind();
      _callback = callback;
      final attempt = AuthorizationAttempt(
        redirectUri: callback.redirectUri,
        clientId:
            existing?.clientId ?? _vault!.pendingClientId ?? dynamicClientId,
      );
      final callbackFuture = callback.receive(attempt, timeout: signInTimeout);
      // The callback can be cancelled while the OS is still opening the browser.
      unawaited(callbackFuture.then<void>((_) {}, onError: (Object _) {}));
      try {
        _checkSignIn(generation);
        final opened = await openBrowser(
          attempt.authorizationUri(
            endpoint: configuration.authorizationEndpoint,
            hostId: _vault!.hostId,
            appName: appName,
            idTokenHint: existing?.tokens['id_token'] as String?,
            loginHint: existing?.email,
            requestConsent: requestConsent,
          ),
        );
        if (!opened)
          throw const ChatGptException(
            'browser_unavailable',
            'The system browser could not be opened.',
          );
        final result = attempt.readCallback(await callbackFuture);
        _checkSignIn(generation);
        if (existing == null) {
          // Retain an issued registration after a failed exchange (invalid_grant),
          // but never make it an account or active session before ID verification.
          await _commit(_vault!.copyWith(pendingClientId: result.clientId));
        }
        final tokenResponse = await _token(configuration.tokenEndpoint, {
          'grant_type': 'authorization_code',
          'client_id': result.clientId,
          'code': result.code,
          'code_verifier': attempt.verifier,
          'redirect_uri': attempt.redirectUri.toString(),
          'resource': openAiResource,
        });
        final idToken = tokenResponse['id_token'];
        if (idToken is! String || idToken.isEmpty) {
          throw const ChatGptException(
            'invalid_id_token',
            'The sign-in response has no identity token.',
          );
        }
        final identity = await _verifier.verify(
          idToken,
          clientId: result.clientId,
          jwksUri: configuration.jwksUri,
          expectedNonce: attempt.nonce,
        );
        _checkSignIn(generation);
        if (existing != null && existing.subject != identity.subject) {
          throw const ChatGptException(
            'account_mismatch',
            'The returned ChatGPT account does not match the selected account.',
          );
        }
        final record = _Record(
          clientId: result.clientId,
          subject: identity.subject,
          email: identity.email,
          name: identity.name,
          tokens: _validatedTokens(tokenResponse),
          scopes: _scopes(tokenResponse['scope']),
          expiresAt: _expiry(tokenResponse),
          welcomeSeen: existing?.welcomeSeen ?? false,
        );
        await _commit(
          _vault!.copyWith(
            records: {..._vault!.records, record.clientId: record},
            activeClientId: record.clientId,
            pendingClientId: existing == null ? null : _vault!.pendingClientId,
          ),
        );
        return record.profile;
      } finally {
        _callback = null;
        await callback.close();
      }
    });
  }

  void _checkSignIn(int generation) {
    if (generation != _signInGeneration) {
      throw const ChatGptException('cancelled', 'Sign-in was cancelled.');
    }
  }

  Future<void> cancelSignIn() async {
    _signInGeneration++;
    await _callback?.close();
  }

  Future<void> selectProfile(String clientId) => _exclusive(() async {
        await _load();
        if (!_vault!.records.containsKey(clientId)) {
          throw const ChatGptException(
            'unknown_account',
            'Select a saved ChatGPT account.',
          );
        }
        await _commit(_vault!.copyWith(activeClientId: clientId));
      });

  Future<void> markWelcomeSeen(String clientId) => _exclusive(() async {
        await _load();
        final record = _vault!.records[clientId];
        if (record == null) return;
        await _commit(
          _vault!.copyWith(
            records: {
              ..._vault!.records,
              clientId: record.copyWith(welcomeSeen: true),
            },
          ),
        );
      });

  /// A request remains bound to the account it started with. Account switching
  /// must cancel callers' active streams before selecting the next profile.
  Future<String> accessToken(String clientId) => _exclusive(() async {
        await _load();
        var record = _vault!.records[clientId];
        if (record == null || _vault!.activeClientId != clientId) {
          throw const ChatGptException(
            'account_changed',
            'The active ChatGPT account changed.',
          );
        }
        if (!record.profile.planEnabled) {
          throw const ChatGptException(
            'plan_not_authorized',
            'Enable ChatGPT plan usage for this account.',
          );
        }
        if (record.expiresAt != null &&
            record.expiresAt!.isAfter(
              _now().toUtc().add(const Duration(seconds: 60)),
            )) {
          return record.tokens['access_token'] as String;
        }
        final refreshToken = record.tokens['refresh_token'];
        if (refreshToken is! String || refreshToken.isEmpty) {
          throw const ChatGptException(
            'sign_in_required',
            'Sign in to ChatGPT again.',
          );
        }
        try {
          final configuration = await _configuration();
          final response = await _token(configuration.tokenEndpoint, {
            'grant_type': 'refresh_token',
            'client_id': record.clientId,
            'refresh_token': refreshToken,
            'resource': openAiResource,
          });
          if (response['access_token'] is! String ||
              (response['access_token'] as String).isEmpty) {
            throw const ChatGptException(
              'invalid_token_response',
              'OpenAI returned no access token.',
            );
          }
          final idToken = response['id_token'];
          if (idToken != null) {
            final identity = await _verifier.verify(
              idToken as String,
              clientId: record.clientId,
              jwksUri: configuration.jwksUri,
            );
            if (identity.subject != record.subject) {
              throw const ChatGptException(
                'account_mismatch',
                'The refreshed identity does not match the selected account.',
              );
            }
          }
          record = record.copyWith(
            tokens: {...record.tokens, ..._validatedTokens(response)},
            scopes: response.containsKey('scope')
                ? _scopes(response['scope'])
                : record.scopes,
            expiresAt: _expiry(response),
          );
          // Rotating access/refresh/ID tokens and scopes are committed as one item.
          await _commit(
            _vault!.copyWith(records: {..._vault!.records, clientId: record}),
          );
          if (!record.profile.planEnabled) {
            throw const ChatGptException(
              'plan_not_authorized',
              'ChatGPT plan permission is no longer enabled.',
            );
          }
          return record.tokens['access_token'] as String;
        } on ChatGptException catch (error) {
          if (const {
            'invalid_grant',
            'invalid_refresh_token',
            'token_expired',
            'refresh_token_expired',
            'refresh_token_invalidated',
            'refresh_token_reused',
          }.contains(error.code)) {
            await _commit(
              _vault!.copyWith(
                records: {
                  ..._vault!.records,
                  clientId: record!.withoutTokens()
                },
              ),
            );
            throw const ChatGptException(
              'sign_in_required',
              'The session has ended. Sign in to ChatGPT again.',
            );
          }
          rethrow;
        }
      });

  /// Returns whether remote revocation was confirmed. Local credentials are
  /// cleared in either case, retaining the host and verified account mapping.
  Future<bool> signOut(String clientId) => _exclusive(() async {
        await _load();
        final record = _vault!.records[clientId];
        if (record == null) return true;
        var revoked = record.tokens['refresh_token'] == null;
        try {
          final refreshToken = record.tokens['refresh_token'];
          if (refreshToken is String) {
            final endpoint = (await _configuration()).revocationEndpoint;
            if (endpoint != null) {
              for (var attempt = 0; attempt < 2; attempt++) {
                try {
                  final request = http.Request('POST', endpoint)
                    ..bodyFields = {
                      'token': refreshToken,
                      'token_type_hint': 'refresh_token',
                      'client_id': record.clientId,
                    };
                  final response = await sendRequest(_http, request);
                  if (response.statusCode == 200) {
                    revoked = true;
                    break;
                  }
                  if (response.statusCode < 500) break;
                } on ChatGptException {
                  /* one bounded network retry */
                }
                if (attempt == 0)
                  await Future<void>.delayed(const Duration(milliseconds: 300));
              }
            }
          }
        } on ChatGptException {
          /* local sign-out must still complete */
        } finally {
          await _commit(
            _vault!.copyWith(
              records: {..._vault!.records, clientId: record.withoutTokens()},
            ),
          );
        }
        return revoked;
      });

  Future<Map<String, dynamic>> _token(
    Uri endpoint,
    Map<String, String> fields,
  ) async =>
      readJson(
        await sendRequest(
          _http,
          http.Request('POST', endpoint)..bodyFields = fields,
        ),
      );

  Map<String, dynamic> _validatedTokens(Map<String, dynamic> json) {
    final result = <String, dynamic>{};
    for (final key in ['access_token', 'refresh_token', 'id_token']) {
      final value = json[key];
      if (value != null) {
        if (value is! String || value.isEmpty) {
          throw const ChatGptException(
            'invalid_token_response',
            'Unexpected token response.',
          );
        }
        result[key] = value;
      }
    }
    if (result.containsKey('access_token') &&
        (json['token_type'] is! String ||
            (json['token_type'] as String).toLowerCase() != 'bearer')) {
      throw const ChatGptException(
        'invalid_token_response',
        'Unsupported token type.',
      );
    }
    return result;
  }

  DateTime? _expiry(Map<String, dynamic> json) {
    if (json['access_token'] == null) return null;
    final seconds = json['expires_in'];
    if (seconds is! num ||
        !seconds.isFinite ||
        seconds <= 0 ||
        seconds > 31536000) {
      throw const ChatGptException(
        'invalid_token_response',
        'Missing or invalid token expiry.',
      );
    }
    return _now().toUtc().add(Duration(seconds: seconds.toInt()));
  }

  List<String> _scopes(Object? value) => value is String
      ? value.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList()
      : [];

  Future<void> close() async {
    await cancelSignIn();
    await _operations;
    _http.close();
  }
}

class _Vault {
  _Vault({
    required this.hostId,
    required this.records,
    this.activeClientId,
    this.pendingClientId,
  });
  final String hostId;
  final Map<String, _Record> records;
  final String? activeClientId;
  final String? pendingClientId;
  factory _Vault.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['host_id'] is! String ||
        !RegExp(
          r'^urn:uuid:[0-9a-fA-F-]{36}$',
        ).hasMatch(json['host_id'] as String)) {
      throw const FormatException('Unsupported credential record.');
    }
    final records = (json['accounts'] as List).map(
      (v) => _Record.fromJson(v as Map<String, dynamic>),
    );
    final byId = {for (final record in records) record.clientId: record};
    final selected = json['active_client_id'] as String?;
    if (selected != null && !byId.containsKey(selected))
      throw const FormatException();
    return _Vault(
      hostId: json['host_id'] as String,
      records: byId,
      activeClientId: selected,
      pendingClientId: json['pending_client_id'] as String?,
    );
  }
  _Vault copyWith({
    Map<String, _Record>? records,
    Object? activeClientId = _unchanged,
    Object? pendingClientId = _unchanged,
  }) =>
      _Vault(
        hostId: hostId,
        records: records ?? this.records,
        activeClientId: identical(activeClientId, _unchanged)
            ? this.activeClientId
            : activeClientId as String?,
        pendingClientId: identical(pendingClientId, _unchanged)
            ? this.pendingClientId
            : pendingClientId as String?,
      );
  Map<String, dynamic> toJson() => {
        'version': 1,
        'host_id': hostId,
        'active_client_id': activeClientId,
        'pending_client_id': pendingClientId,
        'accounts': records.values.map((r) => r.toJson()).toList(),
      };
}

class _Record {
  _Record({
    required this.clientId,
    required this.subject,
    required this.tokens,
    required this.scopes,
    this.email,
    this.name,
    this.expiresAt,
    this.welcomeSeen = false,
  });
  final String clientId;
  final String subject;
  final String? email;
  final String? name;
  final Map<String, dynamic> tokens;
  final List<String> scopes;
  final DateTime? expiresAt;
  final bool welcomeSeen;
  ChatGptProfile get profile => ChatGptProfile(
        clientId: clientId,
        subject: subject,
        issuer: openAiIssuer,
        email: email,
        name: name,
        signedIn: tokens.isNotEmpty,
        planEnabled: scopes.contains(planScope) &&
            scopes.contains('resource.invoke') &&
            tokens['access_token'] is String,
        welcomeSeen: welcomeSeen,
      );
  _Record withoutTokens() => _Record(
        clientId: clientId,
        subject: subject,
        email: email,
        name: name,
        tokens: {},
        scopes: [],
        welcomeSeen: welcomeSeen,
      );
  _Record copyWith({
    Map<String, dynamic>? tokens,
    List<String>? scopes,
    DateTime? expiresAt,
    bool? welcomeSeen,
  }) =>
      _Record(
        clientId: clientId,
        subject: subject,
        email: email,
        name: name,
        tokens: tokens ?? this.tokens,
        scopes: scopes ?? this.scopes,
        expiresAt: expiresAt ?? this.expiresAt,
        welcomeSeen: welcomeSeen ?? this.welcomeSeen,
      );
  factory _Record.fromJson(Map<String, dynamic> json) {
    if (json['issuer'] != openAiIssuer ||
        json['client_id'] == dynamicClientId ||
        (json['client_id'] as String).isEmpty ||
        (json['subject'] as String).isEmpty) {
      throw const FormatException();
    }
    return _Record(
      clientId: json['client_id'] as String,
      subject: json['subject'] as String,
      email: json['email'] as String?,
      name: json['name'] as String?,
      tokens: Map<String, dynamic>.from(json['tokens'] as Map),
      scopes: (json['scopes'] as List).cast<String>(),
      expiresAt: json['expires_at'] == null
          ? null
          : DateTime.parse(json['expires_at'] as String),
      welcomeSeen: json['welcome_seen'] == true,
    );
  }
  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        'subject': subject,
        'issuer': openAiIssuer,
        'email': email,
        'name': name,
        'tokens': tokens,
        'scopes': scopes,
        'expires_at': expiresAt?.toUtc().toIso8601String(),
        'welcome_seen': welcomeSeen,
      };
}
