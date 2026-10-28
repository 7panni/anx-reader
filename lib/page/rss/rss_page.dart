import 'dart:async';
import 'dart:math' as math;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/ai_chat_display_mode.dart';
import 'package:anx_reader/enums/ai_panel_position.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/ai_quick_prompt_chip.dart';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:anx_reader/service/rss/rss_document.dart';
import 'package:anx_reader/service/rss/rss_html.dart';
import 'package:anx_reader/service/rss/rss_models.dart';
import 'package:anx_reader/service/rss/rss_service.dart';
import 'package:anx_reader/service/rss/rss_store.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/widgets/ai/ai_chat_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'rss_strings.dart';

class RssPage extends StatefulWidget {
  const RssPage({super.key, this.controller, this.store, this.service});
  final ScrollController? controller;
  final RssStore? store;
  final RssService? service;
  @override
  State<RssPage> createState() => _RssPageState();
}

class _RssPageState extends State<RssPage> {
  RssStore? _store;
  RssService? _service;
  List<RssSubscription> _feeds = [];
  List<RssEntry> _articles = [];
  RssEntry? _selected;
  int? _feedId;
  bool _unread = false;
  bool _starred = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _loadVersion = 0;
  final _search = TextEditingController();
  Timer? _searchDebounce;
  bool _aiOpen = false;
  bool _aiPopupOpen = false;
  RssDocument? _aiDocument;
  ProviderContainer? _aiScope;
  GlobalKey<AiChatStreamState> _aiChatKey = GlobalKey<AiChatStreamState>();
  String? _aiDraft;
  String? _selectionText;
  late double _aiWidth;
  late double _aiHeight;

  @override
  void initState() {
    super.initState();
    _aiWidth = Prefs().aiPanelWidth;
    _aiHeight = Prefs().aiPanelHeight;
    _search.addListener(() {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 250), _load);
    });
    _initialize();
  }

  @override
  void dispose() {
    _loadVersion++;
    _searchDebounce?.cancel();
    _search.dispose();
    if (widget.service == null) _service?.close();
    final scope = _aiScope;
    WidgetsBinding.instance.addPostFrameCallback((_) => scope?.dispose());
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      _store = widget.store ?? await RssStore.instance;
      if (!mounted) return;
      _service = widget.service ?? RssService(_store!);
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = RssStrings(context).loadFailed;
        });
      }
    }
  }

  Future<void> _load() async {
    if (_store == null) return;
    final version = ++_loadVersion;
    try {
      final feeds = await _store!.subscriptions();
      final articles = await _store!.articles(
          feedId: _feedId,
          unreadOnly: _unread,
          starredOnly: _starred,
          search: _search.text);
      final selected =
          _selected?.id == null ? null : await _store!.article(_selected!.id!);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _feeds = feeds;
        _articles = articles;
        _selected = selected;
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (mounted && version == _loadVersion) {
        setState(() {
          _loading = false;
          _error = RssStrings(context).loadFailed;
        });
      }
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _failure(Object error) {
    final l = RssStrings(context);
    if (error is! RssFailure) {
      return l.zh
          ? '操作失败，请重试。已保存的数据未清除。'
          : 'Operation failed. Saved data was kept; please retry.';
    }
    final messages = {
      'invalid_url': l.invalidAddress,
      'duplicate': l.alreadyAdded,
      'invalid_feed': l.zh
          ? '地址未返回有效的 RSS 或 Atom 内容，请检查订阅地址。'
          : 'The URL did not return a valid RSS or Atom feed.',
      'network': l.zh
          ? '无法连接订阅源，请检查网络后重试。'
          : 'Could not connect to the feed. Check your connection.',
      'timeout':
          l.zh ? '订阅源响应超时，请稍后重试。' : 'The feed timed out. Try again later.',
      'http': l.zh
          ? '订阅源返回错误（HTTP ${error.status}）。'
          : 'The feed returned HTTP ${error.status}.',
      'too_large': l.zh ? '订阅内容过大，暂时无法读取。' : 'This feed is too large to load.',
      'encoding': l.zh
          ? '暂不支持此订阅的文字编码。'
          : 'This feed uses an unsupported text encoding.',
    };
    return messages[error.code] ?? l.errorHint;
  }

  Future<void> _add() async {
    final l = RssStrings(context);
    final input = await showDialog<String>(
        context: context, builder: (_) => const _AddFeedDialog());
    if (!mounted || input == null) return;
    await _run(() async {
      final added = await _service!.subscribe(input.trim());
      final feed =
          await _store!.findFeed(RssService.normalizeUrl(input.trim()));
      if (mounted) {
        setState(() {
          _feedId = feed?.id;
          _unread = false;
          _starred = false;
          _selected = null;
          _resetAi();
          _search.clear();
        });
      }
      _notify(l.refreshResult(added, 0));
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || _store == null) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _notify(_failure(error));
    } finally {
      if (mounted) {
        await _load();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _refresh([RssSubscription? single]) => _run(() async {
        var count = 0;
        var errors = 0;
        for (final feed in single == null ? _feeds : [single]) {
          if (!mounted) break;
          try {
            count += await _service!.refresh(feed);
          } catch (_) {
            errors++;
          }
        }
        if (mounted) _notify(RssStrings(context).refreshResult(count, errors));
      });

  Future<void> _unsubscribe(RssSubscription feed) async {
    final l = RssStrings(context);
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(l.unsubscribe),
                content: Text(l.removeMessage(feed.title)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(l.cancel)),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(l.unsubscribe))
                ]));
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await _store!.unsubscribe(feed.id);
      if (!mounted) return;
      setState(() {
        if (_feedId == feed.id) _feedId = null;
        if (_selected?.feedId == feed.id) {
          _selected = null;
          _resetAi();
        }
      });
    });
  }

  Future<void> _select(RssEntry article) async {
    setState(() {
      if (_selected?.id != article.id) _resetAi();
      _selected = article;
    });
    try {
      await _store!.setRead(article.id!, true);
      await _load();
    } catch (error) {
      if (mounted) _notify(_failure(error));
    }
  }

  void _filter({int? feedId, bool unread = false, bool starred = false}) {
    setState(() {
      _feedId = feedId;
      _unread = unread;
      _starred = starred;
      _selected = null;
      _resetAi();
    });
    _load();
  }

  Future<void> _openUrl(String value) async {
    final safe = rssWebUrl(value);
    if (safe == null) return;
    try {
      if (!await launchUrl(Uri.parse(safe),
          mode: LaunchMode.externalApplication)) {
        throw const RssFailure('network');
      }
    } catch (error) {
      if (mounted) _notify(_failure(error));
    }
  }

  void _resetAi() {
    final previous = _aiScope;
    _aiScope = null;
    _aiDocument = null;
    _aiOpen = false;
    _aiDraft = null;
    _selectionText = null;
    _aiChatKey = GlobalKey<AiChatStreamState>();
    WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
  }

  void _closeAi() {
    _aiDraft = _aiChatKey.currentState?.inputController.text ?? _aiDraft;
    setState(() => _aiOpen = false);
  }

  Future<void> _ask(RssEntry article, {String? selection}) async {
    if (_aiPopupOpen) return;
    final text = selection?.trim();
    setState(() {
      if (_aiDocument?.article.id != article.id) {
        _resetAi();
        _aiDocument = RssDocument(article);
        _aiScope = ProviderContainer(
          parent: ProviderScope.containerOf(context, listen: false),
          overrides: [aiChatProvider.overrideWith(AiChat.new)],
        );
      }
      if (text != null && text.isNotEmpty) _aiDraft = text;
      _aiOpen = true;
    });
    // As in the book reader, a selection is a draft, never an automatic request.
    if (text != null && text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _aiChatKey.currentState?.inputController.text = text;
      });
    }
    final mode = Prefs().aiChatDisplayMode;
    final popup = mode == AiChatDisplayMode.popup ||
        (mode == AiChatDisplayMode.adaptive &&
            MediaQuery.sizeOf(context).width < 600);
    if (!popup) return;
    setState(() => _aiPopupOpen = true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      clipBehavior: Clip.hardEdge,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * .8,
        child: _buildAiChat(onClose: () => Navigator.pop(ctx), popup: true),
      ),
    );
    if (!mounted) return;
    _aiDraft = _aiChatKey.currentState?.inputController.text ?? _aiDraft;
    setState(() {
      _aiPopupOpen = false;
      _aiOpen = false;
    });
  }

  Widget _buildAiChat({required VoidCallback onClose, bool popup = false}) {
    final l = RssStrings(context);
    final document = _aiDocument!;
    return UncontrolledProviderScope(
      container: _aiScope!,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text(
              document.truncated
                  ? '${l.aiContext}\n${l.truncated}'
                  : l.aiContext,
              style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
            child: AiChatStream(
          key: _aiChatKey,
          document: document,
          initialMessage: _aiDraft,
          quickPromptChips: [
            AiQuickPromptChip(
                label: l.summary,
                prompt: l.summaryPrompt,
                icon: Icons.short_text),
            AiQuickPromptChip(
                label: l.card,
                prompt: l.cardPrompt,
                icon: Icons.note_alt_outlined),
          ],
          trailing: [
            if (!popup)
              IconButton(
                tooltip: Prefs().aiPanelPosition == AiPanelPositionEnum.right
                    ? L10n.of(context).aiShowAtBottom
                    : L10n.of(context).aiShowAtRight,
                icon: Icon(Prefs().aiPanelPosition == AiPanelPositionEnum.right
                    ? Icons.arrow_downward
                    : Icons.arrow_forward),
                onPressed: () => setState(() {
                  Prefs().aiPanelPosition =
                      Prefs().aiPanelPosition == AiPanelPositionEnum.right
                          ? AiPanelPositionEnum.bottom
                          : AiPanelPositionEnum.right;
                }),
              ),
            IconButton(
                key: const ValueKey('rss-ai-close'),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: onClose,
                icon: const Icon(Icons.close)),
          ],
        )),
      ]),
    );
  }

  Widget _readingLayout(BoxConstraints bounds, RssStrings l) {
    if (!_aiOpen || _aiPopupOpen || _aiDocument == null) {
      return _library(bounds.maxWidth, l);
    }
    // Use the book reader's position and size preferences. A narrow forced
    // split uses a bottom panel so the article remains readable.
    final right = Prefs().aiPanelPosition == AiPanelPositionEnum.right &&
        bounds.maxWidth >= 600;
    final maxSize = right
        ? math.max(240.0, math.min(bounds.maxWidth * .6, bounds.maxWidth - 320))
        : math.max(
            200.0, math.min(bounds.maxHeight * .6, bounds.maxHeight - 240));
    final size = right
        ? _aiWidth.clamp(240.0, maxSize)
        : _aiHeight.clamp(200.0, maxSize);
    final divider = MouseRegion(
      cursor: right
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        key: const ValueKey('rss-ai-resize'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: right
            ? (details) => setState(() {
                  _aiWidth = (size - details.delta.dx).clamp(240.0, maxSize);
                })
            : null,
        onVerticalDragUpdate: right
            ? null
            : (details) => setState(() {
                  _aiHeight = (size - details.delta.dy).clamp(200.0, maxSize);
                }),
        onHorizontalDragEnd:
            right ? (_) => Prefs().aiPanelWidth = _aiWidth : null,
        onVerticalDragEnd:
            right ? null : (_) => Prefs().aiPanelHeight = _aiHeight,
        child: SizedBox(
            width: right ? 10 : null,
            height: right ? null : 10,
            child: Center(
                child: Container(
                    width: right ? 2 : 40,
                    height: right ? 40 : 2,
                    color: Theme.of(context).colorScheme.outlineVariant))),
      ),
    );
    final chat = SizedBox(
        key: const ValueKey('rss-ai-panel'),
        width: right ? size : null,
        height: right ? null : size,
        child: _buildAiChat(onClose: _closeAi));
    return Flex(
        direction: right ? Axis.horizontal : Axis.vertical,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
              child: LayoutBuilder(
                  builder: (_, libraryBounds) =>
                      _library(libraryBounds.maxWidth, l))),
          divider,
          chat,
        ]);
  }

  Widget _library(double width, RssStrings l) {
    final wide = width >= 1000;
    final split = width >= 720;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (wide) ...[
        SizedBox(width: 205, child: _feedList(l)),
        const VerticalDivider(width: 1)
      ],
      if (split || _selected == null)
        SizedBox(
            width: split ? 290 : width,
            child: _articleList(l, showFeeds: !wide)),
      if (split) const VerticalDivider(width: 1),
      if (split || _selected != null)
        Expanded(
            child: _selected == null
                ? Center(child: Text(l.select))
                : _reader(l, back: !split)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l = RssStrings(context);
    return SafeArea(
        child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 16, 16),
            child: Column(children: [
              Row(children: [
                const SizedBox(width: 8),
                Expanded(
                    child: Text('RSS',
                        style: Theme.of(context).textTheme.headlineSmall)),
                if (_feeds.isNotEmpty)
                  IconButton(
                      tooltip: l.refresh,
                      onPressed: _busy ? null : () => _refresh(),
                      icon: const Icon(Icons.refresh)),
                FilledButton.icon(
                    onPressed: _busy || _store == null ? null : _add,
                    icon: const Icon(Icons.add),
                    label: Text(l.add)),
              ]),
              const SizedBox(height: 12),
              if (_busy || _loading)
                const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                MaterialBanner(content: Text(_error!), actions: [
                  TextButton(onPressed: _initialize, child: Text(l.retry))
                ]),
              Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _feeds.isEmpty
                          ? _emptyFeeds(l)
                          : LayoutBuilder(
                              builder: (_, bounds) =>
                                  _readingLayout(bounds, l))),
            ])));
  }

  Widget _emptyFeeds(RssStrings l) => Center(
      child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.rss_feed,
                size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(l.noFeeds, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(l.feedHint, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            OutlinedButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.add),
                label: Text(l.add))
          ])));

  Widget _feedList(RssStrings l) => ListView(children: [
        ListTile(
            leading: const Icon(Icons.inbox_outlined),
            title: Text(l.all),
            selected: _feedId == null && !_unread && !_starred,
            onTap: () => _filter()),
        ListTile(
            leading: const Icon(Icons.mark_email_unread_outlined),
            title: Text(l.unread),
            trailing: Text('${_feeds.fold(0, (int n, f) => n + f.unread)}'),
            selected: _feedId == null && _unread,
            onTap: () => _filter(unread: true)),
        ListTile(
            leading: const Icon(Icons.star_border),
            title: Text(l.starred),
            selected: _feedId == null && _starred,
            onTap: () => _filter(starred: true)),
        const Divider(),
        Padding(
            padding: const EdgeInsets.all(16), child: Text(l.subscriptions)),
        for (final feed in _feeds)
          ListTile(
              dense: true,
              selected: _feedId == feed.id,
              onTap: () => _filter(feedId: feed.id),
              title: Text(feed.title,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: feed.error == null
                  ? null
                  : Tooltip(
                      message: l.errorHint,
                      child: Icon(Icons.error_outline,
                          size: 16,
                          color: Theme.of(context).colorScheme.error)),
              trailing: Text('${feed.unread}')),
      ]);

  Widget _articleList(RssStrings l, {required bool showFeeds}) {
    final feed = _feeds.where((f) => f.id == _feedId).firstOrNull;
    return Column(children: [
      if (showFeeds)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButton<int>(
                isExpanded: true,
                value: _feedId ?? -1,
                items: [
                  DropdownMenuItem(value: -1, child: Text(l.all)),
                  for (final f in _feeds)
                    DropdownMenuItem(
                        value: f.id,
                        child: Text(f.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis))
                ],
                onChanged: (id) => _filter(feedId: id == -1 ? null : id))),
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Row(children: [
            Expanded(
                child: Text(
                    feed?.title ??
                        (_unread
                            ? l.unread
                            : _starred
                                ? l.starred
                                : l.all),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall)),
            if (feed != null)
              PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: (value) =>
                      value == 'refresh' ? _refresh(feed) : _unsubscribe(feed),
                  itemBuilder: (_) => [
                        PopupMenuItem(
                            value: 'refresh', child: Text(l.refreshOne)),
                        PopupMenuItem(
                            value: 'unsubscribe', child: Text(l.unsubscribe))
                      ]),
          ])),
      if (feed?.error != null)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(l.errorHint,
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
              controller: _search,
              decoration: InputDecoration(
                  isDense: true,
                  hintText: l.search,
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder()))),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            FilterChip(
                label: Text(l.unread),
                selected: _unread,
                onSelected: (v) {
                  setState(() => _unread = v);
                  _load();
                }),
            const SizedBox(width: 6),
            FilterChip(
                label: Text(l.starred),
                selected: _starred,
                onSelected: (v) {
                  setState(() => _starred = v);
                  _load();
                }),
          ])),
      Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(l.articleCount(_articles.length),
              style: Theme.of(context).textTheme.bodySmall)),
      Expanded(
          child: _articles.isEmpty
              ? Center(child: Text(l.empty))
              : ListView.separated(
                  controller: widget.controller,
                  itemCount: _articles.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final a = _articles[index];
                    final preview = a.plainText.replaceAll(RegExp(r'\s+'), ' ');
                    final snippet = preview.length > 160
                        ? '${preview.substring(0, 160)}…'
                        : preview;
                    return ListTile(
                        selected: _selected?.id == a.id,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        title: Text(a.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontWeight: a.isRead
                                    ? FontWeight.normal
                                    : FontWeight.w600)),
                        subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text('${a.feedTitle} · ${_date(a, l)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      Theme.of(context).textTheme.labelSmall),
                              if (snippet.isNotEmpty)
                                Text(snippet,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                            ]),
                        trailing:
                            a.starred ? const Icon(Icons.star, size: 16) : null,
                        onTap: () => _select(a));
                  })),
    ]);
  }

  String _date(RssEntry a, RssStrings l) => a.publishedAt == null
      ? l.unknownDate
      : DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
          .format(DateTime.fromMillisecondsSinceEpoch(a.publishedAt!));

  Widget _reader(RssStrings l, {required bool back}) {
    final a = _selected!;
    final colors = Theme.of(context).colorScheme;
    return Column(children: [
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (back)
                  IconButton(
                      tooltip: l.back,
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() {
                            _selected = null;
                            _resetAi();
                          })),
                IconButton(
                    tooltip: a.isRead ? l.markUnread : l.read,
                    onPressed: _busy
                        ? null
                        : () => _run(() => _store!.setRead(a.id!, !a.isRead)),
                    icon: Icon(a.isRead
                        ? Icons.mark_email_unread_outlined
                        : Icons.mark_email_read_outlined)),
                IconButton(
                    tooltip: a.starred ? l.unstar : l.star,
                    onPressed: _busy
                        ? null
                        : () =>
                            _run(() => _store!.setStarred(a.id!, !a.starred)),
                    icon: Icon(a.starred ? Icons.star : Icons.star_border)),
                IconButton(
                    tooltip: l.original,
                    onPressed: a.url == null ? null : () => _openUrl(a.url!),
                    icon: const Icon(Icons.open_in_new)),
                FilledButton.tonalIcon(
                    onPressed: a.plainText.isEmpty || !EnvVar.enableAIFeature
                        ? null
                        : () => _ask(a),
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(l.ask)),
              ])),
      const Divider(height: 1),
      Expanded(
          child: SelectionArea(
              key: ValueKey('rss-selection-${a.id}'),
              onSelectionChanged: (selection) =>
                  _selectionText = selection?.plainText,
              contextMenuBuilder: (context, region) =>
                  AdaptiveTextSelectionToolbar.buttonItems(
                    anchors: region.contextMenuAnchors,
                    buttonItems: [
                      ...region.contextMenuButtonItems,
                      if (EnvVar.enableAIFeature)
                        ContextMenuButtonItem(
                          label: L10n.of(context).navBarAI,
                          onPressed: () {
                            final quote = _selectionText;
                            region.hideToolbar();
                            if (quote?.trim().isNotEmpty == true) {
                              _ask(a, selection: quote);
                            }
                          },
                        ),
                    ],
                  ),
              child: SingleChildScrollView(
                  key: ValueKey(a.id),
                  padding: const EdgeInsets.all(24),
                  child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 760),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(a.title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall),
                                const SizedBox(height: 12),
                                Text(
                                    [
                                      a.feedTitle,
                                      if (a.author?.isNotEmpty == true)
                                        a.author!,
                                      _date(a, l),
                                    ].join(' · '),
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                                const SizedBox(height: 8),
                                Text(l.bodyHint,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: colors.onSurfaceVariant)),
                                const SizedBox(height: 20),
                                if (a.plainText.isEmpty)
                                  Text(l.noBody)
                                else
                                  Html(
                                      data:
                                          rssDisplayHtml(a.contentHtml, a.url),
                                      style: {
                                        'body': Style(
                                            margin: Margins.zero,
                                            fontSize: FontSize(17),
                                            lineHeight: const LineHeight(1.65),
                                            color: colors.onSurface),
                                        'a': Style(color: colors.primary),
                                        'pre': Style(
                                            whiteSpace: WhiteSpace.pre,
                                            backgroundColor:
                                                colors.surfaceContainer),
                                      },
                                      onLinkTap: (url, _, __) {
                                        if (url != null) _openUrl(url);
                                      }),
                              ]))))))
    ]);
  }
}

class _AddFeedDialog extends StatefulWidget {
  const _AddFeedDialog();
  @override
  State<_AddFeedDialog> createState() => _AddFeedDialogState();
}

class _AddFeedDialogState extends State<_AddFeedDialog> {
  final _controller = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final url = RssService.normalizeUrl(_controller.text.trim());
      Navigator.pop(context, url);
    } on RssFailure {
      setState(() => _error = RssStrings(context).invalidAddress);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = RssStrings(context);
    return AlertDialog(
        title: Text(l.add),
        content: SizedBox(
            width: 440,
            child: TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                    labelText: l.feedAddress,
                    hintText: 'https://example.org/feed.xml',
                    errorText: _error),
                onSubmitted: (_) => _submit())),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          FilledButton(onPressed: _submit, child: Text(l.add))
        ]);
  }
}
