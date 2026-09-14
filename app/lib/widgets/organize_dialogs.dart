import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../screens/album_picker_screen.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/organize.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';

/// What a move-to-album flow collects: the target album once for the
/// whole selection ([track] only when the flow asked for one). [mbid]
/// is set when an EXISTING album was picked and its tracks carry a
/// `{mbid-...}` tag — the renamed files must carry it too, or they
/// would fold into a second same-named album (AlbumKeys folds tagged
/// albums on the mbid, not the typed artist/album/year).
typedef AlbumTarget = ({
  String artist,
  String album,
  int? year,
  int? track,
  String? mbid,
});

/// The shared front half of every move-to-album flow (Needs sorting,
/// the track editor's move, the album page's Edit-tracks bulk move,
/// the detail page's Move-to-album action): a full-screen searchable
/// picker of the library's EXISTING albums ([AlbumPickerScreen]) whose
/// pinned "New album…" row falls through to the free-text
/// [askAlbumDialog]. Picking an existing album derives the target from
/// its own tracks' parsed names — artist/album/year/mbid — never from
/// re-typed text, so the moved files land in exactly that album.
///
/// [excludeAlbumOf] hides the album holding that entry (moving a track
/// "into" its own album is a no-op — the two inside-album surfaces
/// pass their current album's track). [askTrackNumber] adds the
/// optional target-number step (single-track moves).
Future<AlbumTarget?> pickAlbumTargetFlow(
  BuildContext context, {
  required int count,
  String? initialArtist,
  bool askTrackNumber = false,
  MediaEntry? excludeAlbumOf,
  List<MediaList>? lists,
}) async {
  final all = lists ?? await LibraryStore.load();
  // The album pool: every non-channel, non-playlist entry once
  // (playlists hold copies of entries that also live in a regular
  // list; channels mirror someone else's manifest).
  final seen = <(String, String)>{};
  final entries = <MediaEntry>[];
  for (final l in all) {
    if (l.isChannel || l.isPlaylist) continue;
    for (final e in l.entries) {
      if (seen.add((e.address.toLowerCase(), e.name))) entries.add(e);
    }
  }
  final excludeKey = excludeAlbumOf == null
      ? null
      : (excludeAlbumOf.address.toLowerCase(), excludeAlbumOf.name);
  bool holdsExcluded(HomeAlbum album) =>
      excludeKey != null &&
      album.tracks
          .any((tr) => (tr.address.toLowerCase(), tr.name) == excludeKey);
  final items = <HomeItem>[];
  for (final item in groupShows(entries)) {
    switch (item) {
      case HomeAlbum() when !holdsExcluded(item):
        items.add(item);
      case HomeArtist():
        final kept = [
          for (final album in item.albums)
            if (!holdsExcluded(album)) album,
        ];
        if (kept.length == item.albums.length) {
          items.add(item);
        } else if (kept.length == 1) {
          items.add(kept.single);
        } else if (kept.isNotEmpty) {
          items.add(HomeArtist(artist: item.artist, albums: kept));
        }
      default:
        break;
    }
  }
  if (!context.mounted) return null;
  final result = await Navigator.of(context).push<AlbumPickResult>(
    MaterialPageRoute(
        builder: (_) => AlbumPickerScreen(items: items, count: count)),
  );
  if (result == null || !context.mounted) return null;
  switch (result) {
    case NewAlbumPick(:final artistPrefill):
      return askAlbumDialog(context,
          count: count,
          initialArtist: artistPrefill ?? initialArtist,
          askTrackNumber: askTrackNumber);
    case ExistingAlbumPick(:final album):
      // Derive the target from the album's OWN tracks — a sample
      // track's parsed name carries the exact casing, and any track's
      // tag carries the fold's mbid.
      final sample = parseMediaName(album.tracks.first.name);
      String? mbid;
      for (final tr in album.tracks) {
        mbid = parseMediaName(tr.name).releaseMbid;
        if (mbid != null) break;
      }
      int? track;
      if (askTrackNumber) {
        final asked = await askTrackNumberDialog(context,
            album: album.album);
        if (asked == null) return null; // cancelled
        track = asked.track;
      }
      return (
        artist: album.isCompilation
            ? album.artist
            : (sample.artist ?? album.artist),
        album: sample.title,
        year: album.year ?? sample.year,
        track: track,
        mbid: mbid,
      );
  }
}

/// The optional target-track-number ask for a single-track move into
/// an EXISTING album (the free-text dialog carries its own field).
/// Null = cancelled; `(track: null)` = use the next free number.
Future<({int? track})?> askTrackNumberDialog(BuildContext context,
    {required String album}) {
  final track = TextEditingController();
  return showDialog<({int? track})>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      String? error;
      return StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Track number in "$album"',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: track,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: t.bone, fontSize: 14),
                  decoration: const InputDecoration(
                      labelText: 'Track number (optional)',
                      helperText:
                          'Empty = the next free number in that album.'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!,
                      style: TextStyle(color: t.rust, fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: t.ash)),
            ),
            FilledButton(
              onPressed: () {
                final nText = track.text.trim();
                final n = nText.isEmpty ? null : int.tryParse(nText);
                if (nText.isNotEmpty && n == null) {
                  setDialogState(
                      () => error = 'Track number must be a number.');
                  return;
                }
                Navigator.of(context).pop((track: n));
              },
              child: const Text('Continue'),
            ),
          ],
        );
      });
    },
  );
}

/// Artist / Album / Year (and optionally a track number), asked once
/// for [count] files — the NEW-album leg of [pickAlbumTargetFlow]
/// (existing albums are picked from [AlbumPickerScreen] instead of
/// typed). Validation lives in the dialog; the caller gets a complete
/// target or null.
Future<AlbumTarget?> askAlbumDialog(
  BuildContext context, {
  required int count,
  String? initialArtist,
  bool askTrackNumber = false,
}) {
  final artist = TextEditingController(text: initialArtist ?? '');
  final album = TextEditingController();
  final year = TextEditingController();
  final track = TextEditingController();
  return showDialog<AlbumTarget>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      String? error;
      return StatefulBuilder(builder: (context, setDialogState) {
        return AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Move ${count == 1 ? '1 file' : '$count files'} to album',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The files are renamed into the album, numbered '
                  'after its existing tracks. You\'ll see the new '
                  'names before anything changes.',
                  style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: artist,
                  autofocus: true,
                  style: TextStyle(color: t.bone, fontSize: 14),
                  decoration: const InputDecoration(labelText: 'Artist'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: album,
                  style: TextStyle(color: t.bone, fontSize: 14),
                  decoration: const InputDecoration(labelText: 'Album'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: year,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: t.bone, fontSize: 14),
                  decoration:
                      const InputDecoration(labelText: 'Year (optional)'),
                ),
                if (askTrackNumber) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: track,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: t.bone, fontSize: 14),
                    decoration: const InputDecoration(
                        labelText: 'Track number (optional)',
                        helperText:
                            'Empty = the next free number in that album.'),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!,
                      style: TextStyle(color: t.rust, fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: t.ash)),
            ),
            FilledButton(
              onPressed: () {
                final a = artist.text.trim();
                final b = album.text.trim();
                final yText = year.text.trim();
                final y = yText.isEmpty ? null : int.tryParse(yText);
                final nText = track.text.trim();
                final n = nText.isEmpty ? null : int.tryParse(nText);
                if (a.isEmpty || b.isEmpty) {
                  setDialogState(
                      () => error = 'Artist and album are both needed.');
                  return;
                }
                if (yText.isNotEmpty && y == null) {
                  setDialogState(() => error = 'Year must be a number.');
                  return;
                }
                if (nText.isNotEmpty && n == null) {
                  setDialogState(
                      () => error = 'Track number must be a number.');
                  return;
                }
                Navigator.of(context).pop(
                    (artist: a, album: b, year: y, track: n, mbid: null));
              },
              child: const Text('Preview new names'),
            ),
          ],
        );
      });
    },
  );
}

/// The before → after rename preview — nothing is renamed until Apply.
Future<bool?> confirmOrganizePlanDialog(
    BuildContext context, List<OrganizePlanItem> items) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      return AlertDialog(
        backgroundColor: t.ink2,
        title: Text(
            'Rename ${items.length == 1 ? '1 file' : '${items.length} files'}?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final it in items) ...[
                Text(it.entry.name,
                    style: TextStyle(
                        color: t.ash,
                        fontSize: 11.5,
                        fontFamily: wiMonoFamily,
                        fontFamilyFallback: wiMonoFallback)),
                Padding(
                  padding: const EdgeInsets.only(top: 1, bottom: 8),
                  child: Text('→  ${it.newName}',
                      style: TextStyle(
                          color: t.bone,
                          fontSize: 11.5,
                          fontFamily: wiMonoFamily,
                          fontFamilyFallback: wiMonoFallback)),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply'),
          ),
        ],
      );
    },
  );
}

/// Confirm taking [count] tracks out of their album — each file is
/// renamed to just its title and becomes a standalone audio file.
Future<bool?> confirmUnalbumDialog(BuildContext context, int count) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      return AlertDialog(
        backgroundColor: t.ink2,
        title: Text(
            count == 1
                ? 'Remove this track from its album?'
                : 'Remove $count tracks from the album?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The file is renamed to just its title, so it leaves the '
          'album and becomes a standalone audio file (it shows up under '
          'Needs sorting, ready to move into another album later). '
          'Nothing is deleted — playback, downloads, and playlists are '
          'unaffected.',
          style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(count == 1 ? 'Remove track' : 'Remove all'),
          ),
        ],
      );
    },
  );
}
