import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/download_manager.dart';
import '../services/embedded_client.dart';
import '../services/ffmpeg.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/user_metadata.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';

/// Edit details: user-authored title/year/description and artwork for
/// one entry, written to the metadata cache under the entry's lookup
/// key (services/user_metadata.dart). For files TMDB doesn't know —
/// home videos, obscure uploads — this is the only way to get artwork
/// and a description; on top of a TMDB match it's an override that a
/// later re-match never undoes. Artwork comes from an image file, or
/// (with ffmpeg available) a frame sampled out of the video itself.
class EditDetailsScreen extends StatefulWidget {
  const EditDetailsScreen({
    super.key,
    required this.entry,
    this.ffmpeg,
    this.postersDirProvider,
  });

  final MediaEntry entry;

  /// Injectable for tests.
  final FfmpegService? ffmpeg;
  final Future<Directory> Function()? postersDirProvider;

  @override
  State<EditDetailsScreen> createState() => _EditDetailsScreenState();
}

class _EditDetailsScreenState extends State<EditDetailsScreen> {
  late final FfmpegService _ffmpeg = widget.ffmpeg ?? FfmpegService();

  late final TextEditingController _title;
  late final TextEditingController _year;
  late final TextEditingController _overview;

  /// The entry's current metadata at open time — prefills the fields.
  late final MediaMetadata _meta;
  late final String _lookupKey;

  /// Artwork change staged in the editor: new bytes, or removal. Nothing
  /// touches disk until Save.
  Uint8List? _newPosterBytes;
  bool _removePoster = false;

  bool _userEdited = false;
  bool _frameSourceAvailable = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _meta = MetadataService.instance.metadataFor(widget.entry);
    _lookupKey = parseMediaName(widget.entry.name).lookupKey;
    _title = TextEditingController(text: _meta.title);
    _year = TextEditingController(text: _meta.year?.toString() ?? '');
    _overview = TextEditingController(text: _meta.overview ?? '');
    unawaited(_load());
  }

  Future<void> _load() async {
    final row = await metadataRowFor(_lookupKey);
    final ffmpegAvailable = await _ffmpeg.available;
    if (!mounted) return;
    setState(() {
      _userEdited = row?.userEdited ?? false;
      _frameSourceAvailable = ffmpegAvailable && _frameSource() != null;
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    _overview.dispose();
    super.dispose();
  }

  /// Where a frame grab reads the video from: the downloaded file when
  /// one is complete on disk, else the embedded client's stream URL
  /// (each seek costs range requests over the network).
  ({String path, bool local})? _frameSource() {
    final local = DownloadManager.instance.localPathIfDone(widget.entry);
    if (local != null) return (path: local, local: true);
    final url = streamUrl(EmbeddedClient.baseUrl(), widget.entry);
    return url == null ? null : (path: url, local: false);
  }

  Future<void> _pickImageFile() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
          label: 'Images',
          extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp']),
      XTypeGroup(label: 'All files'),
    ]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    if (bytes.length > 10 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That image is larger than 10 MB — pick a '
              'smaller one.')));
      return;
    }
    setState(() {
      _newPosterBytes = bytes;
      _removePoster = false;
    });
  }

  Future<void> _pickVideoFrame() async {
    final source = _frameSource();
    if (source == null) return;
    // Duration: probe the source, falling back to a duration playback
    // has already learned (probing a cold network stream can fail).
    var duration =
        (await _ffmpeg.probe(source.path))?.durationSeconds;
    if (duration == null || duration <= 0) {
      final state = await WatchStateStore.instance.stateFor(widget.entry);
      if (state != null && state.durationMs > 0) {
        duration = state.durationMs / 1000.0;
      }
    }
    if (!mounted) return;
    if (duration == null || duration <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not read the video to sample frames — '
              'try again after playing or downloading it.')));
      return;
    }
    final bytes = await showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FramePickerDialog(
        ffmpeg: _ffmpeg,
        source: source.path,
        durationSeconds: duration!,
        overNetwork: !source.local,
      ),
    );
    if (bytes == null || !mounted) return;
    setState(() {
      _newPosterBytes = bytes;
      _removePoster = false;
    });
  }

  bool get _hasCurrentPoster =>
      _meta.posterFilePath != null || _meta.posterAsset != null;

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    Value<String?> posterFile = const Value.absent();
    if (_newPosterBytes != null) {
      posterFile = Value(await saveUserPoster(_lookupKey, _newPosterBytes!,
          postersDirProvider: widget.postersDirProvider));
    } else if (_removePoster) {
      posterFile = const Value(null);
    }
    await saveUserDetails(
      lookupKey: _lookupKey,
      title: title,
      year: int.tryParse(_year.text.trim()),
      overview: _overview.text,
      posterFile: posterFile,
      postersDirProvider: widget.postersDirProvider,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _clearEdits() async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Remove your edits?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'Your custom details and artwork for this title are deleted. '
          'With a TMDB key configured, details are matched fresh from '
          'TMDB again.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Remove edits', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await clearUserEdits(_lookupKey,
        postersDirProvider: widget.postersDirProvider);
    if (mounted) Navigator.of(context).pop(true);
  }

  Widget _posterPreview(WiTokens t) {
    Widget? image;
    if (_newPosterBytes != null) {
      image = Image.memory(_newPosterBytes!, fit: BoxFit.cover);
    } else if (!_removePoster) {
      image = posterImage(_meta, fit: BoxFit.cover);
    }
    return Container(
      width: 120,
      height: 180,
      decoration: BoxDecoration(
        color: t.ink2,
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: image ??
          Icon(Icons.image_outlined, color: t.ash, size: 40),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Edit details',
            style: TextStyle(color: t.bone, fontSize: 16)),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: Text('Save',
                style: TextStyle(
                    color: t.accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Details entered here are yours: they replace what TMDB '
            'matched (or fill in files it doesn\'t know) and are never '
            'overwritten by a later match. Exported lists carry them, so '
            'people you share with see the same details.',
            style: TextStyle(fontSize: 12, color: t.ash, height: 1.4),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _posterPreview(t),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ARTWORK',
                        style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w700,
                            color: t.ash)),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _pickImageFile,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: t.bone,
                        side: BorderSide(color: t.ash),
                      ),
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: const Text('From image file'),
                    ),
                    if (_frameSourceAvailable) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _pickVideoFrame,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: t.bone,
                          side: BorderSide(color: t.ash),
                        ),
                        icon: const Icon(Icons.movie_filter_outlined,
                            size: 18),
                        label: const Text('From video frame'),
                      ),
                    ],
                    if ((_hasCurrentPoster && !_removePoster) ||
                        _newPosterBytes != null) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => setState(() {
                          _newPosterBytes = null;
                          _removePoster = true;
                        }),
                        icon: Icon(Icons.delete_outline,
                            size: 18, color: t.boneDim),
                        label: Text('Remove artwork',
                            style: TextStyle(color: t.boneDim)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _title,
            style: TextStyle(color: t.bone, fontSize: 14),
            decoration: _fieldDecoration(t, 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _year,
            keyboardType: TextInputType.number,
            style: TextStyle(color: t.bone, fontSize: 14),
            decoration: _fieldDecoration(t, 'Year (optional)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _overview,
            minLines: 4,
            maxLines: 10,
            style: TextStyle(color: t.bone, fontSize: 13.5, height: 1.4),
            decoration: _fieldDecoration(t, 'Description (optional)'),
          ),
          if (_userEdited) ...[
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _clearEdits,
                icon: Icon(Icons.restore, size: 18, color: t.rust),
                label: Text('Remove my edits (re-match from TMDB)',
                    style: TextStyle(color: t.rust)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(WiTokens t, String label) =>
      InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: t.boneDim, fontSize: 13),
        enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: t.ink2)),
        focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: t.accent)),
        filled: true,
        fillColor: t.ink2.withValues(alpha: 0.4),
      );
}

/// Grid of frames sampled evenly across the video — tap one to use it
/// as the artwork (the tap re-grabs the frame at poster resolution).
/// The design the app can't offer is "pause the player at the perfect
/// moment"; this is the next best thing without leaving the editor.
class FramePickerDialog extends StatefulWidget {
  const FramePickerDialog({
    super.key,
    required this.ffmpeg,
    required this.source,
    required this.durationSeconds,
    this.overNetwork = false,
    this.frameCount = 12,
  });

  final FfmpegService ffmpeg;
  final String source;
  final double durationSeconds;

  /// Sampling a streamed (not downloaded) file — warn that it's slower.
  final bool overNetwork;
  final int frameCount;

  @override
  State<FramePickerDialog> createState() => _FramePickerDialogState();
}

class _FramePickerDialogState extends State<FramePickerDialog> {
  late final List<Uint8List?> _thumbs =
      List<Uint8List?>.filled(widget.frameCount, null);
  int _sampled = 0;
  bool _cancelled = false;
  bool _grabbing = false;

  double _timestamp(int i) =>
      widget.durationSeconds * (i + 0.5) / widget.frameCount;

  @override
  void initState() {
    super.initState();
    unawaited(_sample());
  }

  Future<void> _sample() async {
    for (var i = 0; i < widget.frameCount; i++) {
      if (_cancelled) return;
      final bytes = await widget.ffmpeg.extractFrame(
        source: widget.source,
        atSeconds: _timestamp(i),
        maxHeight: 240,
      );
      if (_cancelled || !mounted) return;
      setState(() {
        _thumbs[i] = bytes;
        _sampled = i + 1;
      });
    }
  }

  Future<void> _pick(int i) async {
    if (_grabbing) return;
    setState(() => _grabbing = true);
    final bytes = await widget.ffmpeg.extractFrame(
      source: widget.source,
      atSeconds: _timestamp(i),
      maxHeight: 720,
    );
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _grabbing = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not grab that frame — try another.')));
      return;
    }
    Navigator.of(context).pop(bytes);
  }

  @override
  void dispose() {
    _cancelled = true;
    widget.ffmpeg.cancelFrameExtraction();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final sampling = _sampled < widget.frameCount;
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Pick a frame',
          style: TextStyle(color: t.bone, fontSize: 16)),
      content: SizedBox(
        width: 600,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sampling
                  ? 'Sampling frames — $_sampled of '
                      '${widget.frameCount}…'
                      '${widget.overNetwork ? ' (reading from the '
                          'network, this can take a while)' : ''}'
                  : 'Tap the frame to use as artwork.',
              style: TextStyle(color: t.boneDim, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < widget.frameCount; i++)
                      if (_thumbs[i] != null)
                        InkWell(
                          onTap: () => _pick(i),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.memory(
                              _thumbs[i]!,
                              width: 136,
                              fit: BoxFit.cover,
                            ),
                          ),
                        )
                      else if (i < _sampled || sampling && i == _sampled)
                        Container(
                          width: 136,
                          height: 76,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: t.ink,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: i == _sampled
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: t.accent))
                              : Icon(Icons.broken_image_outlined,
                                  size: 18, color: t.ash),
                        ),
                  ],
                ),
              ),
            ),
            if (_grabbing) ...[
              const SizedBox(height: 12),
              Row(children: [
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: t.accent)),
                const SizedBox(width: 8),
                Text('Grabbing full-quality frame…',
                    style: TextStyle(color: t.boneDim, fontSize: 12)),
              ]),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _cancelled = true;
            widget.ffmpeg.cancelFrameExtraction();
            Navigator.of(context).pop();
          },
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
      ],
    );
  }
}
