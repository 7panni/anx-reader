import 'dart:convert';
import 'package:anx_reader/service/chatgpt/reader_model.dart';
import 'package:anx_reader/service/chatgpt/reader_provider.dart';
import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/prompts.dart';
import '../packages/chatgpt_auth/test/support.dart';

String event(Map<String, dynamic> body) => 'data: ${jsonEncode(body)}\n\n';
Map<String, dynamic> response(
  List<Map<String, dynamic>> output, {
  String status = 'completed',
}) => {
  'id': 'resp_test',
  'object': 'response',
  'created_at': 1,
  'status': status,
  'model': 'test-model',
  'output': output,
};

void main() {
  late FakeOpenAi fake;
  setUp(() async {
    fake = FakeOpenAi();
    await fake.auth.signIn();
  });
  tearDown(() => fake.auth.close());

  test('built-in ChatGPT is inserted once with no API key', () {
    final providers = withChatGptProvider(withChatGptProvider([]));
    expect(providers.length, 1);
    expect(providers.single.apiKeys, isEmpty);
    expect(providers.single.id, chatGptProviderId);
  });

  test(
    'Responses SDK adapter keeps text once and preserves structured conversation',
    () async {
      Map<String, dynamic>? sent;
      final model = ChatGptReaderModel(
        model: 'test-model',
        transport: ChatGptResponsesClient(
          ChatGptResponses(
            fake.auth,
            clientFactory: () => MockClient((request) async {
              sent = jsonDecode(request.body) as Map<String, dynamic>;
              return http.Response(
                [
                  event({
                    'type': 'response.created',
                    'response': response([], status: 'in_progress'),
                  }),
                  event({
                    'type': 'response.output_text.delta',
                    'delta': 'Hello, world!',
                    'output_index': 0,
                    'content_index': 0,
                  }),
                  event({
                    'type': 'response.completed',
                    'response': response([
                      {
                        'type': 'message',
                        'id': 'msg_1',
                        'role': 'assistant',
                        'status': 'completed',
                        'content': [
                          {
                            'type': 'output_text',
                            'text': 'Hello, world!',
                            'annotations': [],
                          },
                        ],
                      },
                    ]),
                  }),
                ].join(),
                200,
              );
            }),
          ),
          clientId: fake.issuedClient,
        ),
      );
      final result = await model.invoke(
        PromptValue.chat([
          ChatMessage.system('synthetic instruction'),
          ChatMessage.humanText('synthetic question'),
          ChatMessage.ai('synthetic prior answer'),
          ChatMessage.humanText('synthetic follow-up'),
        ]),
      );
      expect(result.output.content, 'Hello, world!');
      expect(sent!['store'], false);
      expect(sent!['stream'], true);
      expect((sent!['input'] as List).length, 3);
      expect(sent!['instructions'], 'synthetic instruction');
      expect(jsonEncode(sent), isNot(contains('synthetic-access')));
      model.close();
    },
  );

  test(
    'Responses SDK adapter emits a tool call once, ready for the existing agent',
    () async {
      final tool = {
        'type': 'function_call',
        'id': 'fc_1',
        'call_id': 'call_1',
        'name': 'read_chapter',
        'arguments': '{"chapter":1}',
        'status': 'completed',
      };
      final model = ChatGptReaderModel(
        model: 'test-model',
        transport: ChatGptResponsesClient(
          ChatGptResponses(
            fake.auth,
            clientFactory: () => MockClient(
              (_) async => http.Response(
                [
                  event({
                    'type': 'response.created',
                    'response': response([], status: 'in_progress'),
                  }),
                  event({
                    'type': 'response.output_item.added',
                    'output_index': 0,
                    'item': {...tool, 'arguments': '', 'status': 'in_progress'},
                  }),
                  event({
                    'type': 'response.function_call_arguments.delta',
                    'output_index': 0,
                    'item_id': 'fc_1',
                    'delta': '{"chapter":1}',
                  }),
                  event({
                    'type': 'response.completed',
                    'response': response([tool]),
                  }),
                ].join(),
                200,
              ),
            ),
          ),
          clientId: fake.issuedClient,
        ),
      );
      final result = await model.invoke(
        PromptValue.chat([ChatMessage.humanText('read synthetic chapter')]),
      );
      expect(result.output.toolCalls.length, 1);
      expect(result.output.toolCalls.single.name, 'read_chapter');
      expect(result.output.toolCalls.single.argumentsRaw, '{"chapter":1}');
      model.close();
    },
  );
}
