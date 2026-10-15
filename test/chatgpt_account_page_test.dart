import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/page/settings_page/chatgpt_account_page.dart';
import 'package:anx_reader/service/chatgpt/desktop_chatgpt.dart';
import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Store implements CredentialStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class _LoadedLocale extends LocalizationsDelegate<L10n> {
  const _LoadedLocale(this.value);
  final L10n value;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<L10n> load(Locale locale) => SynchronousFuture(value);
  @override
  bool shouldReload(_LoadedLocale old) => old.value != value;
}

void main() {
  late _Store store;
  late ChatGptAuthClient auth;
  late DesktopChatGptController controller;
  setUp(() {
    store = _Store();
    auth = ChatGptAuthClient(
      store: store,
      openBrowser: (_) async => false,
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'issuer': openAiIssuer,
            'authorization_endpoint': '$openAiIssuer/api/accounts/authorize',
            'token_endpoint': '$openAiIssuer/api/accounts/oauth/token',
            'jwks_uri': '$openAiIssuer/.well-known/jwks.json',
            'revocation_endpoint': '$openAiIssuer/oauth/revoke',
          }),
          200,
        ),
      ),
    );
    controller = DesktopChatGptController(
      auth: auth,
      responsesFactory: (auth) => ChatGptResponses(
        auth,
        clientFactory: () => MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'models': [
                  {
                    'slug': 'test-model',
                    'display_name': 'Test model',
                    'visibility': 'list',
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            'data: ${jsonEncode({
              'type': 'response.failed',
              'response': {
                'error': {'code': 'subscription_sharing_usage_limit_exceeded'},
              },
            })}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      ),
    );
  });

  void seed({bool plan = true, int accounts = 1}) {
    store.value = jsonEncode({
      'version': 1,
      'host_id': 'urn:uuid:11111111-1111-4111-8111-111111111111',
      'active_client_id': 'oaiapp_test_0',
      'pending_client_id': null,
      'accounts': List.generate(
        accounts,
        (index) => {
          'client_id': 'oaiapp_test_$index',
          'issuer': openAiIssuer,
          'subject': 'subject_$index',
          'email': 'reader@example.test',
          'name': 'Reader',
          'tokens': {
            'access_token': 'test-access',
            'refresh_token': 'test-refresh',
            'id_token': 'retained-test-identity',
          },
          'scopes': plan ? requestedScopes : ['openid', 'profile', 'email'],
          'expires_at': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .toIso8601String(),
          'welcome_seen': true,
        },
      ),
    });
  }

  Future<void> showPage(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    GlobalKey? screenshotKey,
    bool realFont = false,
  }) async {
    tester.view.physicalSize = const Size(800, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(
      () => tester.runAsync(() async {
        await auth.close();
        controller.dispose();
      }),
    );
    final localization = await tester.runAsync(() async {
      await controller.initialize();
      return L10n.delegate.load(locale);
    });
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xff256252),
          fontFamily: realFont ? 'SourceHanSerif' : null,
        ),
        localizationsDelegates: [
          _LoadedLocale(localization!),
          ...L10n.localizationsDelegates.skip(1),
        ],
        supportedLocales: L10n.supportedLocales,
        home: RepaintBoundary(
          key: screenshotKey,
          child: ChatGptAccountPage(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
  }

  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    // Keep UI-triggered operations in the real async zone of the auth queue.
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
  }

  testWidgets('signed-out page exposes sign-in and disables inference', (
    tester,
  ) async {
    await showPage(tester);
    expect(find.text('Continue with ChatGPT'), findsOneWidget);
    final models = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Load available models'),
    );
    expect(models.onPressed, isNull);
    expect(
      find.textContaining('Choose ChatGPT in the reading assistant'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'same-email registrations can be selected without exposing tokens',
    (tester) async {
      seed(accounts: 2);
      await showPage(tester);
      await tapAndSettle(
        tester,
        find.byType(DropdownButtonFormField<String>).first,
      );
      await tapAndSettle(
        tester,
        find.text('reader@example.test · aiapp_test_1').last,
      );
      expect(controller.active!.clientId, 'oaiapp_test_1');
      expect(find.textContaining('test-access'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'identity-only profile offers explicit plan consent and no inference',
    (tester) async {
      seed(plan: false);
      await showPage(tester);
      expect(find.text('Enable ChatGPT plan usage'), findsOneWidget);
      final models = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Load available models'),
      );
      expect(models.onPressed, isNull);
    },
  );

  testWidgets(
    'usage failure is visible and cannot show a successful connection',
    (tester) async {
      seed();
      await showPage(tester);
      await tapAndSettle(tester, find.text('Load available models'));
      await tester.ensureVisible(find.text('Verify (uses plan or credits)'));
      await tapAndSettle(tester, find.text('Verify (uses plan or credits)'));
      expect(controller.testCompleted, false);
      expect(
        find.textContaining('subscription_sharing_usage_limit_exceeded'),
        findsOneWidget,
      );
      expect(
        find.text('Connection verified · response completed'),
        findsNothing,
      );
      final manageUsage = find.text('Manage usage in ChatGPT').first;
      await tester.ensureVisible(manageUsage);
      expect(manageUsage.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Chinese connection screen is readable at desktop size', (
    tester,
  ) async {
    final font = FontLoader('SourceHanSerif')
      ..addFont(rootBundle.load('assets/fonts/SourceHanSerifSC-Regular.otf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await tester.runAsync(() async {
      await font.load();
      await icons.load();
    });
    final key = GlobalKey();
    await showPage(
      tester,
      locale: const Locale('zh', 'CN'),
      screenshotKey: key,
      realFont: true,
    );
    expect(find.text('ChatGPT 账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('AUTH_SCREENSHOT')) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('verification/chatgpt-account-zh.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
