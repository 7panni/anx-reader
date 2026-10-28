import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;

String rssPlainText(String value) {
  final fragment = html.parseFragment(value);
  for (final e in fragment.querySelectorAll('script, style')) {
    e.remove();
  }
  for (final e in fragment
      .querySelectorAll('p, div, li, h1, h2, h3, h4, pre, blockquote, br')) {
    e.nodes.add(dom.Text('\n'));
  }
  return fragment.text ?? '';
}

/// Only web links may leave the reader or load images. Relative URLs use the
/// article/feed URL, rather than the app's local origin.
String? rssWebUrl(String? value, [String? base]) {
  if (value == null || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return null;
  final resolved = base == null ? uri : Uri.parse(base).resolveUri(uri);
  if (!['http', 'https'].contains(resolved.scheme) || resolved.host.isEmpty) {
    return null;
  }
  return resolved.removeFragment().toString();
}

class RssSubscription {
  const RssSubscription(
      {required this.id,
      required this.url,
      required this.title,
      this.siteUrl,
      this.etag,
      this.lastModified,
      this.refreshedAt,
      this.error,
      this.unread = 0});
  final int id;
  final String url;
  final String title;
  final String? siteUrl;
  final String? etag;
  final String? lastModified;
  final int? refreshedAt;
  final String? error;
  final int unread;

  factory RssSubscription.fromRow(Map<String, Object?> row) => RssSubscription(
      id: row['id'] as int,
      url: row['url'] as String,
      title: row['title'] as String,
      siteUrl: row['site_url'] as String?,
      etag: row['etag'] as String?,
      lastModified: row['last_modified'] as String?,
      refreshedAt: row['refreshed_at'] as int?,
      error: row['error'] as String?,
      unread: (row['unread'] as int?) ?? 0);
}

class RssEntry {
  const RssEntry(
      {required this.key,
      required this.title,
      required this.contentHtml,
      this.id,
      this.feedId,
      this.feedTitle = '',
      this.url,
      this.author,
      this.publishedAt,
      this.isRead = false,
      this.starred = false});
  final int? id;
  final int? feedId;
  final String feedTitle;
  final String key;
  final String title;
  final String contentHtml;
  final String? url;
  final String? author;
  final int? publishedAt;
  final bool isRead;
  final bool starred;
  String get plainText => rssPlainText(contentHtml).trim();

  static String identity(
      {String? guid, String? url, required String title, int? publishedAt}) {
    if (guid != null && guid.trim().isNotEmpty) return 'id:${guid.trim()}';
    if (url != null) return 'url:$url';
    return 'hash:${sha256.convert(utf8.encode('$title|$publishedAt'))}';
  }

  factory RssEntry.fromRow(Map<String, Object?> row) => RssEntry(
      id: row['id'] as int,
      feedId: row['feed_id'] as int,
      feedTitle: (row['feed_title'] as String?) ?? '',
      key: row['item_key'] as String,
      title: row['title'] as String,
      contentHtml: row['content_html'] as String,
      url: row['url'] as String?,
      author: row['author'] as String?,
      publishedAt: row['published_at'] as int?,
      isRead: row['is_read'] == 1,
      starred: row['starred'] == 1);
}

class ParsedRssFeed {
  const ParsedRssFeed(
      {required this.title, required this.entries, this.siteUrl});
  final String title;
  final String? siteUrl;
  final List<RssEntry> entries;
}
