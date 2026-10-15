import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'auth_client.dart';
import 'oidc.dart';
import 'types.dart';

class ChatGptModel {
  const ChatGptModel({required this.slug, required this.displayName});
  final String slug;
  final String displayName;
}

/// Public Responses API only. Never falls back to an API key, another account,
/// another billing path, or a private ChatGPT backend endpoint.
class ChatGptResponses {
  ChatGptResponses(this.auth, {http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;
  final ChatGptAuthClient auth;
  final http.Client Function() _clientFactory;
  final Set<http.Client> _requests = {};
  int _generation = 0;

  void cancel() {
    _generation++;
    for (final client in _requests.toList()) {
      client.close();
    }
    _requests.clear();
  }

  Future<List<ChatGptModel>> models(String clientId) async {
    final generation = _generation;
    final token = await auth.accessToken(clientId);
    _checkSession(clientId, generation);
    final client = _clientFactory();
    _requests.add(client);
    try {
      final response = await sendRequest(
        client,
        http.Request('GET', Uri.parse('$openAiResource/models'))
          ..headers['Authorization'] = 'Bearer $token',
      );
      _checkSession(clientId, generation);
      final json = readJson(response);
      if (json['models'] is! List) {
        throw const ChatGptException(
          'invalid_model_catalog',
          'Unexpected ChatGPT model catalog.',
        );
      }
      return (json['models'] as List)
          .whereType<Map>()
          .where(
            (m) =>
                m['visibility'] == 'list' &&
                m['slug'] is String &&
                (m['slug'] as String).isNotEmpty &&
                m['display_name'] is String,
          )
          .map(
            (m) => ChatGptModel(
              slug: m['slug'] as String,
              displayName: m['display_name'] as String,
            ),
          )
          .toList();
    } finally {
      _requests.remove(client);
      client.close();
    }
  }

  Stream<String> verifyConnection({
    required String clientId,
    required String model,
  }) =>
      stream(
        clientId: clientId,
        model: model,
        input: 'Say exactly: Hello, world!',
      );

  /// Yields accumulated output, and succeeds only on response.completed.
  Stream<String> stream({
    required String clientId,
    required String model,
    required String input,
  }) async* {
    var output = '';
    await for (final event in events(
      clientId: clientId,
      body: {
        'model': model,
        'input': [
          {'role': 'user', 'content': input},
        ],
      },
    )) {
      if (event['type'] == 'response.output_text.delta' &&
          event['delta'] is String) {
        output += event['delta'] as String;
        yield output;
      }
    }
  }

  /// Structured events for SDK adapters with the same account and completion checks.
  Stream<Map<String, dynamic>> events({
    required String clientId,
    required Map<String, dynamic> body,
  }) async* {
    final generation = _generation;
    final token = await auth.accessToken(clientId);
    _checkSession(clientId, generation);
    final client = _clientFactory();
    _requests.add(client);
    try {
      final request =
          http.Request('POST', Uri.parse('$openAiResource/responses'))
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Accept': 'text/event-stream',
            })
            ..body = jsonEncode({...body, 'store': false, 'stream': true});
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      final requestId = response.headers['openai-request-id'] ??
          response.headers['x-request-id'];
      if (response.statusCode != 200) {
        final body = await http.Response.fromStream(
          response,
        ).timeout(const Duration(seconds: 20));
        readJson(body); // Throws with safe status/code/request-id diagnostics.
        throw responseError(response.statusCode, null, requestId);
      }
      // Some plan-usage gateways omit the SSE media type. Validate the actual
      // event framing and terminal event instead of rejecting valid streams
      // solely from Content-Type. JSON errors still retain their safe codes.
      final mediaType = (response.headers['content-type'] ?? '')
          .split(';')
          .first
          .trim()
          .toLowerCase();
      if (mediaType == 'application/json') {
        final body = await http.Response.fromStream(
          response,
        ).timeout(const Duration(seconds: 20));
        final json = readJson(body);
        if (json['error'] != null) {
          throw responseError(200, json, requestId);
        }
        throw ChatGptException(
          'invalid_stream_content_type_json',
          'OpenAI returned JSON instead of a response stream.',
          status: response.statusCode,
          requestId: requestId,
        );
      }
      await for (final json in decodeResponseEvents(
        response.stream.timeout(const Duration(seconds: 60)),
      )) {
        _checkSession(clientId, generation);
        switch (json['type']) {
          case 'response.failed':
          case 'error':
            final error = json['response'] is Map
                ? (json['response'] as Map)['error']
                : json['error'] ?? json;
            throw responseError(200, {'error': error}, requestId);
          case 'response.incomplete':
            throw const ChatGptException(
              'response_incomplete',
              'The response was not completed.',
            );
          case 'response.completed':
            if (json['response'] is! Map ||
                (json['response'] as Map)['status'] != 'completed') {
              throw ChatGptException(
                'invalid_stream_completion',
                'The response did not complete successfully.',
                status: response.statusCode,
                requestId: requestId,
              );
            }
            yield json;
            return;
        }
        yield json;
      }
      throw const ChatGptException(
        'stream_interrupted',
        'The response stream ended before completion.',
      );
    } on ChatGptException {
      rethrow;
    } catch (_) {
      _checkSession(clientId, generation);
      throw const ChatGptException(
        'network_error',
        'The OpenAI connection was interrupted. Try again.',
      );
    } finally {
      _requests.remove(client);
      client.close();
    }
  }

  void _checkSession(String clientId, int generation) {
    if (generation != _generation || auth.activeProfile?.clientId != clientId) {
      throw const ChatGptException(
        'cancelled',
        'The request was cancelled or the account changed.',
      );
    }
  }
}

/// SSE records can span network chunks and contain multiple data lines.
Stream<Map<String, dynamic>> decodeResponseEvents(
  Stream<List<int>> bytes,
) async* {
  final data = <String>[];
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isEmpty) continue;
      final event = data.join('\n');
      data.clear();
      if (event == '[DONE]') continue; // Not proof of response.completed.
      Object? json;
      try {
        json = jsonDecode(event);
      } on FormatException {
        throw const ChatGptException(
          'invalid_stream_event',
          'Invalid OpenAI stream event.',
        );
      }
      if (json is! Map<String, dynamic>) {
        throw const ChatGptException(
          'invalid_stream_event',
          'Invalid OpenAI stream event.',
        );
      }
      yield json;
    } else if (line.startsWith('data:')) {
      data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
    } else if (!line.startsWith(':') &&
        !line.startsWith('event:') &&
        !line.startsWith('id:') &&
        !line.startsWith('retry:')) {
      throw const ChatGptException(
        'invalid_stream_framing',
        'OpenAI returned a non-SSE response.',
      );
    }
  }
  // A trailing unterminated SSE record is not a completed event.
}
