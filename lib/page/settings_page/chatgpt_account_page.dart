import 'dart:async';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/chatgpt/desktop_chatgpt.dart';
import 'package:flutter/material.dart';

class ChatGptAccountPage extends StatefulWidget {
  const ChatGptAccountPage({super.key, this.controller});
  final DesktopChatGptController? controller;
  @override
  State<ChatGptAccountPage> createState() => _ChatGptAccountPageState();
}

class _ChatGptAccountPageState extends State<ChatGptAccountPage> {
  late final DesktopChatGptController controller;
  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? DesktopChatGptController.instance;
    controller.addListener(_changed);
    if (DesktopChatGptController.supported) {
      unawaited(controller.initialize().then((_) => _welcomeIfNeeded()));
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    unawaited(controller.cancelActiveWork());
    super.dispose();
  }

  Future<void> _connect({String? clientId, bool consent = false}) async {
    final success = await controller.connect(
      clientId: clientId,
      requestConsent: consent,
    );
    if (success && mounted) {
      await _welcomeIfNeeded();
    }
  }

  Future<void> _welcomeIfNeeded() async {
    final account = controller.active;
    if (!mounted ||
        account == null ||
        !account.planEnabled ||
        account.welcomeSeen) {
      return;
    }
    final l10n = L10n.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.chatGptWelcomeTitle),
        content: Text(l10n.chatGptWelcomeBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.chatGptGotIt),
          ),
        ],
      ),
    );
    await controller.welcomeSeen(account.clientId);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final account = controller.active;
    final ready = controller.initialized && !controller.busy;
    final planEnabled = account?.planEnabled == true;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.chatGptTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                l10n.chatGptDescription,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              Text(
                l10n.chatGptModuleScope,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              if (!DesktopChatGptController.supported)
                Text(l10n.chatGptDesktopOnly)
              else ...[
                if (controller.profiles.isNotEmpty) ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      '${account?.clientId}:${controller.profiles.length}',
                    ),
                    initialValue: account?.clientId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.chatGptAccount,
                      border: const OutlineInputBorder(),
                    ),
                    items: controller.profiles
                        .map(
                          (profile) => DropdownMenuItem(
                            value: profile.clientId,
                            child: Text(
                              '${profile.displayName} · ${profile.registrationLabel}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: ready
                        ? (id) {
                            if (id != null) controller.switchAccount(id);
                          }
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    account?.signedIn != true
                        ? l10n.chatGptSignedOut
                        : planEnabled
                        ? l10n.chatGptUsingPlan
                        : l10n.chatGptIdentityOnly,
                  ),
                  const SizedBox(height: 16),
                ],
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 48),
                      ),
                      onPressed: ready
                          ? () => _connect(clientId: account?.clientId)
                          : null,
                      icon: const ImageIcon(
                        AssetImage('assets/images/openai.png'),
                        size: 22,
                      ),
                      label: const Text('Continue with ChatGPT'),
                    ),
                    if (controller.profiles.isNotEmpty)
                      TextButton(
                        onPressed: ready ? () => _connect() : null,
                        child: Text(l10n.chatGptAddAccount),
                      ),
                    if (account?.signedIn == true)
                      TextButton(
                        onPressed: ready ? controller.signOut : null,
                        child: Text(l10n.chatGptSignOut),
                      ),
                  ],
                ),
                if (account?.signedIn == true && !planEnabled)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: ready
                          ? () => _connect(
                              clientId: account!.clientId,
                              consent: true,
                            )
                          : null,
                      child: Text(l10n.chatGptEnablePlan),
                    ),
                  ),
                if (controller.busy) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    controller.signingIn
                        ? l10n.chatGptWaitingBrowser
                        : l10n.chatGptWorking,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: controller.cancelActiveWork,
                      child: Text(l10n.chatGptCancel),
                    ),
                  ),
                ],
                if (!controller.initialized && !controller.busy)
                  TextButton(
                    onPressed: controller.initialize,
                    child: Text(l10n.chatGptRetry),
                  ),
                if (controller.error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _errorMessage(l10n),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  if (controller.error!.code ==
                      'subscription_sharing_usage_limit_exceeded')
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: controller.manageUsage,
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(l10n.chatGptManageUsage),
                      ),
                    ),
                  if (controller.error!.requestId != null)
                    SelectableText(
                      'Request ID: ${controller.error!.requestId}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
                if (controller.remoteRevoked != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    controller.remoteRevoked!
                        ? l10n.chatGptSignedOut
                        : l10n.chatGptRemoteRevokeUnconfirmed,
                  ),
                ],
                const Divider(height: 40),
                Text(
                  l10n.chatGptConnectionTest,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(l10n.chatGptTestDescription),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: ready && planEnabled
                        ? controller.loadModels
                        : null,
                    child: Text(l10n.chatGptLoadModels),
                  ),
                ),
                if (controller.models.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      '${account?.clientId}:${controller.models.map((m) => m.slug).join(',')}',
                    ),
                    initialValue: controller.selectedModel,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.chatGptModel,
                      border: const OutlineInputBorder(),
                    ),
                    items: controller.models
                        .map(
                          (model) => DropdownMenuItem(
                            value: model.slug,
                            child: Text(
                              model.displayName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: ready ? controller.selectModel : null,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed:
                          ready &&
                              planEnabled &&
                              controller.selectedModel != null
                          ? controller.testConnection
                          : null,
                      child: Text(l10n.chatGptTestButton),
                    ),
                  ),
                ],
                if (controller.testOutput != null) ...[
                  const SizedBox(height: 12),
                  SelectableText(controller.testOutput!),
                ],
                if (controller.testCompleted)
                  Semantics(
                    liveRegion: true,
                    child: Text(l10n.chatGptTestCompleted),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: controller.manageUsage,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.chatGptManageUsage),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _errorMessage(L10n l10n) {
    final error = controller.error!;
    final message = switch (error.code) {
      'access_denied' || 'cancelled' => l10n.chatGptCancelled,
      'sign_in_timeout' => l10n.chatGptTimeout,
      'vault_unavailable' ||
      'vault_busy' ||
      'local_error' => l10n.chatGptStorageError,
      'network_error' => l10n.chatGptNetworkError,
      'invalid_id_token' ||
      'invalid_state' ||
      'account_mismatch' ||
      'invalid_callback' => l10n.chatGptVerificationError,
      'sign_in_required' || 'invalid_grant' => l10n.chatGptSignInAgain,
      'subscription_sharing_usage_limit_exceeded' => l10n.chatGptUsageLimit,
      'subscription_sharing_user_not_eligible' ||
      'plan_not_authorized' => l10n.chatGptPlanUnavailable,
      _ => l10n.chatGptRequestFailed,
    };
    return '$message (${error.code}${error.status == null ? '' : ', HTTP ${error.status}'})';
  }
}
