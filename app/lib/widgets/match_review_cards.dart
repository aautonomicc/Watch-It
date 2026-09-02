import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:watchit_upload/watchit_upload.dart' hide MediaProbe;

import '../services/match_review.dart';
import '../theme/tokens.dart';

/// The match-review confirm cards, shared by the Batch upload screen
/// and the datamap Import review screen. Every button funnels through
/// the [MatchReviewSession] actions; the session's label getters adapt
/// the wording (an upload's "Skip file" is an import's "Don't add").

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}

/// One file's confirm card: the proposed match (or NO MATCH FOUND) with
/// accept/search/paste-id/manual-details/type-flip/reject/skip.
class MatchConfirmCard extends StatelessWidget {
  const MatchConfirmCard(
      {super.key, required this.session, required this.confirm});

  final MatchReviewSession session;
  final BatchConfirm confirm;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final outcome = confirm.outcome;
    final art = outcome.artBytes;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.ink2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(outcome.matched ? 'CONFIRM MATCH' : 'NO MATCH FOUND',
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: t.accent)),
          const SizedBox(height: 8),
          Text(p.basename(confirm.path),
              style: TextStyle(color: t.boneDim, fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (art != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.memory(Uint8List.fromList(art),
                      width: 72, fit: BoxFit.contain),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (outcome.note != null)
                      Text(outcome.note!,
                          style: TextStyle(color: t.bone, fontSize: 14)),
                    if (outcome.name != null) ...[
                      const SizedBox(height: 4),
                      Text('→ ${outcome.name}',
                          style: TextStyle(
                              color: t.boneDim,
                              fontSize: 12,
                              fontFamily: wiMonoFamily,
                              fontFamilyFallback: wiMonoFallback)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (confirm.mbHits != null) _mbHitList(t),
          if (confirm.tmdbHits != null) _tmdbHitList(t),
          const SizedBox(height: 12),
          if (confirm.busy)
            const LinearProgressIndicator()
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (outcome.matched)
                  FilledButton(
                    onPressed: session.confirmAccept,
                    child: const Text('Use this match'),
                  ),
                OutlinedButton(
                  onPressed: () => _manualSearchDialog(context),
                  child: const Text('Search…'),
                ),
                OutlinedButton(
                  onPressed: () => _pasteIdDialog(context),
                  child: const Text('Paste ID…'),
                ),
                OutlinedButton(
                  onPressed: () => _manualEntryDialog(context),
                  child: const Text('Enter details…'),
                ),
                OutlinedButton(
                  onPressed: () => session.confirmToggleType(),
                  child: Text(outcome.type == 'music'
                      ? 'Treat as video'
                      : 'Treat as music'),
                ),
                TextButton(
                  onPressed: session.confirmReject,
                  child: Text(session.rejectFileLabel,
                      style: TextStyle(color: t.rust)),
                ),
                TextButton(
                  onPressed: session.confirmSkip,
                  child: Text(session.skipFileLabel,
                      style: TextStyle(color: t.ash)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _mbHitList(WiTokens t) {
    final hits = confirm.mbHits!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (hits.isEmpty)
          Text('No results.', style: TextStyle(color: t.ash, fontSize: 12)),
        for (final hit in hits)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${hit.artist} — ${hit.title}'
              '${hit.year != null ? ' (${hit.year})' : ''}',
              style: TextStyle(color: t.bone, fontSize: 13),
            ),
            onTap: () => session.confirmPickMb(hit.mbid),
          ),
      ],
    );
  }

  Widget _tmdbHitList(WiTokens t) {
    final hits = confirm.tmdbHits!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (hits.isEmpty)
          Text('No results.', style: TextStyle(color: t.ash, fontSize: 12)),
        for (final hit in hits)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${hit.title}${hit.year != null ? ' (${hit.year})' : ''} '
              '· ${hit.mediaType}',
              style: TextStyle(color: t.bone, fontSize: 13),
            ),
            onTap: () => session.confirmPickTmdb(hit.tmdbId,
                tv: hit.mediaType == 'tv'),
          ),
      ],
    );
  }

  Future<void> _manualSearchDialog(BuildContext context) async {
    final t = WiTokens.of(context);
    if (confirm.outcome.type == 'music') {
      final artist = TextEditingController(
          text: '${confirm.outcome.sidecarDefaults['artist'] ?? ''}');
      final album = TextEditingController(
          text: '${confirm.outcome.sidecarDefaults['album'] ?? ''}');
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Search MusicBrainz',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: artist,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Artist')),
              TextField(
                  controller: album,
                  decoration: const InputDecoration(labelText: 'Album')),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash))),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Search', style: TextStyle(color: t.accent))),
          ],
        ),
      );
      if (ok == true && artist.text.trim().isNotEmpty) {
        await session.confirmSearchMusic(
            artist.text.trim(), album.text.trim());
      }
      return;
    }
    final title = TextEditingController(
        text: '${confirm.outcome.sidecarDefaults['title'] ?? ''}');
    final year = TextEditingController(
        text: '${confirm.outcome.sidecarDefaults['year'] ?? ''}');
    var tv = confirm.outcome.sidecarDefaults['season'] != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Search TMDB',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: title,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Title')),
              TextField(
                  controller: year,
                  decoration:
                      const InputDecoration(labelText: 'Year (optional)')),
              CheckboxListTile(
                value: tv,
                contentPadding: EdgeInsets.zero,
                title: Text('TV show',
                    style: TextStyle(color: t.bone, fontSize: 14)),
                onChanged: (v) =>
                    setDialogState(() => tv = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash))),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Search', style: TextStyle(color: t.accent))),
          ],
        ),
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await session.confirmSearchVideo(title.text.trim(),
          year: int.tryParse(year.text.trim()), tv: tv);
    }
  }

  Future<void> _pasteIdDialog(BuildContext context) async {
    final t = WiTokens.of(context);
    final raw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title:
            Text('Paste an ID', style: TextStyle(color: t.bone, fontSize: 16)),
        content: TextField(
          controller: raw,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'ID or URL',
            helperText: 'MusicBrainz release, IMDb tt…, or '
                'tmdb movie:N / tv:N',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.ash))),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Use', style: TextStyle(color: t.accent))),
        ],
      ),
    );
    if (ok == true && raw.text.trim().isNotEmpty) {
      final recognized = await session.confirmPasteId(raw.text.trim());
      if (!recognized && context.mounted) {
        _snack(context, 'Not a recognizable ID');
      }
    }
  }

  Future<void> _manualEntryDialog(BuildContext context) async {
    final t = WiTokens.of(context);
    final defaults = confirm.outcome.sidecarDefaults;
    var music = confirm.outcome.type == 'music';
    final title = TextEditingController(text: '${defaults['title'] ?? ''}');
    final year = TextEditingController(text: '${defaults['year'] ?? ''}');
    final artist =
        TextEditingController(text: '${defaults['artist'] ?? ''}');
    final album = TextEditingController(text: '${defaults['album'] ?? ''}');
    final track = TextEditingController(text: '${defaults['track'] ?? ''}');
    final season =
        TextEditingController(text: '${defaults['season'] ?? ''}');
    final episode =
        TextEditingController(text: '${defaults['episode'] ?? ''}');
    final description = TextEditingController();
    String? artPath;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Enter details',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: SizedBox(
            width: 380,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  session.manualEntryBlurb,
                  style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                        value: false,
                        label: Text('Video'),
                        icon: Icon(Icons.movie_outlined, size: 16)),
                    ButtonSegment(
                        value: true,
                        label: Text('Music'),
                        icon: Icon(Icons.music_note_outlined, size: 16)),
                  ],
                  selected: {music},
                  onSelectionChanged: (sel) =>
                      setDialogState(() => music = sel.first),
                ),
                if (music) ...[
                  TextField(
                      controller: artist,
                      decoration:
                          const InputDecoration(labelText: 'Artist')),
                  TextField(
                      controller: album,
                      decoration: const InputDecoration(labelText: 'Album')),
                  TextField(
                      controller: title,
                      decoration:
                          const InputDecoration(labelText: 'Track title')),
                  TextField(
                      controller: track,
                      decoration:
                          const InputDecoration(labelText: 'Track number')),
                ] else ...[
                  TextField(
                      controller: title,
                      decoration: const InputDecoration(labelText: 'Title')),
                  TextField(
                      controller: season,
                      decoration: const InputDecoration(
                          labelText: 'Season (optional)')),
                  TextField(
                      controller: episode,
                      decoration: const InputDecoration(
                          labelText: 'Episode (optional)')),
                ],
                TextField(
                    controller: year,
                    decoration:
                        const InputDecoration(labelText: 'Year (optional)')),
                TextField(
                    controller: description,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Description (optional)')),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final file = await openFile(acceptedTypeGroups: [
                          const XTypeGroup(label: 'Images', extensions: [
                            'jpg', 'jpeg', 'png', 'webp',
                          ]),
                        ]);
                        if (file != null) {
                          setDialogState(() => artPath = file.path);
                        }
                      },
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(artPath == null
                          ? 'Artwork from file…'
                          : 'Change artwork…'),
                    ),
                    if (artPath != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(p.basename(artPath!),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.boneDim, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash))),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Save', style: TextStyle(color: t.accent))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (title.text.trim().isEmpty) {
      if (context.mounted) {
        _snack(
            context, music ? 'A track title is needed' : 'A title is needed');
      }
      return;
    }
    await session.confirmManual(Sidecar(
      type: music ? 'music' : 'video',
      title: title.text.trim(),
      year: int.tryParse(year.text.trim()),
      artist: artist.text.trim().isEmpty ? null : artist.text.trim(),
      album: album.text.trim().isEmpty ? null : album.text.trim(),
      track: int.tryParse(track.text.trim()),
      season: int.tryParse(season.text.trim()),
      episode: int.tryParse(episode.text.trim()),
      description:
          description.text.trim().isEmpty ? null : description.text.trim(),
      art: artPath,
    ));
  }
}

/// One card for a whole album: the release decision applies to every
/// track, so a rip is reviewed in one look instead of track by track.
class AlbumMatchConfirmCard extends StatelessWidget {
  const AlbumMatchConfirmCard(
      {super.key, required this.session, required this.confirm});

  final MatchReviewSession session;
  final AlbumConfirm confirm;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final album = confirm.album;
    final art = album?.artBytes;
    final placed =
        confirm.outcomes.where((o) => o?.matched ?? false).length;
    final total = confirm.tracks.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.ink2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(album != null ? 'CONFIRM ALBUM MATCH' : 'NO ALBUM MATCH',
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: t.accent)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (art != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.memory(Uint8List.fromList(art),
                      width: 72, fit: BoxFit.contain),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (confirm.albumLine != null)
                      Text(confirm.albumLine!,
                          style: TextStyle(color: t.bone, fontSize: 14)),
                    if (album == null)
                      Text(
                          'These files look like one album, but no '
                          'release matched. Search MusicBrainz, paste a '
                          'release ID, or enter the details once for all '
                          'of them.',
                          style: TextStyle(
                              color: t.bone, fontSize: 13, height: 1.4)),
                    const SizedBox(height: 4),
                    Text(
                        '$placed of $total tracks placed'
                        '${placed < total && album != null ? ' — unplaced tracks are set aside for another pass' : ''}',
                        style: TextStyle(color: t.boneDim, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < confirm.tracks.length; i++)
            _albumTrackRow(t, i),
          if (confirm.mbHits != null) _albumMbHitList(t),
          const SizedBox(height: 12),
          if (confirm.busy)
            const LinearProgressIndicator()
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (album != null)
                  FilledButton(
                    onPressed: session.albumAccept,
                    child: Text('Use for all '
                        '$placed track${placed == 1 ? '' : 's'}'),
                  ),
                OutlinedButton(
                  onPressed: () => _albumSearchDialog(context),
                  child: const Text('Search…'),
                ),
                OutlinedButton(
                  onPressed: () => _albumPasteIdDialog(context),
                  child: const Text('Paste ID…'),
                ),
                OutlinedButton(
                  onPressed: () => _albumManualDialog(context),
                  child: const Text('Enter details…'),
                ),
                TextButton(
                  onPressed: session.albumReject,
                  child: Text(session.rejectAlbumLabel,
                      style: TextStyle(color: t.rust)),
                ),
                TextButton(
                  onPressed: session.albumSkip,
                  child: Text(session.skipAlbumLabel,
                      style: TextStyle(color: t.ash)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _albumTrackRow(WiTokens t, int i) {
    final out = confirm.outcomes[i];
    final ok = out?.matched ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check : Icons.help_outline,
              size: 14, color: ok ? t.signalOk : t.rust),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              ok
                  ? out!.name!
                  : '${p.basename(confirm.tracks[i])} — not placed',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: ok ? t.boneDim : t.rust,
                  fontSize: 12,
                  fontFamily: ok ? wiMonoFamily : null,
                  fontFamilyFallback: ok ? wiMonoFallback : null),
            ),
          ),
        ],
      ),
    );
  }

  Widget _albumMbHitList(WiTokens t) {
    final hits = confirm.mbHits!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (hits.isEmpty)
          Text('No results.', style: TextStyle(color: t.ash, fontSize: 12)),
        for (final hit in hits)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${hit.artist} — ${hit.title}'
              '${hit.year != null ? ' (${hit.year})' : ''}',
              style: TextStyle(color: t.bone, fontSize: 13),
            ),
            onTap: () => session.albumPickMb(hit.mbid),
          ),
      ],
    );
  }

  Future<void> _albumSearchDialog(BuildContext context) async {
    final t = WiTokens.of(context);
    final artist = TextEditingController(
        text: '${confirm.defaults['artist'] ?? ''}');
    final album =
        TextEditingController(text: '${confirm.defaults['album'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Search MusicBrainz',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: artist,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Artist')),
            TextField(
                controller: album,
                decoration: const InputDecoration(labelText: 'Album')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.ash))),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Search', style: TextStyle(color: t.accent))),
        ],
      ),
    );
    if (ok == true && artist.text.trim().isNotEmpty) {
      await session.albumSearch(artist.text.trim(), album.text.trim());
    }
  }

  Future<void> _albumPasteIdDialog(BuildContext context) async {
    final t = WiTokens.of(context);
    final raw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title:
            Text('Paste an ID', style: TextStyle(color: t.bone, fontSize: 16)),
        content: TextField(
          controller: raw,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'ID or URL',
            helperText: 'MusicBrainz release ID or URL — applied to '
                'every track of the album',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.ash))),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Use', style: TextStyle(color: t.accent))),
        ],
      ),
    );
    if (ok == true && raw.text.trim().isNotEmpty) {
      final recognized = await session.albumPasteId(raw.text.trim());
      if (!recognized && context.mounted) {
        _snack(context, 'Not a MusicBrainz release ID');
      }
    }
  }

  /// Case B for a whole album: artist/album/year/artwork entered once,
  /// track titles and numbers from each file's tags or name.
  Future<void> _albumManualDialog(BuildContext context) async {
    final t = WiTokens.of(context);
    final artist = TextEditingController(
        text: '${confirm.defaults['artist'] ?? ''}');
    final album =
        TextEditingController(text: '${confirm.defaults['album'] ?? ''}');
    final year =
        TextEditingController(text: '${confirm.defaults['year'] ?? ''}');
    final description = TextEditingController();
    String? artPath;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Enter album details',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: SizedBox(
            width: 380,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  'For an album not in any database — one entry covers '
                  'all ${confirm.tracks.length} tracks; each track keeps '
                  'its own title and number from its tags or file name.',
                  style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: artist,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Artist')),
                TextField(
                    controller: album,
                    decoration: const InputDecoration(labelText: 'Album')),
                TextField(
                    controller: year,
                    decoration:
                        const InputDecoration(labelText: 'Year (optional)')),
                TextField(
                    controller: description,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Description (optional)')),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final file = await openFile(acceptedTypeGroups: [
                          const XTypeGroup(label: 'Images', extensions: [
                            'jpg', 'jpeg', 'png', 'webp',
                          ]),
                        ]);
                        if (file != null) {
                          setDialogState(() => artPath = file.path);
                        }
                      },
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(artPath == null
                          ? 'Artwork from file…'
                          : 'Change artwork…'),
                    ),
                    if (artPath != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(p.basename(artPath!),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.boneDim, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash))),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Save', style: TextStyle(color: t.accent))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (artist.text.trim().isEmpty || album.text.trim().isEmpty) {
      if (context.mounted) _snack(context, 'Artist and album are needed');
      return;
    }
    await session.albumManual(
      artist: artist.text.trim(),
      album: album.text.trim(),
      year: int.tryParse(year.text.trim()),
      description:
          description.text.trim().isEmpty ? null : description.text.trim(),
      artPath: artPath,
    );
  }
}
