import 'dart:async';
import 'dart:io';

import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// macOS Keychain, Windows protected storage, Linux Secret Service. This item
/// is independent of Anx Reader's synced/exported provider configuration.
class DesktopCredentialStore implements CredentialStore {
  static const _key = 'ai_reader.chatgpt.credentials.v1';
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    // Use the macOS login Keychain, which also supports local ad-hoc builds.
    mOptions: MacOsOptions(
      accountName: 'AIReader.ChatGPT',
      useDataProtectionKeyChain: false,
    ),
  );
  RandomAccessFile? _processLock;

  Future<void> _lock() async {
    if (_processLock != null) return;
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final handle = await File(
      '${directory.path}/chatgpt-session.lock',
    ).open(mode: FileMode.append);
    try {
      // Hold for the life of this process. The OS releases it on exit/crash;
      // another process cannot race a rotating refresh token or stale vault.
      await handle.lock(FileLock.exclusive);
      _processLock = handle;
    } catch (_) {
      await handle.close();
      throw const ChatGptException(
        'vault_busy',
        'Another AI Reader process is using ChatGPT. Close it and try again.',
      );
    }
  }

  @override
  Future<String?> read() async {
    await _lock();
    return _storage.read(key: _key);
  }

  @override
  Future<void> write(String value) async {
    await _lock();
    await _storage.write(key: _key, value: value);
  }

  Future<void> close() async {
    await _processLock?.unlock();
    await _processLock?.close();
    _processLock = null;
  }
}

class DesktopChatGptController extends ChangeNotifier {
  DesktopChatGptController({
    ChatGptAuthClient? auth,
    ChatGptResponses Function(ChatGptAuthClient)? responsesFactory,
  }) : auth =
           auth ??
           ChatGptAuthClient(
             store: DesktopCredentialStore(),
             appName: 'AI Reader',
             openBrowser: (uri) =>
                 launchUrl(uri, mode: LaunchMode.externalApplication),
           ) {
    responses =
        responsesFactory?.call(this.auth) ?? ChatGptResponses(this.auth);
  }
  static final instance = DesktopChatGptController();
  static bool get supported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
  final ChatGptAuthClient auth;
  late final ChatGptResponses responses;
  bool busy = false;
  bool signingIn = false;
  bool initialized = false;
  ChatGptException? error;
  bool? remoteRevoked;
  List<ChatGptModel> models = [];
  String? selectedModel;
  String? testOutput;
  bool testCompleted = false;

  List<ChatGptProfile> get profiles => auth.profiles;
  ChatGptProfile? get active => auth.activeProfile;

  Future<bool> _run(Future<void> Function() action) async {
    if (busy) return false;
    busy = true;
    error = null;
    remoteRevoked = null;
    notifyListeners();
    try {
      await action();
      return true;
    } on ChatGptException catch (e) {
      error = e;
      return false;
    } catch (_) {
      error = const ChatGptException(
        'local_error',
        'The operation could not be completed. Check system secure storage and try again.',
      );
      return false;
    } finally {
      busy = false;
      signingIn = false;
      notifyListeners();
    }
  }

  Future<void> initialize() async {
    if (initialized) return;
    await _run(() async {
      await auth.initialize();
      initialized = true;
    });
  }

  void _clearTest() {
    responses.cancel();
    models = [];
    selectedModel = null;
    testOutput = null;
    testCompleted = false;
  }

  Future<bool> connect({String? clientId, bool requestConsent = false}) =>
      _run(() async {
        signingIn = true;
        notifyListeners();
        _clearTest();
        await auth.signIn(clientId: clientId, requestConsent: requestConsent);
      });

  Future<void> switchAccount(String clientId) async => _run(() async {
    _clearTest();
    await auth.selectProfile(clientId);
  });

  Future<void> signOut() async => _run(() async {
    final id = active?.clientId;
    if (id == null) return;
    _clearTest();
    remoteRevoked = await auth.signOut(id);
  });

  Future<void> welcomeSeen(String clientId) async =>
      _run(() => auth.markWelcomeSeen(clientId));

  Future<void> loadModels() async => _run(() async {
    final id = active?.clientId;
    if (id == null) return;
    models = [];
    selectedModel = null;
    testOutput = null;
    testCompleted = false;
    models = await responses.models(id);
    selectedModel = models.firstOrNull?.slug;
  });

  void selectModel(String? model) {
    if (busy || !models.any((m) => m.slug == model)) return;
    selectedModel = model;
    testOutput = null;
    testCompleted = false;
    notifyListeners();
  }

  Future<void> testConnection() async => _run(() async {
    final id = active?.clientId;
    final model = selectedModel;
    if (id == null || model == null) return;
    testCompleted = false;
    testOutput = null;
    await for (final chunk in responses.verifyConnection(
      clientId: id,
      model: model,
    )) {
      testOutput = chunk;
      notifyListeners();
    }
    testCompleted = true;
  });

  Future<void> cancelActiveWork() async {
    responses.cancel();
    await auth.cancelSignIn();
  }

  Future<void> manageUsage() async {
    try {
      if (await launchUrl(
        Uri.parse('https://chatgpt.com/settings/usage'),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      /* Show a bounded error instead of an OS exception. */
    }
    error = const ChatGptException(
      'browser_unavailable',
      'The system browser could not be opened.',
    );
    notifyListeners();
  }
}
