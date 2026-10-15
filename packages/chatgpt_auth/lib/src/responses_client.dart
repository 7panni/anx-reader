import 'dart:convert';
import 'package:http/http.dart' as http;
import 'responses.dart';
import 'types.dart';

/// Reuses authenticated transport without exposing OAuth tokens to the SDK.
class ChatGptResponsesClient extends http.BaseClient {
  ChatGptResponsesClient(this.responses, {required this.clientId});
  final ChatGptResponses responses;
  final String clientId;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed)
      throw const ChatGptException('cancelled', 'Request cancelled.');
    if (request.method != 'POST' ||
        request.url != Uri.parse('$openAiResource/responses')) {
      throw const ChatGptException(
        'unsupported_endpoint',
        'ChatGPT plan access only supports the public Responses endpoint.',
      );
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(await request.finalize().toBytes()));
    } catch (_) {
      throw const ChatGptException(
        'invalid_request',
        'Invalid Responses request.',
      );
    }
    if (body is! Map<String, dynamic> || body['stream'] != true) {
      throw const ChatGptException(
        'invalid_request',
        'ChatGPT plan requests must use streaming.',
      );
    }
    final normalized = <String, dynamic>{...body};
    if (body['input'] is List) {
      final instructions = <String>[
        if (body['instructions'] is String) body['instructions'] as String,
      ];
      normalized['input'] = [
        for (final item in body['input'] as List)
          if (item is! Map || item['role'] != 'system') item,
      ];
      for (final item in body['input'] as List) {
        if (item is Map && item['role'] == 'system') {
          final content = item['content'];
          if (content is String) {
            instructions.add(content);
          } else if (content is List) {
            for (final part in content) {
              if (part is Map && part['text'] is String) {
                instructions.add(part['text'] as String);
              }
            }
          }
        }
      }
      if (instructions.isNotEmpty) {
        normalized['instructions'] = instructions.join('\n\n');
      }
    }
    if (body['tools'] is List) {
      // Existing reader tools use optional parameters and non-strict schemas.
      // Responses otherwise normalizes omitted strictness differently from Chat.
      normalized['tools'] = [
        for (final tool in body['tools'] as List)
          if (tool is Map && tool['type'] == 'function')
            {...tool, 'strict': false}
          else
            tool,
      ];
    }
    final events = responses
        .events(clientId: clientId, body: normalized)
        .map((event) => utf8.encode('data: ${jsonEncode(event)}\n\n'));
    return http.StreamedResponse(
      events,
      200,
      headers: {'content-type': 'text/event-stream'},
      request: request,
    );
  }

  @override
  void close() {
    _closed = true;
    responses.cancel();
    super.close();
  }
}
