import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/ai_prompts.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
  });

  test(
      'Saved original English defaults resolve to Chinese without rewriting prefs',
      () async {
    const previous = '''
Summarize the chapter content. Your reply must follow these requirements:
Language: Use the same language as the original chapter content.
Length: 8-10 complete sentences.
Structure: Three paragraphs: Main plot, Core characters, Themes/messages.
Style: Avoid boilerplate phrases like "This chapter describes..."
Perspective: Maintain a literary analysis perspective, not just narration.
        ''';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('aiPrompt_summaryTheChapter', previous);
    expect(Prefs().getAiPrompt(AiPrompts.summaryTheChapter),
        AiPrompts.summaryTheChapter.getPrompt());
    expect(prefs.getString('aiPrompt_summaryTheChapter'), previous);
    expect(AiPrompts.summaryTheBook.isLegacyDefault(previous), isFalse);
  });

  test(
      'Custom English or Chinese prompts take precedence and reset uses new default',
      () {
    for (final id in AiPrompts.values) {
      for (final custom in ['My own prompt for ${id.name}', '我的自定义提示词']) {
        Prefs().saveAiPrompt(id, custom);
        expect(Prefs().getAiPrompt(id), custom);
      }
      Prefs().deleteAiPrompt(id);
      expect(Prefs().getAiPrompt(id), id.getPrompt());
    }
  });

  test('All translated templates format through the real prompt builders', () {
    final prompts = [
      generatePromptTest(),
      generatePromptSummaryTheChapter(),
      generatePromptSummaryTheBook(),
      generatePromptSummaryThePreviousContent('前文样例'),
      generatePromptTranslate('source sample', '中文', '英语',
          contextText: 'context sample'),
      generatePromptFullTextTranslate('source sample', '中文', '英语'),
      generatePromptMindmap(),
    ];
    for (final prompt in prompts) {
      final text = prompt.buildString();
      expect(text, isNot(contains('{{')));
      expect(text, matches(RegExp(r'[\u4e00-\u9fff]')));
      for (final value in prompt.variables.values) {
        expect(text, contains(value.toString()));
      }
    }
    expect(prompts.last.buildString(), contains('`mindmap_draw`'));
  });
}
