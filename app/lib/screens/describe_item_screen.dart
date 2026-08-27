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
import '../widgets/channel_badge.dart';
import '../widgets/poster_crop_dialog.dart';
import 'edit_details_screen.dart' show FramePickerDialog;

/// "Describe this item" — the REQUIRED metadata step before an item can
/// join a channel (docs/PLAN-personal-vs-channels.md Part 2). Fresh,
/// self-made content is not in TMDB, so the manifest must be
/// self-describing: title, description, and artwork are mandatory here
/// (the Add button stays disabled until all three exist). The save is a
/// normal Edit-details save (a `userEdited` metadata row + `user_`
/// poster), so the publisher's own library and the channel manifest
/// stay consistent, and a later manifest rebuild re-exports it
/// unchanged. Pops `true` when the item is fully described.
class DescribeItemScreen extends StatefulWidget {
  const DescribeItemScreen({
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
  State<DescribeItemScreen> createState() => _DescribeItemScreenState();
}

class _DescribeItemScreenState extends State<DescribeItemScreen> {
  late final FfmpegService _ffmpeg = widget.ffmpeg ?? FfmpegService();

  late final TextEditingController _title;
  late final TextEditingController _year;
  late final TextEditingController _overview;

  late final MediaMetadata _meta;
  late final ParsedName _parsed;

  Uint8List? _newPosterBytes;
  bool _frameSourceAvailable = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _meta = MetadataService.instance.metadataFor(widget.entry);
    _parsed = parseMediaName(widget.entry.name);
    // Prefilled from whatever metadata already exists (user edits, or a
    // TMDB match for the rare indexed item).
    _title = TextEditingController(text: _meta.title);
    _year = TextEditingController(text: _meta.year?.toString() ?? '');
    _overview = TextEditingController(text: _meta.overview ?? '');
    _title.addListener(_changed);
    _overview.addListener(_changed);
    unawaited(_load());
  }

  void _changed() => setState(() {});

  Future<void> _load() async {
    final available = await _ffmpeg.available;
    if (!mounted) return;
    setState(() =>
        _frameSourceAvailable = available && _frameSource() != null);
  }

  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    _overview.dispose();
    super.dispose();
  }

  ({String path, bool local})? _frameSource() {
    final local = DownloadManager.instance.localPathIfDone(widget.entry);
    if (local != null) return (path: local, local: true);
    final url = streamUrl(EmbeddedClient.baseUrl(), widget.entry);
    return url == null ? null : (path: url, local: false);
  }

  bool get _hasArtwork =>
      _newPosterBytes != null || posterImage(_meta) != null;

  bool get _complete =>
      _title.text.trim().isNotEmpty &&
      _overview.text.trim().isNotEmpty &&
      _hasArtwork;

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
    setState(() => _newPosterBytes = bytes);
  }

  Future<void> _pickVideoFrame() async {
    final source = _frameSource();
    if (source == null) return;
    var duration = (await _ffmpeg.probe(source.path))?.durationSeconds;
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
    final chosen = await showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PosterCropDialog(bytes: bytes),
    );
    if (chosen == null || !mounted) return;
    setState(() => _newPosterBytes = chosen);
  }

  Future<void> _save() async {
    if (!_complete || _saving) return;
    setState(() => _saving = true);
    Value<String?> posterFile = const Value.absent();
    if (_newPosterBytes != null) {
      posterFile = Value(await saveUserPoster(
          _parsed.lookupKey, _newPosterBytes!,
          postersDirProvider: widget.postersDirProvider));
    }
    await saveUserDetails(
      lookupKey: _parsed.lookupKey,
      title: _title.text.trim(),
      year: int.tryParse(_year.text.trim()),
      overview: _overview.text,
      posterFile: posterFile,
      postersDirProvider: widget.postersDirProvider,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final currentPoster = _newPosterBytes != null
        ? Image.memory(_newPosterBytes!, fit: BoxFit.cover)
        : posterImage(_meta, fit: BoxFit.cover);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Row(
          children: [
            Text('Describe this item',
                style: TextStyle(color: t.bone, fontSize: 18)),
            const SizedBox(width: 10),
            const ChannelBadge(text: 'PUBLIC'),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            widget.entry.name,
            style: TextStyle(
              fontFamily: wiMonoFamily,
              fontFamilyFallback: wiMonoFallback,
              fontSize: 11.5,
              color: t.ash,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Subscribers only see what you write here — fresh content '
            'is not in any database. Title, description, and artwork '
            'are required.',
            style: TextStyle(
                color: WiTokens.channelAmber, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            maxLength: 200,
            style: TextStyle(color: t.bone),
            decoration: InputDecoration(
              labelText: 'Title (required)',
              labelStyle: TextStyle(color: t.ash),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _year,
            keyboardType: TextInputType.number,
            style: TextStyle(color: t.bone),
            decoration: InputDecoration(
              labelText: 'Year (optional)',
              labelStyle: TextStyle(color: t.ash),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _overview,
            maxLines: 4,
            maxLength: 2000,
            style: TextStyle(color: t.bone),
            decoration: InputDecoration(
              labelText: 'Description (required)',
              labelStyle: TextStyle(color: t.ash),
              helperText: _parsed.isEpisode
                  ? 'This describes the episode '
                      '(S${_parsed.season} E${_parsed.episode} per the '
                      'file name)'
                  : null,
              helperStyle: TextStyle(color: t.ash, fontSize: 11),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('ARTWORK (required)',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: t.ash,
              )),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 110,
                height: 165,
                decoration: BoxDecoration(
                  color: t.ink2,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: _hasArtwork ? t.line : t.rust),
                ),
                clipBehavior: Clip.antiAlias,
                child: currentPoster ??
                    Center(
                      child: Icon(Icons.image_outlined,
                          color: t.ash, size: 32),
                    ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickImageFile,
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: const Text('From image file'),
                    ),
                    const SizedBox(height: 8),
                    if (_frameSourceAvailable)
                      OutlinedButton.icon(
                        onPressed: _pickVideoFrame,
                        icon: const Icon(Icons.movie_filter_outlined,
                            size: 18),
                        label: const Text('From video frame'),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'For self-made video, grabbing a frame is the '
                      'natural poster source.',
                      style: TextStyle(color: t.ash, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: WiTokens.channelAmber,
              foregroundColor: Colors.black,
              disabledBackgroundColor: t.ink2,
            ),
            onPressed: _complete && !_saving ? _save : null,
            child: Text(_saving ? 'Saving…' : 'Save description'),
          ),
          if (!_complete)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                [
                  if (_title.text.trim().isEmpty) 'title',
                  if (_overview.text.trim().isEmpty) 'description',
                  if (!_hasArtwork) 'artwork',
                ].isEmpty
                    ? ''
                    : 'Still missing: '
                        '${[
                        if (_title.text.trim().isEmpty) 'title',
                        if (_overview.text.trim().isEmpty) 'description',
                        if (!_hasArtwork) 'artwork',
                      ].join(', ')}',
                style: TextStyle(color: t.ash, fontSize: 12),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
