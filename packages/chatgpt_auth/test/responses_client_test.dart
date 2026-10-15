import 'dart:convert';
import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'support.dart';

void main() {
  late FakeOpenAi fake;
  setUp(() async {
    fake = FakeOpenAi();
    await fake.auth.signIn();
  });
  tearDown(() => fake.auth.close());

  test(
    'SDK transport pins endpoint and account, enforces flags and preserves tool input',
    () async {
      Map<String, dynamic>? sent;
      final transport = ChatGptResponsesClient(
        ChatGptResponses(
          fake.auth,
          clientFactory: () => MockClient((request) async {
            expect(request.headers['Authorization'], 'Bearer synthetic-access');
            expect(request.followRedirects, false);
            sent = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              'data: {"type":"response.completed","response":{"status":"completed"}}\n\n',
              200,
            );
          }),
        ),
        clientId: fake.issuedClient,
      );
      final request =
          http.Request('POST', Uri.parse('$openAiResource/responses'))
            ..body = jsonEncode({
              'model': 'test-model',
              'store': true,
              'stream': true,
              'input': [
                {
                  'type': 'function_call_output',
                  'call_id': 'call_1',
                  'output': 'synthetic chapter',
                },
              ],
              'tools': [
                {'type': 'function', 'name': 'read_chapter', 'parameters': {}},
              ],
            });
      final response = await transport.send(request);
      final events = await decodeResponseEvents(response.stream).toList();
      expect(events.single['type'], 'response.completed');
      expect(sent!['store'], false);
      expect(sent!['input'][0]['call_id'], 'call_1');
      expect(sent!['tools'][0]['name'], 'read_chapter');
      expect(sent!['tools'][0]['strict'], false);
      transport.close();
    },
  );

  test(
    'SDK transport rejects foreign URLs before sending any request',
    () async {
      final transport = ChatGptResponsesClient(
        ChatGptResponses(
          fake.auth,
          clientFactory: () =>
              MockClient((_) async => throw StateError('must not send')),
        ),
        clientId: fake.issuedClient,
      );
      await expectLater(
        transport.send(
          http.Request('POST', Uri.parse('https://example.test/responses')),
        ),
        throwsA(
          isA<ChatGptException>().having(
            (e) => e.code,
            'code',
            'unsupported_endpoint',
          ),
        ),
      );
      transport.close();
    },
  );

  test(
    'SDK stream never turns partial output or plan limit into success or retry',
    () async {
      var calls = 0;
      final transport = ChatGptResponsesClient(
        ChatGptResponses(
          fake.auth,
          clientFactory: () => MockClient((_) async {
            calls++;
            return http.Response(
              'data: {"type":"response.output_text.delta","delta":"partial"}\n\n'
              'data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}\n\n',
              200,
            );
          }),
        ),
        clientId: fake.issuedClient,
      );
      final response = await transport.send(
        http.Request('POST', Uri.parse('$openAiResource/responses'))
          ..body = jsonEncode({'stream': true, 'model': 'test-model'}),
      );
      await expectLater(
        response.stream.drain<void>(),
        throwsA(
          isA<ChatGptException>().having(
            (e) => e.code,
            'code',
            'subscription_sharing_usage_limit_exceeded',
          ),
        ),
      );
      expect(calls, 1);
      transport.close();
    },
  );
}
