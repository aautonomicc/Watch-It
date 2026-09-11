import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/caption_file.dart';

/// A local alternative for TVs whose document picker is only a system stub.
class CaptionTextDialog extends StatefulWidget {
  const CaptionTextDialog({super.key});

  @override
  State<CaptionTextDialog> createState() => _CaptionTextDialogState();
}

class _CaptionTextDialogState extends State<CaptionTextDialog> {
  final _name = TextEditingController(text: 'Captions');
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;
      final text = data?.text;
      if (text == null || text.isEmpty) {
        setState(
          () => _error =
              'The clipboard has no text. You can type captions below.',
        );
        return;
      }
      if (text.length > CaptionFile.maxBytes) {
        setState(() => _error = 'Caption text must be under 2 MB.');
        return;
      }
      _text.text = text;
      setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not read the clipboard. You can type captions below.',
        );
      }
    }
  }

  void _load() {
    try {
      final text = _text.text.trim();
      var name = _name.text.trim();
      if (name.isEmpty) name = 'Captions';
      if (!RegExp(r'\.(srt|vtt)$', caseSensitive: false).hasMatch(name)) {
        name += text.replaceFirst('\uFEFF', '').startsWith('WEBVTT')
            ? '.vtt'
            : '.srt';
      }
      final caption = CaptionFile.parse(
        name,
        Uint8List.fromList(utf8.encode(text)),
      );
      Navigator.of(context).pop(caption);
    } on FormatException {
      setState(() => _error = 'Use timed SRT or WebVTT captions under 2 MB.');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Paste captions'),
    content: SizedBox(
      width: 640,
      height: MediaQuery.sizeOf(context).height * .56,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'For this playback only. Paste or enter timed caption text.',
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              autofocus: true,
              onPressed: _paste,
              icon: const Icon(Icons.content_paste),
              label: const Text('Paste from clipboard'),
            ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Label (for example: Latvian.lv)',
              ),
              maxLength: 120,
            ),
            TextField(
              controller: _text,
              minLines: 4,
              maxLines: 8,
              maxLength: CaptionFile.maxBytes,
              decoration: const InputDecoration(
                labelText: 'SRT or WebVTT text',
                hintText: 'WEBVTT\n\n00:00.000 --> 00:10.000\nCaption text',
                counterText: '',
              ),
            ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _load, child: const Text('Load captions')),
    ],
  );
}
