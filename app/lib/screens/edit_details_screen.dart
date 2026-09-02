import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../db/app_database.dart' show MetadataCacheRow;
import '../models/media_list.dart';
import '../services/download_manager.dart';
import '../services/embedded_client.dart';
import '../services/ffmpeg.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart'
    show AlbumKeys, episodeNameFromLabel;
import '../services/user_metadata.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/poster_crop_dialog.dart';

/// What one Edit details page edits — which cache key it writes and
/// which fields it shows.
enum EditDetailsScope {
  /// The entry itself: a movie's title/year/description, or (when the
  /// entry is an episode) the episode's name/synopsis/artwork.
  entry,

  /// The whole show, written under the episode-less show key: title,
  /// year, show synopsis, show poster. Reached from the show page.
  show,

  /// One season, written under the season key: season artwork and
  /// synopsis. Reached from the season page.
  season,
}

/// Edit details: user-authored details and artwork written to the
/// metadata cache (services/user_metadata.dart) under the key for
/// [scope] — the entry's own lookup key, or the show/season key that
/// MetadataService overlays onto every episode. For files TMDB doesn't
/// know — home videos, obscure uploads — this is the only way to get
/// artwork and a description; on top of a TMDB match it's an override
/// that a later re-match never undoes. Artwork comes from an image
/// file, or (with ffmpeg available) a frame sampled out of the video.
class EditDetailsScreen extends StatefulWidget {
  const EditDetailsScreen({
    super.key,
    required this.entry,
    this.scope = EditDetailsScope.entry,
    this.ffmpeg,
    this.postersDirProvider,
  });

  /// The entry being edited; for [EditDetailsScope.show]/[EditDetailsScope.season]
  /// any episode of the show/season (frames are sampled from its video).
  final MediaEntry entry;

  final EditDetailsScope scope;

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
  late final TextEditingController _artist;
  late final TextEditingController _trackTitle;
  late final TextEditingController _track;
  late final TextEditingController _disc;

  /// The entry's current metadata at open time — prefills the fields.
  late final MediaMetadata _meta;
  late final ParsedName _parsed;
  late final String _lookupKey;

  /// The title/year field text as prefilled — a track's album/year only
  /// rename the album when the user touched the field (or the differing
  /// prefill was itself a user edit), never because a database match's
  /// canonical title merely differs from the file name.
  late final String _initialTitle;
  late final String _initialYear;

  /// The cache row under [_lookupKey] at open time, if any — the source
  /// for fields the editor preserves rather than shows (an episode row's
  /// stored title, a season row's year).
  MetadataCacheRow? _row;

  /// Artwork change staged in the editor: new bytes, or removal. Nothing
  /// touches disk until Save.
  Uint8List? _newPosterBytes;
  bool _removePoster = false;

  bool _userEdited = false;
  bool _frameSourceAvailable = false;
  bool _saving = false;

  EditDetailsScope get _scope => widget.scope;

  /// The entry scope splits by entry kind: an episode entry edits
  /// episode-level fields (name/synopsis), not the show's.
  bool get _episodeScope =>
      _scope == EditDetailsScope.entry && _parsed.isEpisode;

  /// A music track: every field is editable — artist/description/
  /// artwork write the album's shared row, the track title its own
  /// per-track row (mistakes in any of them stay fixable). Album, year,
  /// and the track number are IDENTITY (they come from the file name
  /// and drive the wall's album fold), so changing them renames entries:
  /// the number renames this track, album/year rename the whole album.
  bool get _trackScope =>
      _scope == EditDetailsScope.entry && _parsed.isTrack;

  @override
  void initState() {
    super.initState();
    _meta = MetadataService.instance.metadataFor(widget.entry);
    _parsed = parseMediaName(widget.entry.name);
    _lookupKey = switch (_scope) {
      EditDetailsScope.entry => _parsed.lookupKey,
      EditDetailsScope.show => _parsed.showLookupKey,
      EditDetailsScope.season =>
        _parsed.seasonLookupKey ?? _parsed.lookupKey,
    };
    _title = TextEditingController(
        text: _episodeScope
            ? episodeNameFromLabel(_meta.episodeLabel) ?? ''
            : _meta.title);
    _year = TextEditingController(text: _meta.year?.toString() ?? '');
    _artist = TextEditingController(
        text: _meta.artist ?? _parsed.artist ?? '');
    _trackTitle = TextEditingController(
        text: _trackScope
            ? episodeNameFromLabel(_meta.episodeLabel) ??
                _parsed.trackTitle ??
                ''
            : '');
    _track = TextEditingController(
        text: _trackScope ? '${_parsed.track}' : '');
    _disc = TextEditingController(text: _parsed.disc?.toString() ?? '');
    _overview = TextEditingController(
        text: switch (_scope) {
      EditDetailsScope.show => _meta.showOverview ?? '',
      EditDetailsScope.season => _meta.seasonOverview ?? '',
      EditDetailsScope.entry => _meta.overview ?? '',
    });
    _initialTitle = _title.text.trim();
    _initialYear = _year.text.trim();
    unawaited(_load());
  }

  Future<void> _load() async {
    final row = await metadataRowFor(_lookupKey);
    final trackKey = _trackScope ? trackLookupKey(_parsed) : null;
    final trackRow =
        trackKey == null ? null : await metadataRowFor(trackKey);
    final ffmpegAvailable = await _ffmpeg.available;
    if (!mounted) return;
    setState(() {
      _row = row;
      _userEdited =
          (row?.userEdited ?? false) || (trackRow?.userEdited ?? false);
      _frameSourceAvailable = ffmpegAvailable && _frameSource() != null;
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    _overview.dispose();
    _artist.dispose();
    _trackTitle.dispose();
    _track.dispose();
    _disc.dispose();
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
    // Frames are landscape; the crop step picks the poster-shaped piece
    // (or keeps the whole frame — the old behaviour).
    final chosen = await showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PosterCropDialog(bytes: bytes),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _newPosterBytes = chosen;
      _removePoster = false;
    });
  }

  /// The image the poster preview shows before any staged change — the
  /// artwork slot this scope's save would replace. The episode editor
  /// shows only the episode's own user artwork, not the season art its
  /// pages merely display (that slot belongs to the season editor).
  Widget? _currentPosterImage() => switch (_scope) {
        EditDetailsScope.show => showPosterImage(_meta, fit: BoxFit.cover),
        EditDetailsScope.season => posterImage(_meta, fit: BoxFit.cover),
        EditDetailsScope.entry => _episodeScope
            ? episodePosterImage(_meta, fit: BoxFit.cover)
            : posterImage(_meta, fit: BoxFit.cover),
      };

  bool get _hasCurrentPoster => _currentPosterImage() != null;

  /// A title is only typed (and required) for a movie, a track's album,
  /// or the show scope; episode and season rows keep the show title
  /// already stored (or the one currently displayed) so other readers
  /// of the row see it.
  bool get _hasTitleField => !_episodeScope && _scope != EditDetailsScope.season;

  /// `S01E02` marker for the episode being edited.
  String get _episodeMarker =>
      'S${_parsed.season.toString().padLeft(2, '0')}'
      'E${_parsed.episode.toString().padLeft(2, '0')}';

  Future<void> _save() async {
    final text = _title.text.trim();
    if (_saving || (_hasTitleField && text.isEmpty)) return;
    setState(() => _saving = true);
    // Track/disc numbers are identity — they live in the file name, not
    // a metadata row — so changing them renames the library entry (and
    // migrates the per-track row to the renamed key) before the field
    // saves below.
    var parsed = _parsed;
    var lookupKey = _lookupKey;
    String? carriedPoster;
    if (_trackScope) {
      final track = int.tryParse(_track.text.trim());
      final disc = _disc.text.trim().isEmpty
          ? null
          : int.tryParse(_disc.text.trim());
      if (track == null ||
          (_disc.text.trim().isNotEmpty && disc == null)) {
        _failSave('Track and disc must be numbers.');
        return;
      }
      var entry = widget.entry;
      if (track != _parsed.track || disc != _parsed.disc) {
        final result = await renumberTrackEntry(entry,
            track: track,
            disc: disc,
            postersDirProvider: widget.postersDirProvider);
        if (result.error != null) {
          _failSave(result.error!);
          return;
        }
        parsed = parseMediaName(result.newName!);
        entry = MediaEntry(
          name: result.newName!,
          address: entry.address,
          addedAt: entry.addedAt,
          sizeBytes: entry.sizeBytes,
          videoInfo: entry.videoInfo,
        );
      }
      // Album and year are identity too — they drive the album fold, so
      // an edited album/year renames the WHOLE album. Only user intent
      // triggers it: a touched field, or a prefill that was itself a
      // user edit (the pre-rename-era album override, healed on Save) —
      // a database match's canonical title merely differing from the
      // file name never renames anything by itself.
      final yearText = _year.text.trim();
      final newYear = yearText.isEmpty ? null : int.tryParse(yearText);
      if (yearText.isNotEmpty && newYear == null) {
        _failSave('Year must be a number.');
        return;
      }
      final touched =
          text != _initialTitle || yearText != _initialYear;
      final differs =
          sanitizeNamePart(text) != parsed.title || newYear != parsed.year;
      if (differs && (touched || (_row?.userEdited ?? false))) {
        final result = await renameTrackAlbum(entry,
            album: text,
            year: newYear,
            postersDirProvider: widget.postersDirProvider);
        if (result.error != null) {
          _failSave(result.error!);
          return;
        }
        parsed = parseMediaName(result.newName!);
        lookupKey = parsed.lookupKey;
        carriedPoster = result.carriedPosterFile;
      }
    }
    Value<String?> posterFile = const Value.absent();
    if (_newPosterBytes != null) {
      posterFile = Value(await saveUserPoster(lookupKey, _newPosterBytes!,
          postersDirProvider: widget.postersDirProvider));
    } else if (_removePoster) {
      posterFile = const Value(null);
    } else if (carriedPoster != null) {
      posterFile = Value(carriedPoster);
    }
    // Episode/season rows never take the typed text as the row title —
    // the row keeps its stored show title (falling back to the one on
    // display) so the fields stay scoped to what the page claims to edit.
    final keptTitle = _row?.title ?? _meta.title;
    final artistText = _artist.text.trim();
    await saveUserDetails(
      lookupKey: lookupKey,
      title: _hasTitleField ? text : keptTitle,
      year: _hasTitleField ? int.tryParse(_year.text.trim()) : _row?.year,
      overview: _overview.text,
      episodeLabel: _episodeScope
          ? Value(text.isEmpty ? _episodeMarker : '$_episodeMarker · $text')
          : const Value.absent(),
      posterFile: posterFile,
      artist: _trackScope
          ? Value(artistText.isEmpty ? null : artistText)
          : const Value.absent(),
      postersDirProvider: widget.postersDirProvider,
    );
    if (_trackScope) await _saveTrackTitle(text, parsed);
    if (mounted) Navigator.of(context).pop(true);
  }

  void _failSave(String message) {
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The track's own title lives in a per-track row (`<albumKey>:tD-NN`)
  /// overlaid onto the shared album row — typing the file name's title
  /// back (or clearing the field) removes the override. [parsed] is the
  /// entry as saved — the renumbered name when this save renamed it.
  Future<void> _saveTrackTitle(String albumTitle, ParsedName parsed) async {
    final trackKey = trackLookupKey(parsed);
    if (trackKey == null) return;
    final typed = _trackTitle.text.trim();
    final original = parsed.trackTitle ?? '';
    if (typed.isEmpty || typed == original) {
      await clearUserEdits(trackKey,
          postersDirProvider: widget.postersDirProvider);
      return;
    }
    await saveUserDetails(
      lookupKey: trackKey,
      title: albumTitle,
      episodeLabel: Value('${parsed.trackMarker} · $typed'),
      postersDirProvider: widget.postersDirProvider,
    );
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
    final trackKey = _trackScope ? trackLookupKey(_parsed) : null;
    if (trackKey != null) {
      await clearUserEdits(trackKey,
          postersDirProvider: widget.postersDirProvider);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Widget _posterPreview(WiTokens t) {
    Widget? image;
    if (_newPosterBytes != null) {
      image = Image.memory(_newPosterBytes!, fit: BoxFit.cover);
    } else if (!_removePoster) {
      image = _currentPosterImage();
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

  String get _pageTitle => switch (_scope) {
        EditDetailsScope.show => 'Edit show details',
        EditDetailsScope.season =>
          'Edit season ${_parsed.season} details',
        EditDetailsScope.entry => _episodeScope
            ? 'Edit episode details'
            : _trackScope
                ? 'Edit track details'
                : 'Edit details',
      };

  String get _explainer {
    final target = switch (_scope) {
      EditDetailsScope.show => 'the whole show, everywhere it appears',
      EditDetailsScope.season => 'this season only',
      EditDetailsScope.entry => _episodeScope
          ? 'this episode only'
          : _trackScope
              ? 'the whole album (artist, album, year, description, '
                  'artwork) and this track\'s own title and number'
              : 'this title',
    };
    return 'Details entered here are yours and apply to $target: they '
        'replace what TMDB matched (or fill in files it doesn\'t know) '
        'and are never overwritten by a later match. Exported lists '
        'carry them, so people you share with see the same details.';
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(_pageTitle,
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
            _explainer,
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
          if (_trackScope) ...[
            TextField(
              controller: _artist,
              style: TextStyle(color: t.bone, fontSize: 14),
              decoration: _fieldDecoration(t, 'Artist'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              style: TextStyle(color: t.bone, fontSize: 14),
              decoration: _fieldDecoration(t, 'Album'),
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
              controller: _trackTitle,
              style: TextStyle(color: t.bone, fontSize: 14),
              decoration: _fieldDecoration(
                  t, 'Track title — ${_parsed.trackMarker}'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _track,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: t.bone, fontSize: 14),
                    decoration: _fieldDecoration(t, 'Track number'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _disc,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: t.bone, fontSize: 14),
                    decoration: _fieldDecoration(t, 'Disc (optional)'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Album, year, and the track number are part of the file '
              'name and decide how tracks group into albums. Changing '
              'the album or year renames every track of this album (so '
              'tracks given the same album and year combine into one); '
              'changing the number renames this entry.',
              style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
          ] else if (_episodeScope) ...[
            // The show's title is edited from the show page; here the
            // text is the episode's own name (the part after SxxEyy).
            TextField(
              controller: _title,
              style: TextStyle(color: t.bone, fontSize: 14),
              decoration: _fieldDecoration(
                  t, 'Episode name (optional) — $_episodeMarker'),
            ),
            const SizedBox(height: 12),
          ] else if (_hasTitleField) ...[
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
          ],
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

/// A track renumber's outcome: the renamed entry name, or the message
/// explaining why nothing was changed.
typedef RenumberResult = ({String? newName, String? error});

/// Rename [entry]'s track marker to ([disc], [track]) everywhere the
/// library holds it (same file name + address in any list), migrating
/// its per-track metadata row to the renamed key. Name-is-the-database:
/// the new number re-parses into the album's sort order and metadata
/// keys with no other state to update; the address is untouched, so
/// playback, downloads, and the upload ledger never notice.
///
/// Refuses (error, nothing written) when the album already holds the
/// requested (disc, track) on another entry — no silent swap.
Future<RenumberResult> renumberTrackEntry(
  MediaEntry entry, {
  required int track,
  int? disc,
  Future<Directory> Function()? postersDirProvider,
}) async {
  final parsed = parseMediaName(entry.name);
  if (!parsed.isTrack) {
    return (newName: null, error: 'Not a music track.');
  }
  final newName =
      renumberedMusicFileName(entry.name, track: track, disc: disc);
  if (newName == null) {
    return (
      newName: null,
      error: 'This file name cannot be renumbered — it does not follow '
          'the track naming convention.'
    );
  }
  final newParsed = parseMediaName(newName);
  final marker = newParsed.trackMarker!;
  final lists = await LibraryStore.load();
  bool isSelf(MediaEntry e) =>
      e.address == entry.address && e.name == entry.name;
  for (final list in lists) {
    if (!list.entries.any(isSelf)) continue;
    // The same fold the home wall uses decides what "this album" means
    // (mbid tag, else album+year, artist-agnostic).
    final keys = AlbumKeys(list.entries);
    final albumKey = keys.keyFor(parsed);
    for (final other in list.entries) {
      if (isSelf(other)) continue;
      final op = parseMediaName(other.name);
      if (!op.isTrack || keys.keyFor(op) != albumKey) continue;
      if ((op.disc ?? 1) == (disc ?? 1) && op.track == track) {
        return (
          newName: null,
          error: 'Track $marker is already taken in this album by '
              '"${op.trackTitle}" — renumber that track first.'
        );
      }
    }
  }
  await LibraryStore.save([
    for (final l in lists)
      l.copyWith(entries: [
        for (final e in l.entries)
          isSelf(e)
              ? MediaEntry(
                  name: newName,
                  address: e.address,
                  addedAt: e.addedAt,
                  sizeBytes: e.sizeBytes,
                  videoInfo: e.videoInfo,
                )
              : e,
      ]),
  ]);
  // The per-track override row's key embeds the number — move it.
  final oldKey = trackLookupKey(parsed)!;
  final newKey = trackLookupKey(newParsed)!;
  if (oldKey != newKey) {
    final row = await metadataRowFor(oldKey);
    if (row != null) {
      final customName = episodeNameFromLabel(row.episodeLabel);
      await clearUserEdits(oldKey,
          postersDirProvider: postersDirProvider);
      if (customName != null) {
        await saveUserDetails(
          lookupKey: newKey,
          title: row.title ?? parsed.title,
          episodeLabel: Value('$marker · $customName'),
          postersDirProvider: postersDirProvider,
        );
      }
    }
  }
  return (newName: newName, error: null);
}

/// An album-identity edit's outcome: the edited entry's renamed name,
/// the album artwork file carried to the new album key (if any), or the
/// message explaining why nothing was changed.
typedef AlbumRenameResult = ({
  String? newName,
  String? error,
  String? carriedPosterFile,
});

/// Rename the album / year of [entry]'s WHOLE album: every track the
/// wall folds into it (the AlbumKeys fold, in each list holding
/// [entry]) gets its name's album/year swapped for [album]/[year] —
/// in every list that holds those exact entries (name + address), so a
/// track never ends up under two names. Album and year live in the file
/// name and drive the album fold, so the edit is a rename exactly like
/// the track-number edit; `{mbid-...}` tags are dropped (the edit
/// overrides the database match — [realbumedMusicFileName]). Per-track
/// override rows migrate to their renamed keys, and the old album row's
/// artwork is carried to the new album key when that key has none.
/// Addresses are untouched: playback, downloads, and the upload ledger
/// never notice.
///
/// Refuses (error, nothing written) when a renamed track would land on
/// a (disc, track) number an existing target-album track already holds
/// — the silent alternative is worse: the same-number-different-artist
/// guard would quietly split the combined album back apart.
Future<AlbumRenameResult> renameTrackAlbum(
  MediaEntry entry, {
  required String album,
  int? year,
  Future<Directory> Function()? postersDirProvider,
}) async {
  final parsed = parseMediaName(entry.name);
  if (!parsed.isTrack) {
    return (
      newName: null,
      error: 'Not a music track.',
      carriedPosterFile: null
    );
  }
  final lists = await LibraryStore.load();
  bool isSelf(MediaEntry e) =>
      e.address == entry.address && e.name == entry.name;
  // What "this album" means = the fold the wall shows, per list holding
  // the edited entry.
  final moved = <(String, String)>{(entry.address, entry.name)};
  for (final list in lists) {
    if (!list.entries.any(isSelf)) continue;
    final keys = AlbumKeys(list.entries);
    final albumKey = keys.keyFor(parsed);
    for (final other in list.entries) {
      final op = parseMediaName(other.name);
      if (op.isTrack && keys.keyFor(op) == albumKey) {
        moved.add((other.address, other.name));
      }
    }
  }
  bool isMoved(MediaEntry e) => moved.contains((e.address, e.name));
  final renames = <String, String>{}; // old name → new name
  for (final m in moved) {
    final oldName = m.$2;
    if (renames.containsKey(oldName)) continue;
    final newName =
        realbumedMusicFileName(oldName, album: album, year: year);
    if (newName == null) {
      return (
        newName: null,
        error: '"$oldName" cannot be renamed — it does not follow the '
            'track naming convention.',
        carriedPosterFile: null,
      );
    }
    renames[oldName] = newName;
  }
  final selfNewName = renames[entry.name]!;
  // Collision check inside the target album, per list: a moved track
  // must not land on a (disc, track) an unmoved track already holds.
  for (final list in lists) {
    final sim = [
      for (final e in list.entries)
        isMoved(e)
            ? MediaEntry(name: renames[e.name]!, address: e.address)
            : e,
    ];
    final keys = AlbumKeys(sim);
    // Compare CLUSTERS, not fold keys: a number collision between two
    // artists makes keyFor split the album per artist, which would hide
    // exactly the collision this check exists to refuse.
    final targetKey = keys.clusterFor(parseMediaName(selfNewName));
    final movedMarkers = <String, ParsedName>{};
    final takenMarkers = <String, String>{}; // disc-track → track title
    for (var i = 0; i < sim.length; i++) {
      final op = parseMediaName(sim[i].name);
      if (!op.isTrack || keys.clusterFor(op) != targetKey) continue;
      final marker = '${op.disc ?? 1}-${op.track}';
      if (isMoved(list.entries[i])) {
        movedMarkers[marker] = op;
      } else {
        takenMarkers[marker] = op.trackTitle!;
      }
    }
    for (final e in movedMarkers.entries) {
      final other = takenMarkers[e.key];
      if (other != null) {
        return (
          newName: null,
          error: 'Track ${e.value.trackMarker} is already taken in '
              '"${e.value.title}" by "$other" — renumber that track '
              'first.',
          carriedPosterFile: null,
        );
      }
    }
  }
  await LibraryStore.save([
    for (final l in lists)
      l.copyWith(entries: [
        for (final e in l.entries)
          isMoved(e)
              ? MediaEntry(
                  name: renames[e.name]!,
                  address: e.address,
                  addedAt: e.addedAt,
                  sizeBytes: e.sizeBytes,
                  videoInfo: e.videoInfo,
                )
              : e,
      ]),
  ]);
  // Per-track override rows key on the album — move them along.
  for (final r in renames.entries) {
    final op = parseMediaName(r.key);
    final np = parseMediaName(r.value);
    final oldKey = trackLookupKey(op);
    final newKey = trackLookupKey(np);
    if (oldKey == null || newKey == null || oldKey == newKey) continue;
    final row = await metadataRowFor(oldKey);
    if (row == null) continue;
    final customName = episodeNameFromLabel(row.episodeLabel);
    await clearUserEdits(oldKey, postersDirProvider: postersDirProvider);
    if (customName != null) {
      await saveUserDetails(
        lookupKey: newKey,
        title: np.title,
        episodeLabel: Value('${np.trackMarker} · $customName'),
        postersDirProvider: postersDirProvider,
      );
    }
  }
  // Album artwork follows the rename when the target album has none —
  // a fresh copy under the new key (never a shared file, so clearing
  // one key's edits can't orphan the other's artwork).
  String? carried;
  final newParsed = parseMediaName(selfNewName);
  if (newParsed.lookupKey != parsed.lookupKey) {
    final oldRow = await metadataRowFor(parsed.lookupKey);
    final newRow = await metadataRowFor(newParsed.lookupKey);
    final oldPoster = oldRow?.posterFile;
    if (oldPoster != null && newRow?.posterFile == null) {
      final dir = await (postersDirProvider ?? defaultPostersDir)();
      final f = File('${dir.path}/$oldPoster');
      if (f.existsSync()) {
        carried = await saveUserPoster(
            newParsed.lookupKey, f.readAsBytesSync(),
            postersDirProvider: postersDirProvider);
      }
    }
  }
  return (newName: selfNewName, error: null, carriedPosterFile: carried);
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
