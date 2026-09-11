import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

String trackLanguageName(String? language) {
  final code = language?.trim().toLowerCase();
  return switch (code) {
    null || '' || 'und' => 'Language not specified',
    'lv' || 'lav' => 'Latvian',
    'en' || 'eng' => 'English',
    'th' || 'tha' => 'Thai',
    'ru' || 'rus' => 'Russian',
    'uk' || 'ukr' => 'Ukrainian',
    'de' || 'deu' || 'ger' => 'German',
    'fr' || 'fra' || 'fre' => 'French',
    'es' || 'spa' => 'Spanish',
    _ => language!.trim(),
  };
}

/// Metadata labels are descriptive, not an attestation of track language.
String audioTrackLabel(AudioTrack track, int index) =>
    track.title?.trim().isNotEmpty == true
    ? track.title!.trim()
    : 'Audio track ${index + 1}';

String captionTrackLabel(SubtitleTrack track, int index) =>
    track.title?.trim().isNotEmpty == true
    ? track.title!.trim()
    : 'Caption track ${index + 1}';

/// Receives live engine state. Selection changes do not seek/reopen the media.
class TvTrackMenu extends StatefulWidget {
  const TvTrackMenu({
    super.key,
    required this.tracks,
    required this.selected,
    required this.onAudio,
    required this.onCaption,
    this.onLoadCaptions,
    this.onPasteCaptions,
  });

  final Tracks tracks;
  final Track selected;
  final Future<void> Function(AudioTrack) onAudio;
  final Future<void> Function(SubtitleTrack) onCaption;
  final Future<void> Function()? onLoadCaptions;
  final Future<void> Function()? onPasteCaptions;

  @override
  State<TvTrackMenu> createState() => _TvTrackMenuState();
}

class _TvTrackMenuState extends State<TvTrackMenu> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action, String failure) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _choice({
    required String title,
    String? subtitle,
    required bool selected,
    required VoidCallback onTap,
    bool autofocus = false,
  }) => ListTile(
    autofocus: autofocus,
    enabled: !_busy,
    selected: selected,
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_off,
    ),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final audio = widget.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final captions = widget.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    return AlertDialog(
      title: const Text('Audio & Captions'),
      content: SizedBox(
        width: 640,
        height: MediaQuery.sizeOf(context).height * .56,
        child: ListView(
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Text('Audio', style: Theme.of(context).textTheme.titleLarge),
            _choice(
              title: 'Automatic audio',
              subtitle: 'Use the media file’s default',
              selected: widget.selected.audio.id == 'auto',
              autofocus: true,
              onTap: () => _run(
                () => widget.onAudio(AudioTrack.auto()),
                'Could not change audio. Try another track.',
              ),
            ),
            if (audio.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No audio tracks reported yet.'),
              ),
            for (var i = 0; i < audio.length; i++)
              _choice(
                title: audioTrackLabel(audio[i], i),
                subtitle: trackLanguageName(audio[i].language),
                selected: widget.selected.audio == audio[i],
                onTap: () => _run(
                  () => widget.onAudio(audio[i]),
                  'Could not change audio. Try another track.',
                ),
              ),
            const Divider(height: 28),
            Text('Captions', style: Theme.of(context).textTheme.titleLarge),
            _choice(
              title: 'Captions off',
              selected: widget.selected.subtitle.id == 'no',
              onTap: () => _run(
                () => widget.onCaption(SubtitleTrack.no()),
                'Could not turn captions off. Please try again.',
              ),
            ),
            if (captions.isNotEmpty)
              _choice(
                title: 'Automatic captions',
                selected: widget.selected.subtitle.id == 'auto',
                onTap: () => _run(
                  () => widget.onCaption(SubtitleTrack.auto()),
                  'Could not change captions. Try another track.',
                ),
              ),
            if (captions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'No caption tracks in this media. Load a file or paste timed caption text.',
                ),
              ),
            for (var i = 0; i < captions.length; i++)
              _choice(
                title: captionTrackLabel(captions[i], i),
                subtitle: trackLanguageName(captions[i].language),
                selected: widget.selected.subtitle == captions[i],
                onTap: () => _run(
                  () => widget.onCaption(captions[i]),
                  'Could not change captions. Try another track.',
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.onPasteCaptions != null)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => _run(
                    widget.onPasteCaptions!,
                    'Could not load captions. Please try again.',
                  ),
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste captions'),
          ),
        if (widget.onLoadCaptions != null)
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => _run(
                    widget.onLoadCaptions!,
                    'Could not load captions. Choose a UTF-8 SRT or VTT file under 2 MB.',
                  ),
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Load caption file'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
