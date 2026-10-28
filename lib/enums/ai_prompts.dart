import 'dart:convert';

import 'package:crypto/crypto.dart';

enum AiPrompts {
  test,
  summaryTheChapter,
  summaryTheBook,
  summaryThePreviousContent,
  translate,
  fullTextTranslate,
  mindmap,
}

extension AiPromptsJson on AiPrompts {
  // Match only unchanged saved defaults; preserve custom prompts and preferences.
  static const _legacyDefaultHashes = {
    AiPrompts.test:
        'f7c5f3a7cc305a32cf9d4b4b7f4fa43b26c9deca664ce44b4a851629b3c091b0',
    AiPrompts.summaryTheChapter:
        '2a61c2ea82f0917fde7c73b1b187969eb16eb9e33e2e1052244503b14b90b6eb',
    AiPrompts.summaryTheBook:
        '7f2201284d5a9cd2905880e902d1e24431a0f19b9720fdb27421d289f29384c6',
    AiPrompts.summaryThePreviousContent:
        'bc75b8000c68a7a81a6a3f6b1c6eb5fa3ae0e7601e8fc116c98868b0efd912fe',
    AiPrompts.fullTextTranslate:
        '679b95feaff7dc359c35e5ca905f9c7cec902c66083453fbdcebdfedf220e422',
    AiPrompts.translate:
        '2a5321882d9ed2b45686f654929b94b5aa7c3d899094833cfe8fc9a773571400',
    AiPrompts.mindmap:
        'e1c79b9681318540b4d195d3c1d6ca54a11c77681087c79f0e981acfe0c1dfc6',
  };

  bool isLegacyDefault(String prompt) =>
      sha256.convert(utf8.encode(prompt.trim())).toString() ==
      _legacyDefaultHashes[this];

  String getPrompt() {
    switch (this) {
      case AiPrompts.test:
        return '''
请用简洁、友好的语言介绍你自己。回复使用语言代码 {{language_locale}} 对应的语言。
        ''';

      case AiPrompts.summaryTheChapter:
        return '''
请总结本章内容，并遵循以下要求：
语言：与章节原文保持一致。
长度：8—10 个完整句子。
结构：分为三段，依次概括主要情节、核心人物、主题或寓意。
风格：避免使用“本章描述了……”等套话。
视角：从文学分析的角度提炼内容，不只复述情节。
        ''';

      case AiPrompts.summaryTheBook:
        return '''
请生成本书摘要，要求如下：
使用与书名一致的语言。
概括核心冲突，并用 » 符号突出显示。
介绍 3 位核心人物及其动机，写出姓名与关键选择。
提炼 3—5 个主题关键词。
不要剧透最终结局。
        ''';

      case AiPrompts.summaryThePreviousContent:
        return '''
我正在重读一本很久以前读过的书。请帮我快速回顾前文，以便继续阅读。
要求：用 3—5 句话保留核心信息，与前文原文使用相同语言，避免逐字复述。

前文内容：
{{previous_content}}
        ''';

      case AiPrompts.fullTextTranslate:
        return '''
你是一位专业译者。请将以下文字翻译成 {{to_locale}}。

原文语言：{{from_locale}}
原文：{{text}}

要求：
只输出译文，不添加任何其他内容。
不要附加解释、注释、评论或原文。
保留段落结构和排版。
保持原文的语气与风格。
        ''';

      case AiPrompts.translate:
        return '''
你是 Anx Reader 的“翻译与释义”专家。请用用户偏好的语言 {{to_locale}} 给出准确、可靠的解答。

本次输入：
原文：{{text}}
原文语言提示：{{from_locale}}
阅读上下文（可能为空）：{{contextText}}

回答必须依次包含以下两部分。只输出最终答案，不输出模板框架或任务说明。

第一部分：结合上下文的简明释义
先用 1—2 个简洁的词语，直接说明原文在当前语境中的含义或译法。
利用上下文消除歧义，采用自然易懂的表达。只有为澄清含义确有必要时才引用原文，避免大量引用。

第二部分：详细分析
准确理解原文，结合阅读上下文判断代词指向、语气、专业知识及文化典故。上下文为空时，说明判断仅依据当前片段。
提供词典层面的信息（音标、词性、细微义项），并补充一条百科式背景（来源、文化、文学典故或相关事实）。
给出实用说明，帮助读者自然理解或使用该表达。

输出约束：
全文使用 {{to_locale}}，所有小标题也须译成该语言。
简洁且完整。仅在某部分确实不适用时省略，并简要说明原因。
不要使用 Markdown 列表、编号符号或代码围栏，只使用本地化小标题与正文。

如果原文语言与 {{to_locale}} 相同，按进阶单语词典方式回答，详细分析包含：
发音：提供可靠的音标；不确定时如实说明。
词性：列出与本处用法相关的词性。
含义：简明解释主要义项。
例句：给出两个自然例句，并作简短说明。
百科：补充一条相关历史、文学、习语来源或专业用法背景。

如果原文语言与 {{to_locale}} 不同，按译者兼语言教师的方式回答，详细分析包含：
原文片段：引用或适当缩短原文；缩短时明确说明。
译文：译文自然流畅，并保留语气和语体。
翻译说明：解释关键选词，以及上下文如何影响译法。
词汇表：用 {{to_locale}} 解释 2—4 个关键术语。
百科：补充一条有助理解的文化、场景或概念背景。
        ''';

      case AiPrompts.mindmap:
        return '''
你是 Anx Reader 的思维导图助手。请分析用户当前阅读的上下文，通过 `mindmap_draw` 工具构建清晰的层级图。

目标：
确定中心主题或重点议题。
提炼 4—7 个主要分支，覆盖情节线、人物、概念或论证。
补充第二层子节点，标签简短，每个标签不超过 8 个词。
突出有意义的关系，不必穷尽所有细节。

工具规则：
回复文字前必须先调用 `mindmap_draw`。
工具输入中，`title` 为简明图名，`nodes` 为包含父子关系的结构化节点列表。
同一张图中的节点 ID 必须唯一且稳定。
节点标签与原文保持相同语言。

调用工具后，用三个项目符号句子依次说明：导图的整体思路、关键分支或分组、呈现出的重要洞见或矛盾。
        ''';
    }
  }
}
