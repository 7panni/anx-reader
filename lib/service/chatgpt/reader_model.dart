import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/prompts.dart';
import 'package:langchain_openai/langchain_openai.dart';

/// Keeps the existing agent/tool pipeline while using the OAuth transport.
class ChatGptReaderModel extends ChatOpenAIResponses {
  ChatGptReaderModel({required this.transport, required String model})
    : super(
        client: transport,
        defaultOptions: ChatOpenAIResponsesOptions(model: model, store: false),
      );

  final ChatGptResponsesClient transport;

  @override
  Stream<ChatResult> stream(
    PromptValue input, {
    ChatOpenAIResponsesOptions? options,
  }) async* {
    var hasText = false;
    var hasTools = false;
    await for (final chunk in super.stream(input, options: options)) {
      // The pinned LangChain mapper emits deltas followed by the full response.
      // Keep terminal metadata, without appending the same text/tools twice.
      if (chunk.metadata.containsKey('created_at')) {
        yield ChatResult(
          id: chunk.id,
          finishReason: chunk.finishReason,
          usage: chunk.usage,
          metadata: chunk.metadata,
          streaming: true,
          output: AIChatMessage(
            content: hasText ? '' : chunk.output.content,
            toolCalls: hasTools ? const [] : chunk.output.toolCalls,
          ),
        );
      } else {
        hasText = hasText || chunk.output.content.isNotEmpty;
        hasTools = hasTools || chunk.output.toolCalls.isNotEmpty;
        yield chunk;
      }
    }
  }

  @override
  Future<ChatResult> invoke(
    PromptValue input, {
    ChatOpenAIResponsesOptions? options,
  }) async {
    ChatResult? result;
    await for (final chunk in stream(input, options: options)) {
      result = result == null ? chunk : result.concat(chunk);
    }
    if (result == null) {
      throw const ChatGptException(
        'empty_response',
        'No response was returned.',
      );
    }
    return result;
  }

  @override
  void close() {
    transport.close();
    super.close();
  }
}
