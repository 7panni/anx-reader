import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:rss_dart/dart_rss.dart';
import 'package:rss_dart/domain/rss1_feed.dart';
import 'package:xml/xml.dart';

import 'rss_models.dart';
import 'rss_store.dart';

class RssFailure implements Exception {
  const RssFailure(this.code, [this.status]);
  final String code;
  final int? status;
  @override
  String toString() => 'RSS: $code${status == null ? '' : ' ($status)'}';
}

class RssService {
  RssService(this.store, {http.Client? client})
      : _client = client ?? http.Client();
  final RssStore store;
  final http.Client _client;
  static const maxFeedBytes = 8 * 1024 * 1024;
  void close() => _client.close();

  static String normalizeUrl(String value) {
    final url = rssWebUrl(value);
    if (url == null || Uri.parse(url).userInfo.isNotEmpty) {
      throw const RssFailure('invalid_url');
    }
    return url;
  }

  Future<int> subscribe(String input) async {
    final url = normalizeUrl(input);
    if (await store.findFeed(url) != null) throw const RssFailure('duplicate');
    return _fetch(url);
  }

  Future<int> refresh(RssSubscription feed) async {
    try {
      return await _fetch(feed.url, existing: feed);
    } catch (error) {
      await store.failed(feed.id, error is RssFailure ? error.code : 'network');
      rethrow;
    }
  }

  Future<int> _fetch(String url, {RssSubscription? existing}) async {
    final abort = Completer<void>();
    try {
      return await (() async {
        final request = http.AbortableRequest('GET', Uri.parse(url),
            abortTrigger: abort.future);
        request.headers['Accept'] =
            'application/atom+xml, application/rss+xml, application/xml, text/xml, */*';
        request.headers['User-Agent'] = 'AI-Reader-RSS/1.0';
        if (existing?.etag != null) {
          request.headers['If-None-Match'] = existing!.etag!;
        }
        if (existing?.lastModified != null) {
          request.headers['If-Modified-Since'] = existing!.lastModified!;
        }
        final response = await _client.send(request);
        if (response.statusCode == 304 && existing != null) {
          await response.stream.drain<void>();
          await store.checked(existing.id);
          return 0;
        }
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          throw RssFailure('http', response.statusCode);
        }
        if ((response.contentLength ?? 0) > maxFeedBytes) {
          throw const RssFailure('too_large');
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxFeedBytes) {
            throw const RssFailure('too_large');
          }
          bytes.addAll(chunk);
        }
        final declared =
            RegExp(r'charset=["\x27]?([\w-]+)', caseSensitive: false)
                .firstMatch(response.headers['content-type'] ?? '')
                ?.group(1);
        final xmlEncoding =
            RegExp(r'encoding=["\x27]([\w-]+)', caseSensitive: false)
                .firstMatch(latin1.decode(bytes.take(200).toList()))
                ?.group(1);
        final encoding = Encoding.getByName(declared ?? xmlEncoding ?? 'utf-8');
        if (encoding == null) throw const RssFailure('encoding');
        final body = encoding.decode(bytes);
        final parsed = parse(body, url);
        return await store.saveFeed(url, parsed,
            etag: response.headers['etag'],
            lastModified: response.headers['last-modified']);
      })()
          .timeout(const Duration(seconds: 25));
    } on RssFailure {
      rethrow;
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw const RssFailure('timeout');
    } on FormatException {
      throw const RssFailure('invalid_feed');
    } on http.ClientException {
      throw const RssFailure('network');
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  static ParsedRssFeed parse(String body, String feedUrl) {
    try {
      final doc = XmlDocument.parse(body);
      final root = doc.rootElement.name.local.toLowerCase();
      String title(String? value) {
        final text = rssPlainText(value ?? '').trim();
        return text.isEmpty ? Uri.parse(feedUrl).host : text;
      }

      RssEntry entry(
          {String? guid,
          String? title,
          String? url,
          String? author,
          String? content,
          String? date}) {
        final safeUrl = rssWebUrl(url, feedUrl);
        final heading = rssPlainText(title ?? '').trim();
        final name = heading.isEmpty ? (safeUrl ?? 'Untitled') : heading;
        final published = _date(date);
        return RssEntry(
            key: RssEntry.identity(
                guid: guid, url: safeUrl, title: name, publishedAt: published),
            title: name,
            url: safeUrl,
            author: author,
            contentHtml: content ?? '',
            publishedAt: published);
      }

      if (root == 'rss') {
        final f = RssFeed.parse(body);
        return ParsedRssFeed(
            title: title(f.title),
            siteUrl: rssWebUrl(f.link, feedUrl),
            entries: f.items
                .map((a) => entry(
                    guid: a.guid,
                    title: a.title,
                    url: a.link,
                    author: a.author ?? a.dc?.creator,
                    content: a.content?.value.trim().isNotEmpty == true
                        ? a.content!.value
                        : a.description,
                    date: a.pubDate ?? a.dc?.date))
                .toList());
      }
      if (root == 'feed') {
        final f = AtomFeed.parse(body);
        final elements = doc.rootElement.childElements
            .where((e) => e.name.local == 'entry')
            .toList();
        String? link(List<AtomLink> links) {
          for (final l in links) {
            if (l.rel == null || l.rel == 'alternate') return l.href;
          }
          return null;
        }

        return ParsedRssFeed(
            title: title(f.title),
            siteUrl: rssWebUrl(link(f.links), feedUrl),
            entries: List.generate(f.items.length, (i) {
              final a = f.items[i];
              String? content = a.content ?? a.summary;
              // Atom XHTML must keep its markup; plain text must remain literal.
              if (i < elements.length) {
                final bodies = elements[i]
                    .childElements
                    .where((e) => ['content', 'summary'].contains(e.name.local))
                    .toList();
                final element = bodies
                        .where((e) => e.name.local == 'content')
                        .firstOrNull ??
                    bodies.firstOrNull;
                if (element != null) {
                  final type = element.getAttribute('type') ?? 'text';
                  if (type == 'xhtml') {
                    content = element.innerXml;
                  } else if (type == 'text') {
                    content = const HtmlEscape().convert(element.innerText);
                  }
                }
              }
              return entry(
                  guid: a.id,
                  title: a.title,
                  url: link(a.links),
                  author: a.authors.isEmpty
                      ? null
                      : a.authors
                          .map((p) => p.name)
                          .whereType<String>()
                          .join(', '),
                  content: content,
                  date: a.published ?? a.updated);
            }));
      }
      if (root == 'rdf') {
        final f = Rss1Feed.parse(body);
        return ParsedRssFeed(
            title: title(f.title),
            siteUrl: rssWebUrl(f.link, feedUrl),
            entries: f.items
                .map((a) => entry(
                    title: a.title,
                    url: a.link,
                    author: a.dc?.creator,
                    content: a.content?.value ?? a.description,
                    date: a.dc?.date))
                .toList());
      }
      throw const RssFailure('invalid_feed');
    } on RssFailure {
      rethrow;
    } catch (_) {
      throw const RssFailure('invalid_feed');
    }
  }

  static int? _date(String? text) {
    if (text == null) return null;
    final iso = DateTime.tryParse(text.trim());
    if (iso != null) return iso.millisecondsSinceEpoch;
    final match = RegExp(
            r'(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s+([+-]\d{4}|GMT|UTC|UT|Z)',
            caseSensitive: false)
        .firstMatch(text);
    if (match == null) return null;
    const months = [
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec'
    ];
    final month = months.indexOf(match[2]!.toLowerCase()) + 1;
    if (month == 0) return null;
    final zone = match[7]!;
    var offset = 0;
    if (zone.startsWith('+') || zone.startsWith('-')) {
      offset = (int.parse(zone.substring(1, 3)) * 60 +
              int.parse(zone.substring(3, 5))) *
          (zone.startsWith('-') ? -1 : 1);
    }
    return DateTime.utc(
            int.parse(match[3]!),
            month,
            int.parse(match[1]!),
            int.parse(match[4]!),
            int.parse(match[5]!),
            int.parse(match[6] ?? '0'))
        .subtract(Duration(minutes: offset))
        .millisecondsSinceEpoch;
  }
}
