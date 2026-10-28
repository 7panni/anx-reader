import 'package:flutter/widgets.dart';

class RssStrings {
  RssStrings(BuildContext context)
      : zh = Localizations.localeOf(context).languageCode == 'zh';
  final bool zh;
  String get subscriptions => zh ? '订阅源' : 'Subscriptions';
  String get add => zh ? '添加订阅' : 'Add feed';
  String get refresh => zh ? '刷新订阅' : 'Refresh feeds';
  String get refreshOne => zh ? '刷新此订阅' : 'Refresh this feed';
  String get all => zh ? '全部文章' : 'All articles';
  String get unread => zh ? '未读' : 'Unread';
  String get starred => zh ? '星标' : 'Starred';
  String get search => zh ? '搜索文章' : 'Search articles';
  String get noFeeds => zh ? '添加第一个 RSS 订阅' : 'Add your first RSS feed';
  String get feedHint => zh
      ? '订阅更新会保存在本机，阅读时可直接向 AI 提问。'
      : 'Updates are saved locally. Ask AI about any article as you read.';
  String get feedAddress => zh ? 'RSS 或 Atom 订阅地址' : 'RSS or Atom feed URL';
  String get invalidAddress =>
      zh ? '请输入有效的 http 或 https 订阅地址' : 'Enter a valid HTTP or HTTPS feed URL';
  String get cancel => zh ? '取消' : 'Cancel';
  String get empty => zh ? '没有符合条件的文章' : 'No matching articles';
  String get select => zh ? '选择一篇文章开始阅读' : 'Select an article to read';
  String get unsubscribe => zh ? '取消订阅' : 'Unsubscribe';
  String removeMessage(String title) => zh
      ? '取消订阅「$title」？此订阅在本机保存的文章和阅读标记也会删除。'
      : 'Unsubscribe from “$title”? Its locally saved articles and reading flags will also be deleted.';
  String get read => zh ? '标为已读' : 'Mark read';
  String get markUnread => zh ? '标为未读' : 'Mark unread';
  String get star => zh ? '添加星标' : 'Star article';
  String get unstar => zh ? '取消星标' : 'Unstar article';
  String get original => zh ? '打开原网页' : 'Open original';
  String get ask => zh ? '询问 AI' : 'Ask AI';
  String get aiUnavailable =>
      zh ? '当前版本未启用 AI' : 'AI is disabled in this build';
  String get back => zh ? '返回文章列表' : 'Back to articles';
  String get noBody => zh
      ? '订阅源没有提供正文，可打开原网页阅读。'
      : 'This feed did not include a body. Open the original page to read it.';
  String get bodyHint => zh
      ? '正文来自订阅源，可能仅包含摘要。'
      : 'Content is supplied by the feed and may be an excerpt.';
  String get retry => zh ? '重试' : 'Retry';
  String get loadFailed =>
      zh ? '无法读取本机 RSS 数据' : 'Could not read local RSS data';
  String get local => zh ? '本机订阅' : 'Local feeds';
  String get unknownDate => zh ? '日期未知' : 'Unknown date';
  String articleCount(int n) => zh ? '$n 篇文章' : '$n articles';
  String unreadCount(int n) => zh ? '$n 篇未读' : '$n unread';
  String refreshResult(int n, int errors) => zh
      ? '新增 $n 篇文章${errors > 0 ? '，$errors 个订阅刷新失败，已保留缓存' : ''}'
      : '$n new articles${errors > 0 ? '; $errors feeds failed, cached articles kept' : ''}';
  String get alreadyAdded => zh ? '这个订阅已存在' : 'This feed is already subscribed';
  String get aiContext => zh
      ? '已附上本文内容，发送后由当前选择的 AI 服务处理。'
      : 'This article is attached and will be sent to the selected AI service when you send a message.';
  String get summary => zh ? '总结要点' : 'Summarize';
  String get summaryPrompt => '请总结本文的核心观点和依据，并说明文中没有回答的问题。';
  String get card => zh ? '生成知识卡片' : 'Knowledge card';
  String get cardPrompt =>
      '请根据本文生成 Markdown 知识卡片，包含标题、来源链接、核心观点、依据、适用边界和一个自检问题。区分原文观点与归纳，不补写原文没有的事实。';
  String get truncated => zh
      ? '文章较长，本次附上前 60,000 个字符；回答可能不覆盖后文。'
      : 'This long article is limited to the first 60,000 characters; later content is not attached.';
  String get errorHint => zh
      ? '订阅出错，可重试；已保存的文章仍可阅读。'
      : 'Feed error. Retry when ready; saved articles remain available.';
}
