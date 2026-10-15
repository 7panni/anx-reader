import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/page/settings_page/chatgpt_account_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Optional focused entry point; it uses the same screen and implementation
/// as the full reader, without loading books or existing reader preferences.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      child: MaterialApp(
        title: 'AI Reader',
        theme: ThemeData(
          colorSchemeSeed: const Color(0xff256252),
          useMaterial3: true,
        ),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: const ChatGptAccountPage(),
      ),
    ),
  );
}
