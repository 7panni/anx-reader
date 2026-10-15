import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/ai_provider.dart';
import 'package:anx_reader/service/ai/ai_model_service.dart';
import 'package:anx_reader/service/chatgpt/desktop_chatgpt.dart';
import 'package:anx_reader/service/chatgpt/reader_provider.dart';
import 'package:chatgpt_auth/chatgpt_auth.dart';
import 'package:anx_reader/widgets/common/anx_button.dart';
import 'package:flutter/material.dart';

/// A dialog that lets the user either type a model name manually or pick one
/// from the auto-fetched list (OpenAI-compatible `/v1/models` endpoint only).
///
/// Returns the selected/entered model string, or `null` if cancelled.
Future<String?> showModelPickerDialog({
  required BuildContext context,
  required AiProvider provider,
  String? currentModel,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ModelPickerDialog(
      provider: provider,
      currentModel: currentModel,
    ),
  );
}

class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({
    required this.provider,
    this.currentModel,
  });

  final AiProvider provider;
  final String? currentModel;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  late TextEditingController _controller;
  List<String>? _fetchedModels;
  bool _isFetching = false;
  String? _fetchError;
  bool get _isChatGpt => widget.provider.id == chatGptProviderId;

  bool get _canFetch =>
      _isChatGpt || (widget.provider.protocol == AiProtocol.openai &&
      widget.provider.hasValidKey &&
      widget.provider.url.isNotEmpty);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.currentModel ?? '',
    );
    if (_isChatGpt) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchModels();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _fetchModels() async {
    setState(() {
      _isFetching = true;
      _fetchError = null;
      _fetchedModels = null;
    });

    try {
      final List<String> models;
      if (_isChatGpt) {
        final controller = DesktopChatGptController.instance;
        await controller.initialize();
        final account = controller.active;
        if (account == null || !account.signedIn || !account.planEnabled) {
          throw const ChatGptException('sign_in_required',
              'Open Settings > AI > ChatGPT account to sign in.');
        }
        models = (await controller.responses.models(account.clientId))
            .map((m) => m.slug).toList();
      } else {
        models = await fetchAiModels(url: widget.provider.url,
            apiKey: widget.provider.currentApiKey ?? '');
      }
      if (mounted) {
        setState(() {
          _fetchedModels = models;
          _isFetching = false;
          if (models.isEmpty) {
            _fetchError = L10n.of(context).settingsAiProviderNoModelsFound;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFetching = false;
          _fetchError = L10n.of(context)
              .settingsAiProviderFetchModelsFailed(e.toString());
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(l10n.aiModelSwitchTitle),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Manual input row
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      labelText: _isChatGpt ? l10n.chatGptModel : l10n.aiModelEnterManually,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    autofocus: !_canFetch,
                    readOnly: _isChatGpt,
                  ),
                ),
                if (_canFetch) ...[
                  const SizedBox(width: 8),
                  AnxButton(
                    onPressed: _isFetching ? null : _fetchModels,
                    isLoading: _isFetching,
                    child: Text(l10n.settingsAiProviderFetchModels),
                  ),
                ],
              ],
            ),

            // Error message
            if (_fetchError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _fetchError!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),

            // Fetched model list
            if (_fetchedModels != null && _fetchedModels!.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(
                  l10n.aiModelOrSelectBelow,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.35,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _fetchedModels!.length,
                  itemBuilder: (context, index) {
                    final modelId = _fetchedModels![index];
                    final isSelected = _controller.text == modelId;
                    return ListTile(
                      dense: true,
                      title: Text(modelId),
                      selected: isSelected,
                      selectedColor: theme.colorScheme.primary,
                      onTap: () {
                        setState(() => _controller.text = modelId);
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: _isChatGpt && !(_fetchedModels?.contains(_controller.text) ?? false)
              ? null : () {
            final text = _controller.text.trim();
            Navigator.pop(context, text.isEmpty ? null : text);
          },
          child: Text(l10n.commonConfirm),
        ),
      ],
    );
  }
}
