import 'package:anx_reader/models/ai_provider.dart';

const chatGptProviderId = 'chatgpt-plan';

/// Preferences store only service metadata, never OAuth tokens.
AiProvider chatGptReaderProvider() => const AiProvider(
  id: chatGptProviderId,
  title: 'ChatGPT',
  url: 'https://api.openai.com/v1',
  protocol: AiProtocol.openai,
  isBuiltin: true,
);

List<AiProvider> withChatGptProvider(List<AiProvider> providers) => [
  if (!providers.any((p) => p.id == chatGptProviderId)) chatGptReaderProvider(),
  ...providers,
];
