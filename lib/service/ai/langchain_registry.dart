import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:anx_reader/service/chatgpt/desktop_chatgpt.dart';
import 'package:anx_reader/service/chatgpt/reader_model.dart';
import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langchain_anthropic/langchain_anthropic.dart';
import 'package:langchain_core/chat_models.dart';
import 'package:langchain_core/tools.dart';
import 'package:langchain_google/langchain_google.dart';
import 'package:langchain_openai/langchain_openai.dart';

import 'langchain_ai_config.dart';

/// Factory responsible for building chat models based on user preferences.
class LangchainAiRegistry {
  const LangchainAiRegistry(this.ref);
  final WidgetRef? ref;

  LangchainPipeline resolveChatGpt({
    required String clientId,
    required String model,
    required bool useAgent,
  }) {
    final auth = DesktopChatGptController.instance.auth;
    return _buildPipeline(
      LangchainAiConfig(identifier: 'chatgpt-plan', model: model, apiKey: ''),
      ChatGptReaderModel(
        transport:
            ChatGptResponsesClient(ChatGptResponses(auth), clientId: clientId),
        model: model,
      ),
      useAgent: useAgent,
    );
  }

  LangchainPipeline resolve(
    LangchainAiConfig config, {
    bool useAgent = false,
  }) {
    switch (config.identifier) {
      case 'claude':
        return _buildPipeline(
          config,
          _buildAnthropic(config),
          useAgent: useAgent,
        );
      case 'gemini':
        return _buildPipeline(
          config,
          _buildGoogle(config),
          useAgent: useAgent,
        );
      case 'deepseek':
      case 'openrouter':
      case 'openai':
      default:
        return _buildPipeline(
          config,
          _buildOpenAi(config),
          useAgent: useAgent,
        );
    }
  }

  /// Resolve pipeline based on AiProtocol enum (for new provider system)
  LangchainPipeline resolveByProtocol(
    AiProtocol protocol,
    LangchainAiConfig config, {
    bool useAgent = false,
  }) {
    switch (protocol) {
      case AiProtocol.claude:
        return _buildPipeline(
          config,
          _buildAnthropic(config),
          useAgent: useAgent,
        );
      case AiProtocol.gemini:
        return _buildPipeline(
          config,
          _buildGoogle(config),
          useAgent: useAgent,
        );
      case AiProtocol.openai:
        return _buildPipeline(
          config,
          _buildOpenAi(config),
          useAgent: useAgent,
        );
    }
  }

  BaseChatModel _buildOpenAi(LangchainAiConfig config) {
    return ChatOpenAI(
      apiKey: config.apiKey.isEmpty ? null : config.apiKey,
      baseUrl: config.baseUrl ?? 'https://api.openai.com/v1',
      headers: config.headers.isEmpty ? null : config.headers,
      defaultOptions: config.toOpenAIOptions(),
    );
  }

  BaseChatModel _buildAnthropic(LangchainAiConfig config) {
    return ChatAnthropic(
      apiKey: config.apiKey.isEmpty ? null : config.apiKey,
      baseUrl: config.baseUrl ?? 'https://api.anthropic.com/v1',
      headers: config.headers.isEmpty ? null : config.headers,
      defaultOptions: config.toAnthropicOptions(),
    );
  }

  BaseChatModel _buildGoogle(LangchainAiConfig config) {
    return ChatGoogleGenerativeAI(
      apiKey: config.apiKey.isEmpty ? null : config.apiKey,
      baseUrl: config.baseUrl,
      headers: config.headers.isEmpty ? null : config.headers,
      defaultOptions: config.toGoogleOptions(),
    );
  }

  LangchainPipeline _buildPipeline(
    LangchainAiConfig config,
    BaseChatModel model, {
    required bool useAgent,
  }) {
    if (useAgent) {
      assert(ref != null, 'ref must be provided when useAgent is true');
    }

    final isReading =
        useAgent && ref != null && ref!.read(currentReadingProvider).isReading;

    var tools = const <Tool>[];
    ChatMessage? systemMessage;

    if (useAgent) {
      final enabledIds = Prefs().enabledAiToolIds;
      final toolContext = AiToolContext(ref: ref!);
      tools = AiToolRegistry.buildTools(toolContext, enabledIds);
      final enabledDefs = AiToolRegistry.definitions
          .where((def) => enabledIds.contains(def.id))
          .toList(growable: false);
      systemMessage = _buildAgentSystemMessage(
        isReading: isReading,
        enabledTools: enabledDefs,
      );
    }

    return LangchainPipeline(
      model: model,
      tools: tools,
      systemMessage: systemMessage,
    );
  }

  ChatMessage _buildAgentSystemMessage({
    required bool isReading,
    required List<AiToolDefinition> enabledTools,
  }) {
    final currentLanguageCode =
        Prefs().locale?.languageCode ?? Platform.localeName;

    // Map language code to language name
    final languageMap = {
      'zh': '简体中文',
      'zh-CN': '简体中文',
      'zh-Hans': '简体中文',
      'zh-TW': '繁體中文',
      'zh-Hant': '繁體中文',
      'en': 'English',
      'ja': '日本語',
      'ko': '한국어',
      'fr': 'Français',
      'de': 'Deutsch',
      'es': 'Español',
      'ru': 'Русский',
      'ar': 'العربية',
      'tr': 'Türkçe',
    };

    final languageName = languageMap[currentLanguageCode] ??
        languageMap[currentLanguageCode.split('_').first] ??
        currentLanguageCode;

    final readingStateContext = isReading
        ? '📖 用户正在阅读：专注于当前内容，及时提供理解、翻译和笔记方面的帮助。'
        : '📚 用户正在浏览书库：帮助整理书籍，规划阅读策略。';

    final guidance = '''你是“Anx Reader AI”，集成在 Anx Reader 中的智能阅读助手。

## 角色
你是一位知识丰富的阅读伙伴，通过恰当使用工具和认真分析，帮助用户理解、整理并享受阅读。

## 当前情境
$readingStateContext

## 工具使用原则
1. 先获取上下文：回答前使用工具了解相关情况。
2. 高效组合工具：按需要并行或依次调用多个工具。
3. 优先使用专用工具：用户正在阅读时，优先使用 current_* 系列工具，再考虑通用搜索。
4. 保持透明：使用复杂工具组合时，简要解释依据。

## 可用工具与使用场景
${_formatToolCatalog(enabledTools)}

## 回答策略
1. 理解用户的真实意图。
2. 使用工具收集相关信息。
3. 综合信息，形成连贯的分析。
4. 给出清晰的答案或可操作的建议。

## 沟通方式
- 简洁且完整，避免无关展开。
- 根据工具结果中的具体内容作答。
- 随阅读情境调整语气。
- 需求含糊、影响判断时主动澄清。
- 除非用户明确使用其他语言，否则始终以 **$languageName** 回复。

## Markdown 示例
可使用 Markdown 排版，例如：
- **加粗**：**重点文字**
- *斜体*：*强调文字*
- [链接](https://www.example.com)
- 列表：
  1. 第一项
  2. 第二项
  3. 第三项

## LaTeX 示例
可使用 LaTeX 表达数学公式，例如：

- **公式**: \\( f(x) = x^2 + 2x + 1 \\)
- **积分**: \\( \\int_{0}^{1} x^2 \\, dx \\)
- **矩阵**:

\\[
\\begin{bmatrix}
1 & 2 & 3 \\\\
4 & 5 & 6 \\\\
7 & 8 & 9
\\end{bmatrix}
\\]


## 异常处理
- 没有结果：建议其他搜索方式，或核实书籍与章节上下文。
- 工具失败：说明问题，并尝试其他可行方式。
- 超出能力范围：说明限制，并建议手动处理方法。

## 重要约束
- 尊重隐私，仅通过提供的工具访问数据。
- 专注于阅读相关帮助。
- 不对无法获取的数据作假设。
- 使用用户的语言回复。

请作为用户的阅读伙伴，帮助每次阅读获得更清晰的理解与更好的体验。''';

    return ChatMessage.system(guidance);
  }

  String _formatToolCatalog(List<AiToolDefinition> enabledTools) {
    if (enabledTools.isEmpty) {
      return '_用户目前没有启用工具。_';
    }
    return enabledTools
        .map(
          (tool) =>
              '- **${tool.displayNameOrDefault()}** → ${tool.descriptionOrDefault()}',
        )
        .join('\n');
  }
}

class LangchainPipeline {
  const LangchainPipeline({
    required this.model,
    required this.tools,
    this.systemMessage,
  });

  final BaseChatModel model;
  final List<Tool> tools;
  final ChatMessage? systemMessage;
}
