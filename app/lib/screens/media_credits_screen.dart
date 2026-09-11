import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/media_credits.dart';
import '../models/media_list.dart';
import '../services/media_credits_store.dart';
import '../services/profiles.dart';

/// Attribution is available for every file, including a music track's detail
/// page. Editing stays explicit; reading credits never launches a source URL.
class MediaCreditsScreen extends StatefulWidget {
  const MediaCreditsScreen({super.key, required this.entry});
  final MediaEntry entry;

  @override
  State<MediaCreditsScreen> createState() => _MediaCreditsScreenState();
}

class _MediaCreditsScreenState extends State<MediaCreditsScreen> {
  MediaCredits? _credits;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final credits = await MediaCreditsStore.read(widget.entry.address);
      if (mounted) {
        setState(() {
          _credits = credits;
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not read these credits.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _CreditsEditor(entry: widget.entry, initial: _credits),
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _open(String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No browser is available. Copy the credits to open the link on another device.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final credits = _credits;
    return Scaffold(
      appBar: AppBar(title: const Text('Credits & source')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  widget.entry.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ] else ...[
                  Text(
                    credits == null || credits.isEmpty
                        ? 'No credits recorded yet.'
                        : 'Credits supplied with this media or entered on this device.',
                  ),
                  const SizedBox(height: 16),
                  if (credits != null && !credits.isEmpty) ...[
                    for (final field in credits.toJson().entries)
                      if (field.value.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                MediaCredits.fields[field.key]!.$1,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(field.value),
                            ],
                          ),
                        ),
                    if (credits.licenseName.isEmpty &&
                        credits.licenseUrl.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 16),
                        child: Text('Reuse licence not recorded.'),
                      ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          autofocus: true,
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy credits'),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: credits.creditText),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Credits copied.'),
                                ),
                              );
                            }
                          },
                        ),
                        if (credits.sourceUrl.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () => _open(credits.sourceUrl),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Open source'),
                          ),
                        if (credits.licenseUrl.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () => _open(credits.licenseUrl),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('Read licence'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (!ProfileStore.instance.isKid)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        autofocus: credits == null || credits.isEmpty,
                        onPressed: _edit,
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(
                          credits == null || credits.isEmpty
                              ? 'Add credits'
                              : 'Edit credits',
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  const Text(
                    'These details travel with exported collections. A credit record '
                    'does not verify ownership or grant permission to reuse the media.',
                  ),
                ],
              ],
            ),
    );
  }
}

class _CreditsEditor extends StatefulWidget {
  const _CreditsEditor({required this.entry, this.initial});
  final MediaEntry entry;
  final MediaCredits? initial;
  @override
  State<_CreditsEditor> createState() => _CreditsEditorState();
}

class _CreditsEditorState extends State<_CreditsEditor> {
  final _form = GlobalKey<FormState>();
  late final _controllers = {
    for (final field in MediaCredits.fields.keys)
      field: TextEditingController(text: widget.initial?.toJson()[field] ?? ''),
  };
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving ||
        ProfileStore.instance.isKid ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await MediaCreditsStore.save(
        widget.entry.address,
        MediaCredits.fromJson({
          for (final field in _controllers.entries) field.key: field.value.text,
        }),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on FormatException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save credits. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Edit credits')),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) Text(_error!),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving…' : 'Save credits'),
                ),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Record the original source and credit, including any changes '
            'such as a trim, translation or dub. Leave unknown details blank.',
          ),
          const SizedBox(height: 24),
          for (final field in MediaCredits.fields.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextFormField(
                key: ValueKey('credit-${field.key}'),
                controller: _controllers[field.key],
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: field.value.$1,
                  border: const OutlineInputBorder(),
                ),
                maxLength: field.value.$2,
                minLines: 1,
                maxLines: field.key == 'attribution' || field.key == 'changes'
                    ? 4
                    : 2,
                keyboardType: field.key.endsWith('Url')
                    ? TextInputType.url
                    : TextInputType.multiline,
                autocorrect: !field.key.endsWith('Url'),
                validator: (value) {
                  try {
                    MediaCredits.fromJson({field.key: value ?? ''});
                    return null;
                  } on FormatException catch (e) {
                    return e.message;
                  }
                },
              ),
            ),
        ],
      ),
    ),
  );
}
