import 'dart:convert';
import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'support.dart';

Matcher code(String value) =>
    isA<ChatGptException>().having((e) => e.code, 'code', value);
String event(Map<String, dynamic> json) => 'data: ${jsonEncode(json)}\n\n';
String delta(String text) =>
    event({'type': 'response.output_text.delta', 'delta': text});
String get completed => event({
      'type': 'response.completed',
      'response': {'status': 'completed'},
    });

void main() {
  late FakeOpenAi fake;
  setUp(() async {
    fake = FakeOpenAi();
    await fake.auth.signIn();
  });
  tearDown(() => fake.auth.close());

  test(
    'model catalog uses account-specific visibility, display names and server order',
    () async {
      final api = ChatGptResponses(
        fake.auth,
        clientFactory: () => MockClient((request) async {
          expect(request.url.toString(), '$openAiResource/models');
          expect(request.headers['Authorization'], 'Bearer synthetic-access');
          return jsonResponse({
            'models': [
              {
                'slug': 'second',
                'display_name': 'Second',
                'visibility': 'list',
              },
              {
                'slug': 'hidden',
                'display_name': 'Hidden',
                'visibility': 'hidden',
              },
              {'slug': 'first', 'display_name': 'First', 'visibility': 'list'},
            ],
          });
        }),
      );
      final models = await api.models(fake.issuedClient);
      expect(models.map((m) => m.slug), ['second', 'first']);
      expect(models.first.displayName, 'Second');
    },
  );

  test(
    'inference uses public endpoint, fixed verification input and required flags',
    () async {
      final api = ChatGptResponses(
        fake.auth,
        clientFactory: () => MockClient((request) async {
          expect(request.url.toString(), '$openAiResource/responses');
          expect(request.method, 'POST');
          expect(request.followRedirects, false);
          final json = jsonDecode(request.body) as Map;
          expect(json['store'], false);
          expect(json['stream'], true);
          expect(json['model'], 'test-model');
          expect(json['input'][0]['content'], 'Say exactly: Hello, world!');
          return http.Response(
            '${delta('Hello, ')}${delta('world!')}$completed',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      expect(
        await api
            .verifyConnection(clientId: fake.issuedClient, model: 'test-model')
            .toList(),
        ['Hello, ', 'Hello, world!'],
      );
    },
  );

  test('JSON error with HTTP 200 preserves its safe code', () async {
    final api = ChatGptResponses(
      fake.auth,
      clientFactory: () => MockClient(
        (_) async => jsonResponse({
          'error': {
            'code': 'subscription_sharing_usage_unavailable',
            'message': 'synthetic-access must not be echoed',
          },
        }),
      ),
    );
    await expectLater(
      api
          .verifyConnection(clientId: fake.issuedClient, model: 'test-model')
          .toList(),
      throwsA(code('subscription_sharing_usage_unavailable')),
    );
  });

  test('unexpected HTTP 200 JSON is not a successful stream', () async {
    final api = ChatGptResponses(
      fake.auth,
      clientFactory: () =>
          MockClient((_) async => jsonResponse({'status': 'completed'})),
    );
    await expectLater(
      api
          .verifyConnection(clientId: fake.issuedClient, model: 'test-model')
          .toList(),
      throwsA(code('invalid_stream_content_type_json')),
    );
  });

  for (final headers in <Map<String, String>>[
    {},
    {'content-type': 'text/plain; charset=utf-8'},
    {'content-type': 'application/octet-stream'},
  ]) {
    test('valid SSE completes despite gateway media type $headers', () async {
      final api = ChatGptResponses(
        fake.auth,
        clientFactory: () => MockClient(
          (_) async => http.Response(
            '${delta('Hello, world!')}$completed',
            200,
            headers: headers,
          ),
        ),
      );
      expect(
        await api
            .verifyConnection(clientId: fake.issuedClient, model: 'test-model')
            .toList(),
        ['Hello, world!'],
      );
    });
  }

  for (final body in ['<html>not SSE</html>', 'data: {broken}\n\n']) {
    test('invalid content never succeeds even with HTTP 200: $body', () async {
      final api = ChatGptResponses(
        fake.auth,
        clientFactory: () => MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        api
            .verifyConnection(clientId: fake.issuedClient, model: 'test-model')
            .toList(),
        throwsA(isA<ChatGptException>()),
      );
    });
  }

  test('partial text followed by a usage error is a failure', () async {
    final api = ChatGptResponses(
      fake.auth,
      clientFactory: () => MockClient(
        (_) async => http.Response(
          '${delta('partial')}${event({
                'type': 'response.failed',
                'response': {
                  'error': {
                    'code': 'subscription_sharing_usage_limit_exceeded'
                  },
                },
              })}',
          200,
          headers: {
            'content-type': 'text/event-stream',
            'x-request-id': 'req-test',
          },
        ),
      ),
    );
    await expectLater(
      api.verifyConnection(clientId: fake.issuedClient, model: 'test-model'),
      emitsInOrder([
        'partial',
        emitsError(code('subscription_sharing_usage_limit_exceeded')),
        emitsDone,
      ]),
    );
  });

  for (final ending in <String, String>{
    'closed stream': '',
    'DONE marker': 'data: [DONE]\n\n',
    'unterminated completion event': completed.trimRight(),
    'incomplete response': event({'type': 'response.incomplete'}),
  }.entries) {
    test('${ending.key} cannot be reported as completed', () async {
      final api = ChatGptResponses(
        fake.auth,
        clientFactory: () => MockClient(
          (_) async => http.Response(
            '${delta('partial')}${ending.value}',
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
      );
      await expectLater(
        api
            .verifyConnection(clientId: fake.issuedClient, model: 'test-model')
            .toList(),
        throwsA(isA<ChatGptException>()),
      );
    });
  }

  test(
    'admission detail body preserves status without echoing sensitive content',
    () async {
      var count = 0;
      final api = ChatGptResponses(
        fake.auth,
        clientFactory: () => MockClient((_) async {
          count++;
          return jsonResponse({
            'detail': 'synthetic-access must never be echoed',
          }, 403);
        }),
      );
      await expectLater(
        api
            .verifyConnection(clientId: fake.issuedClient, model: 'test-model')
            .toList(),
        throwsA(
          isA<ChatGptException>().having((e) => e.status, 'status', 403).having(
                (e) => e.toString(),
                'diagnostics',
                isNot(contains('synthetic-access')),
              ),
        ),
      );
      expect(count, 1); // No hidden retry or billing fallback.
    },
  );

  test(
    'account switch cancels responses and model requests are never rebound',
    () async {
      final first = fake.issuedClient;
      fake.issuedClient = 'oaiapp_other';
      fake.subject = 'other';
      await fake.auth.signIn();
      final api = ChatGptResponses(
        fake.auth,
        clientFactory: () => MockClient((_) async {
          fail('A request for a previously selected account must not be sent');
        }),
      );
      await expectLater(api.models(first), throwsA(code('account_changed')));
    },
  );

  test(
    'SSE parser handles split UTF-8, CRLF, comments and multi-line data',
    () async {
      final content =
          ': keepalive\r\nevent: ignored\r\ndata: {"type":"response.output_text.delta",\r\n'
          'data: "delta":"你好"}\r\n\r\n$completed';
      final bytes = utf8.encode(content);
      final chunks = [
        for (var i = 0; i < bytes.length; i += 2)
          bytes.sublist(i, i + 2 > bytes.length ? bytes.length : i + 2),
      ];
      final events = await decodeResponseEvents(
        Stream.fromIterable(chunks),
      ).toList();
      expect(events.first['delta'], '你好');
      expect(events.last['type'], 'response.completed');
    },
  );
}
