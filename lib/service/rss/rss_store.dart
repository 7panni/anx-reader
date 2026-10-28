import 'dart:io';

import 'package:anx_reader/utils/get_path/databases_path.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'rss_models.dart';

/// RSS uses its own database; adding this feature does not migrate the book
/// library. The RSS database is local and isn't part of book/WebDAV sync.
class RssStore {
  RssStore(this.db);
  final Database db;
  static Future<RssStore>? _instance;
  static Future<RssStore> get instance =>
      _instance ??= _open().catchError((Object error, StackTrace stack) {
        _instance = null;
        Error.throwWithStackTrace(error, stack);
      });

  static Future<RssStore> _open() async {
    final directory = await getAnxDataBasesPath();
    await Directory(directory).create(recursive: true);
    if (AnxPlatform.isWindows || AnxPlatform.isIOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    return RssStore(await openDatabase(p.join(directory, 'rss.db'),
        version: 1,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) => createSchema(db)));
  }

  static Future<void> createSchema(Database db) async {
    await db.execute('''CREATE TABLE rss_feeds (
      id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE,
      title TEXT NOT NULL, site_url TEXT, etag TEXT, last_modified TEXT,
      refreshed_at INTEGER, error TEXT)''');
    await db.execute('''CREATE TABLE rss_articles (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      feed_id INTEGER NOT NULL REFERENCES rss_feeds(id) ON DELETE CASCADE,
      item_key TEXT NOT NULL, title TEXT NOT NULL, url TEXT, author TEXT,
      content_html TEXT NOT NULL, published_at INTEGER, fetched_at INTEGER NOT NULL,
      is_read INTEGER NOT NULL DEFAULT 0, starred INTEGER NOT NULL DEFAULT 0,
      UNIQUE(feed_id, item_key))''');
    await db.execute(
        'CREATE INDEX rss_article_order ON rss_articles(feed_id, published_at DESC)');
    await db
        .execute('CREATE INDEX rss_article_url ON rss_articles(feed_id, url)');
  }

  Future<List<RssSubscription>> subscriptions() async => (await db.rawQuery('''
    SELECT f.*, (SELECT count(*) FROM rss_articles a
      WHERE a.feed_id=f.id AND a.is_read=0) AS unread FROM rss_feeds f
    ORDER BY f.id''')).map(RssSubscription.fromRow).toList();

  Future<RssSubscription?> findFeed(String url) async {
    final rows = await db.query('rss_feeds', where: 'url=?', whereArgs: [url]);
    return rows.isEmpty ? null : RssSubscription.fromRow(rows.first);
  }

  Future<List<RssEntry>> articles(
      {int? feedId,
      bool unreadOnly = false,
      bool starredOnly = false,
      String search = ''}) async {
    final conditions = <String>[];
    final args = <Object?>[];
    if (feedId != null) {
      conditions.add('a.feed_id=?');
      args.add(feedId);
    }
    if (unreadOnly) conditions.add('a.is_read=0');
    if (starredOnly) conditions.add('a.starred=1');
    if (search.trim().isNotEmpty) {
      conditions.add(
          '(a.title LIKE ? ESCAPE \'\\\' OR a.content_html LIKE ? ESCAPE \'\\\')');
      final term = search
          .trim()
          .replaceAll('\\', '\\\\')
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      args.addAll(['%$term%', '%$term%']);
    }
    return (await db.rawQuery('''SELECT a.*, f.title AS feed_title
      FROM rss_articles a JOIN rss_feeds f ON a.feed_id=f.id
      ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
      ORDER BY coalesce(a.published_at,a.fetched_at) DESC, a.id DESC''', args))
        .map(RssEntry.fromRow)
        .toList();
  }

  Future<RssEntry?> article(int id) async {
    final rows = await db.rawQuery('''SELECT a.*, f.title AS feed_title
      FROM rss_articles a JOIN rss_feeds f ON f.id=a.feed_id WHERE a.id=?''',
        [id]);
    return rows.isEmpty ? null : RssEntry.fromRow(rows.first);
  }

  /// A refresh updates content in place, retaining IDs and user read/star flags.
  /// URL is a second identity so a publisher changing GUIDs doesn't duplicate it.
  Future<int> saveFeed(String url, ParsedRssFeed feed,
          {String? etag, String? lastModified}) =>
      db.transaction((txn) async {
        final now = DateTime.now().millisecondsSinceEpoch;
        await txn.insert('rss_feeds', {'url': url, 'title': feed.title},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        final id = (await txn.query('rss_feeds',
                columns: ['id'], where: 'url=?', whereArgs: [url]))
            .single['id'] as int;
        await txn.update(
            'rss_feeds',
            {
              'title': feed.title,
              'site_url': feed.siteUrl,
              'etag': etag,
              'last_modified': lastModified,
              'refreshed_at': now,
              'error': null
            },
            where: 'id=?',
            whereArgs: [id]);
        var added = 0;
        for (final entry in feed.entries) {
          final old = await txn.query('rss_articles',
              columns: ['id'],
              where:
                  'feed_id=? AND (item_key=? OR (url IS NOT NULL AND url=?))',
              whereArgs: [id, entry.key, entry.url],
              limit: 1);
          final values = <String, Object?>{
            'title': entry.title,
            'url': entry.url,
            'author': entry.author,
            'published_at': entry.publishedAt
          };
          if (entry.contentHtml.trim().isNotEmpty || old.isEmpty) {
            values['content_html'] = entry.contentHtml;
          }
          if (old.isEmpty) {
            await txn.insert('rss_articles', {
              ...values,
              'feed_id': id,
              'item_key': entry.key,
              'fetched_at': now
            });
            added++;
          } else {
            await txn.update('rss_articles', values,
                where: 'id=?', whereArgs: [old.first['id']]);
          }
        }
        return added;
      });

  Future<void> checked(int id) async {
    await db.update('rss_feeds',
        {'refreshed_at': DateTime.now().millisecondsSinceEpoch, 'error': null},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> failed(int id, String error) async {
    await db.update('rss_feeds', {'error': error},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> setRead(int id, bool read) async {
    await db.update('rss_articles', {'is_read': read ? 1 : 0},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> setStarred(int id, bool starred) async {
    await db.update('rss_articles', {'starred': starred ? 1 : 0},
        where: 'id=?', whereArgs: [id]);
  }

  Future<void> unsubscribe(int id) async {
    await db.transaction((txn) async {
      await txn.delete('rss_articles', where: 'feed_id=?', whereArgs: [id]);
      await txn.delete('rss_feeds', where: 'id=?', whereArgs: [id]);
    });
  }
}
