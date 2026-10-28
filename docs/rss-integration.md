# Native RSS integration

RSS appears between Bookshelf and Statistics. The native Flutter page supports
adding an RSS/Atom feed URL, manual refresh, per-feed refresh and unsubscribe,
local search, unread/star filters, reading the feed-supplied HTML, read/star
flags, and opening the original URL. Open an article and choose Ask AI to start
an article-scoped conversation, with Summarize and Knowledge card shortcuts.
The conversation uses the existing selected AI provider. Opening the panel does
not send content; submitting a question or shortcut sends the attached text.

The article AI uses the book reader's display-mode, panel-position and size
preferences. On desktop it opens beside the article by default, can move below
it, and can be resized. Narrow adaptive layouts or an explicit popup preference
use the same bottom sheet as book reading. Selecting text and choosing AI fills
the input without sending it. Closing and reopening the same article's panel
retains its conversation and draft; switching articles starts a separate context.

## Storage and refresh

`rss.db` is version 1 in the application's databases directory. It is independent
of `app_database.db`: no book-library schema migration, and no WebDAV/book-sync
integration is added. Feeds and articles remain available offline after a
successful fetch. Refresh uses ETag/Last-Modified validators and transactions;
it updates article content without replacing user read/star flags. Within each
feed, GUID/Atom ID is the primary identity, URL is a second identity, and a
hash of title and publication date is the fallback. Failed refresh preserves
cached articles. Unsubscribe explicitly confirms removal of that feed's local
articles and flags. There is no automatic pruning of old articles.

Feed HTML is retained in storage; rendering strips active/embed/form content
and event/style attributes, resolves relative links/images and allows HTTP(S)
URLs only. The HTML renderer does not execute website JavaScript.

## AI context

`RssDocument` attaches a self-contained, explicitly untrusted article payload
once per conversation. Each article panel uses a scoped `AiChat` provider, so
it does not overwrite the main book chat. The context is saved with existing
AI history, including source URL and whether text was truncated; reloaded RSS
conversations continue without the book agent/tool context. The normal book
assistant path is unchanged. Attachments above 60,000 characters are truncated
with a visible notice. All processing uses the existing provider; no new model
service, API key, subscription or Papr process is required.

Built-in reading templates, assistant system guidance and RSS summary/card
prompts are written in Chinese. Language variables, translation targets and
tool names remain intact. Custom saved prompts retain priority; saved original
English defaults are recognized exactly and resolve to the new Chinese defaults
without rewriting preferences. Tool protocol identifiers and schemas are unchanged.

## Scope

This version reads feed-supplied content. It does not fetch full article pages,
auto-discover feeds from website homepages, import/export OPML, run background
refresh jobs, sync RSS between devices, or install/modify Papr. macOS was built
and exercised; other native targets have not been built for this feature.

## Adopted dependencies

- `rss_dart` **1.0.14**, source: <https://pub.dev/packages/rss_dart>, repository:
  <https://github.com/ubuntu-flutter-community/rss.dart>. MIT, copyright 2018
  Wito Chandra. Used as an unmodified linked Dart package, included in compiled
  builds. Original notice: [MIT license](licenses/rss_dart-1.0.14-MIT.txt).
  Archive SHA-256:
  `09c0123427e9557d74562e07f9d22effe3fd493893602e8a8d24b961490f2c30`.
- `xml` **6.5.0** was already resolved by this app and is now declared directly
  for root-element detection and preserving Atom XHTML. Its version is unchanged.
- Existing HTTP, HTML, SQLite, crypto, intl, Flutter UI and AI components are reused.
  The lockfile adds only rss_dart and changes xml's dependency classification.

RSS metadata/body parsing uses the package's public interfaces; Atom XHTML is
preserved from the feed XML rather than flattened. The Anx page, local data
schema, refresh orchestration and tests are project-specific implementation.
No third-party RSS application source/UI has been copied. Flutter's generated
license registry includes the package notices.
