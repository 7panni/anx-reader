import 'dart:ui' show PointerDeviceKind;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/ai_chat_display_mode.dart';
import 'package:anx_reader/enums/ai_panel_position.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart' show navigatorKey;
import 'package:anx_reader/page/rss/rss_page.dart';
import 'package:anx_reader/service/rss/rss_service.dart';
import 'package:anx_reader/service/rss/rss_store.dart';
import 'package:anx_reader/widgets/ai/ai_chat_stream.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'rss_test.dart' as fixture;

class _Locale extends LocalizationsDelegate<L10n> {
  const _Locale(this.value);
  final L10n value;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<L10n> load(Locale locale) => SynchronousFuture(value);
  @override
  bool shouldReload(_Locale old) => false;
}

void main() {
  late RssStore store;
  late RssService service;
  late L10n locale;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    locale = await L10n.delegate.load(const Locale('en'));
    final db = await databaseFactoryFfiNoIsolate.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await RssStore.createSchema(db);
    store = RssStore(db);
    service = RssService(store,
        client: MockClient((r) async => http.Response(fixture.feed(), 200,
            headers: {'content-type': 'application/rss+xml; charset=utf-8'})));
  });
  tearDown(() async {
    service.close();
    await store.db.close();
  });

  Future<void> render(WidgetTester tester,
      {double width = 1300, double height = 900}) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('en'),
            localizationsDelegates: [
              _Locale(locale),
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate
            ],
            home: Scaffold(body: RssPage(store: store, service: service)))));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'Empty state can subscribe; article opens and refresh keeps one copy',
      (tester) async {
    await render(tester);
    expect(find.text('Add your first RSS feed'), findsOneWidget);
    await tester.tap(find.text('Add feed').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, fixture.url);
    await tester.tap(find.widgetWithText(FilledButton, 'Add feed').last);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('测试文章'), findsOneWidget);
    await tester.tap(find.text('测试文章'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(find.text('测试文章'), findsNWidgets(2));
    expect(find.text('Ask AI'), findsOneWidget);
    expect(
        (await tester.runAsync(() => store.articles()))!.single.isRead, isTrue);
    await tester.tap(find.byTooltip('Refresh feeds'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => store.articles()), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Narrow layout opens article, isolates its AI chat and goes back',
      (tester) async {
    await tester.runAsync(() => store.saveFeed(
        fixture.url, RssService.parse(fixture.feed(), fixture.url)));
    await render(tester, width: 440);
    await tester.tap(find.text('测试文章'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to articles'), findsOneWidget);
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    final chat = tester.widget<AiChatStream>(find.byType(AiChatStream));
    expect(chat.document?.article.title, '测试文章');
    expect(chat.document?.article.plainText, '完整正文');
    expect(find.text('Knowledge card'), findsOneWidget);
    expect(find.textContaining('This article is attached'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to articles'));
    await tester.pumpAndSettle();
    expect(find.text('测试文章'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Desktop AI stays beside the article, resizes and keeps its draft when reopened',
      (tester) async {
    await tester.runAsync(() => store.saveFeed(
        fixture.url, RssService.parse(fixture.feed(), fixture.url)));
    await render(tester);
    await tester.tap(find.text('测试文章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    final panel = find.byKey(const ValueKey('rss-ai-panel'));
    final reader = find.byType(SelectionArea).first;
    expect(tester.getRect(reader).right,
        lessThanOrEqualTo(tester.getRect(panel).left));
    expect(tester.getSize(panel).width, 300);
    final chat = tester.state<AiChatStreamState>(find.byType(AiChatStream));
    chat.inputController.text = 'my question draft';
    await tester.drag(
        find.byKey(const ValueKey('rss-ai-resize')), const Offset(-45, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, greaterThan(300));
    expect(Prefs().aiPanelWidth, greaterThan(300));
    await tester.tap(find.byKey(const ValueKey('rss-ai-close')));
    await tester.pumpAndSettle();
    expect(find.byType(AiChatStream), findsNothing);
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    expect(
        tester
            .state<AiChatStreamState>(find.byType(AiChatStream))
            .inputController
            .text,
        'my question draft');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Desktop AI can move below the article using the shared position setting',
      (tester) async {
    await tester.runAsync(() => store.saveFeed(
        fixture.url, RssService.parse(fixture.feed(), fixture.url)));
    await render(tester);
    await tester.tap(find.text('测试文章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(locale.aiShowAtBottom));
    await tester.pumpAndSettle();
    expect(Prefs().aiPanelPosition, AiPanelPositionEnum.bottom);
    final panel = find.byKey(const ValueKey('rss-ai-panel'));
    final reader = find.byType(SelectionArea).first;
    expect(tester.getRect(reader).bottom,
        lessThanOrEqualTo(tester.getRect(panel).top));
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('RSS selection AI fills the selected text without submitting it',
      (tester) async {
    await tester.runAsync(() => store.saveFeed(
        fixture.url,
        RssService.parse(
            fixture.feed(text: '<p>alpha beta gamma delta</p>'), fixture.url)));
    await render(tester);
    await tester.tap(find.text('测试文章'));
    await tester.pumpAndSettle();
    final paragraph = find.byWidgetPredicate((w) =>
        w is RichText &&
        w.maxLines == null &&
        w.text.toPlainText().trim() == 'alpha beta gamma delta');
    expect(paragraph, findsOneWidget);
    final rect = tester.getRect(paragraph);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    final start = rect.topLeft + const Offset(1, 8);
    await gesture.addPointer(location: start);
    await gesture.down(start);
    await gesture.moveTo(rect.topRight + const Offset(-1, 8));
    await gesture.up();
    await tester.pumpAndSettle();
    // Desktop mouse selections use the secondary-click selection toolbar.
    await tester.tapAt(rect.centerLeft + const Offset(10, 0),
        buttons: 2, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text(locale.navBarAI), findsOneWidget);
    await tester.tap(find.text(locale.navBarAI));
    await tester.pumpAndSettle();
    final chat = tester.state<AiChatStreamState>(find.byType(AiChatStream));
    expect(chat.inputController.text, contains('alpha beta'));
    expect(tester.widget<AiChatStream>(find.byType(AiChatStream)).sendImmediate,
        isFalse);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
    await gesture.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Explicit popup preference still uses the book reader bottom sheet',
      (tester) async {
    Prefs().aiChatDisplayMode = AiChatDisplayMode.popup;
    await tester.runAsync(() => store.saveFeed(
        fixture.url, RssService.parse(fixture.feed(), fixture.url)));
    await render(tester);
    await tester.tap(find.text('测试文章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('rss-ai-panel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rss-ai-close')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Switching RSS articles closes the panel and replaces its context',
      (tester) async {
    final xml = fixture.feed().replaceFirst('</channel>',
        '<item><guid>two</guid><title>Second article</title><link>/articles/two</link><description>Second body</description></item></channel>');
    await tester.runAsync(
        () => store.saveFeed(fixture.url, RssService.parse(xml, fixture.url)));
    await render(tester);
    await tester.tap(find.text('测试文章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    tester
        .state<AiChatStreamState>(find.byType(AiChatStream))
        .inputController
        .text = 'old draft';
    await tester.tap(find.text('Second article'));
    await tester.pumpAndSettle();
    expect(find.byType(AiChatStream), findsNothing);
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<AiChatStream>(find.byType(AiChatStream))
            .document
            ?.article
            .title,
        'Second article');
    expect(
        tester
            .state<AiChatStreamState>(find.byType(AiChatStream))
            .inputController
            .text,
        isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Compact desktop keeps the article visible beside and above AI',
      (tester) async {
    await tester.runAsync(() => store.saveFeed(
        fixture.url, RssService.parse(fixture.feed(), fixture.url)));
    await render(tester, width: 680, height: 640);
    await tester.tap(find.text('测试文章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask AI'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip(locale.aiShowAtBottom));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final panel = find.byKey(const ValueKey('rss-ai-panel'));
    expect(tester.getRect(find.byType(SelectionArea).first).bottom,
        lessThanOrEqualTo(tester.getRect(panel).top));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
