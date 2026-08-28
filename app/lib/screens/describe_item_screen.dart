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
import '../services/library_arrangement.dart' show genreNames;
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/tmdb_client.dart';
import '../services/user_metadata.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/channel_badge.dart';
import '../widgets/poster_crop_dialog.dart';
import 'edit_details_screen.dart' show FramePickerDialog;

/// Categories offered as chips on the Describe page — the TMDB genre
/// names, so a hand-picked category and a TMDB match feed the exact
/// same filter chips on list pages.
const kDescribeCategories = [
  'Action',
  'Adventure',
  'Animation',
  'Comedy',
  'Crime',
  'Documentary',
  'Drama',
  'Family',
  'Fantasy',
  'History',
  'Horror',
  'Music',
  'Mystery',
  'Romance',
  'Science Fiction',
  'Thriller',
  'War',
  'Western',
];

/// What "Check TMDB" searches for: the typed title/year when the
/// publisher changed them (their correction beats a mangled file name),
/// else the parsed file name — which keeps an IMDb id tag's exact
/// `/find` lookup. Season/episode markers always come from the file
/// name; a typed title only renames the show being searched.
ParsedName tmdbSearchName(
    ParsedName parsed, String typedTitle, String typedYear) {
  final title = typedTitle.trim();
  final year = int.tryParse(typedYear.trim());
  if (title.isEmpty ||
      (title.toLowerCase() == parsed.title.toLowerCase() &&
          year == parsed.year)) {
    return parsed;
  }
  return ParsedName(title, year,
      season: parsed.season, episode: parsed.episode);
}

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
    this.entry,
    this.fileName,
    this.localPath,
    this.ffmpeg,
    this.postersDirProvider,
  }) : assert(entry != null || fileName != null,
            'describe either a library entry or a local file');

  /// The library entry being described (the add-from-library path), or
  /// null when describing a not-yet-uploaded local file.
  final MediaEntry? entry;

  /// File name to describe when there is no library entry yet (the
  /// channel publish-from-file path) — the metadata row is keyed by the
  /// name exactly like a library entry's would be, so the later uploads
  /// resolve to it.
  final String? fileName;

  /// Local path of that file; frame grabs sample it directly.
  final String? localPath;

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

  late MediaMetadata _meta;
  late final ParsedName _parsed;

  Uint8List? _newPosterBytes;
  final _selectedGenres = <String>{};
  bool _frameSourceAvailable = false;
  bool _saving = false;
  bool _checkingTmdb = false;

  String get _name => widget.entry?.name ?? widget.fileName!;

  @override
  void initState() {
    super.initState();
    _meta = MetadataService.instance.metadataFor(
        widget.entry ?? MediaEntry(name: _name, address: ''));
    _parsed = parseMediaName(_name);
    // Prefilled from whatever metadata already exists (user edits, or a
    // TMDB match for the rare indexed item).
    _title = TextEditingController(text: _meta.title);
    _year = TextEditingController(text: _meta.year?.toString() ?? '');
    _overview = TextEditingController(text: _meta.overview ?? '');
    _selectedGenres.addAll(genreNames(_meta.category));
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
    final localPath = widget.localPath;
    if (localPath != null) return (path: localPath, local: true);
    final entry = widget.entry;
    if (entry == null) return null;
    final local = DownloadManager.instance.localPathIfDone(entry);
    if (local != null) return (path: local, local: true);
    final url = streamUrl(EmbeddedClient.baseUrl(), entry);
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
    if ((duration == null || duration <= 0) && widget.entry != null) {
      final state = await WatchStateStore.instance.stateFor(widget.entry!);
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

  void _snack(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  /// Look the item up on TMDB with the typed title/year (public-domain
  /// classics ARE in the database), preview the match, and on accept
  /// store it through the normal metadata pipeline — the full row
  /// (rating, genres, TMDB id) then travels in the channel manifest —
  /// and prefill the required fields from it.
  Future<void> _checkTmdb() async {
    if (_checkingTmdb) return;
    final service = MetadataService.instance;
    if (!await service.hasTmdbKey) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No TMDB key'),
          content: const Text(
              'Looking items up needs your own (free) TMDB API key — add '
              'one in Settings → Metadata, then come back here.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close')),
          ],
        ),
      );
      return;
    }
    setState(() => _checkingTmdb = true);
    try {
      final search = tmdbSearchName(_parsed, _title.text, _year.text);
      final match = await service.lookupTmdb(search);
      if (match == null) {
        if (mounted) {
          _snack('TMDB has no match for “${search.title}” — check the '
              'title and year, then try again.');
        }
        return;
      }
      final poster = await service.tmdbPosterBytes(match);
      if (!mounted) return;
      // Checking is over once the preview is up — an endless button
      // spinner behind the dialog would also never settle in tests.
      setState(() => _checkingTmdb = false);
      final use = await showDialog<bool>(
        context: context,
        builder: (_) => TmdbMatchDialog(match: match, posterBytes: poster),
      );
      if (use != true || !mounted) return;
      final adopted =
          await service.adoptTmdbMatch(_parsed.lookupKey, match);
      if (!mounted) return;
      setState(() {
        _meta = adopted;
        _title.text = match.title;
        _year.text = match.year?.toString() ?? _year.text;
        // TMDB sometimes has no synopsis — keep whatever was typed.
        if (match.overview != null) _overview.text = match.overview!;
        // The match's genres replace any hand-picked category.
        if (adopted.category != null) {
          _selectedGenres
            ..clear()
            ..addAll(genreNames(adopted.category));
        }
        // The adopted poster file shows through _meta; a previously
        // picked image would hide it.
        _newPosterBytes = null;
      });
    } on TmdbException catch (e) {
      if (mounted) _snack('Could not reach TMDB ($e) — try again.');
    } finally {
      if (mounted) setState(() => _checkingTmdb = false);
    }
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
    // Ordered as listed (extras from a TMDB match keep their spot at
    // the end) so the stored string is deterministic.
    final genres = [
      for (final g in kDescribeCategories)
        if (_selectedGenres.contains(g)) g,
      for (final g in _selectedGenres)
        if (!kDescribeCategories.contains(g)) g,
    ];
    await saveUserDetails(
      lookupKey: _parsed.lookupKey,
      title: _title.text.trim(),
      year: int.tryParse(_year.text.trim()),
      overview: _overview.text,
      posterFile: posterFile,
      category: Value(genres.isEmpty ? null : genres.join(' · ')),
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
            _name,
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
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _checkingTmdb ? null : _checkTmdb,
                icon: _checkingTmdb
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.travel_explore, size: 18),
                label: Text(
                    _checkingTmdb ? 'Checking TMDB…' : 'Check TMDB'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Known films and shows — public-domain classics '
                  'included — can be filled in from The Movie Database '
                  'using the title and year above.',
                  style: TextStyle(color: t.ash, fontSize: 11.5),
                ),
              ),
            ],
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
          Text('CATEGORY (optional)',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: t.ash,
              )),
          const SizedBox(height: 4),
          Text(
            'Subscribers filter a list by these — without one the item '
            'shows as uncategorised.',
            style: TextStyle(color: t.ash, fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              // A TMDB match can carry genres outside the offered set
              // ("TV Movie", "War & Politics") — keep them selectable
              // rather than silently dropping them on the next save.
              for (final g in [
                ...kDescribeCategories,
                ..._selectedGenres
                    .where((g) => !kDescribeCategories.contains(g)),
              ])
                FilterChip(
                  label: Text(g),
                  selected: _selectedGenres.contains(g),
                  showCheckmark: false,
                  backgroundColor: t.ink2,
                  selectedColor: WiTokens.channelAmber,
                  side: BorderSide(
                      color: _selectedGenres.contains(g)
                          ? WiTokens.channelAmber
                          : t.line),
                  labelStyle: TextStyle(
                    fontSize: 12,
                    color: _selectedGenres.contains(g) ? t.ink : t.boneDim,
                    fontWeight: _selectedGenres.contains(g)
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                  onSelected: (on) => setState(() {
                    on ? _selectedGenres.add(g) : _selectedGenres.remove(g);
                  }),
                ),
            ],
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

/// Preview of a "Check TMDB" match: poster, title, rating/genres,
/// synopsis. Pops `true` when the publisher takes the details.
class TmdbMatchDialog extends StatelessWidget {
  const TmdbMatchDialog({super.key, required this.match, this.posterBytes});

  final TmdbMatch match;
  final Uint8List? posterBytes;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final year = match.year == null ? '' : ' (${match.year})';
    final extras = [
      if (match.rating != null) '${match.rating!.toStringAsFixed(1)}/10',
      if (match.category != null) match.category!,
    ].join(' · ');
    return AlertDialog(
      title: const Text('TMDB match'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (posterBytes != null)
                    Container(
                      width: 90,
                      height: 135,
                      margin: const EdgeInsets.only(right: 12),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6)),
                      child:
                          Image.memory(posterBytes!, fit: BoxFit.cover),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${match.title}$year',
                            style: TextStyle(
                                color: t.bone,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        if (match.episodeLabel != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(match.episodeLabel!,
                                style: TextStyle(
                                    color: t.ash, fontSize: 12.5)),
                          ),
                        if (extras.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(extras,
                                style: TextStyle(
                                    color: t.ash, fontSize: 12.5)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (match.overview != null) ...[
                const SizedBox(height: 12),
                Text(match.overview!,
                    style: TextStyle(
                        color: t.bone, fontSize: 13, height: 1.4)),
              ],
              const SizedBox(height: 12),
              Text(
                'Details and artwork from The Movie Database. They fill '
                'in the describe fields — you can still edit everything '
                'before saving.',
                style: TextStyle(color: t.ash, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Use these details')),
      ],
    );
  }
}
