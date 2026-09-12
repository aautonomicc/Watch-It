import 'package:flutter/material.dart';

import '../services/organize.dart';
import '../theme/tokens.dart';

/// What the move-to-album dialog collects: the target album once for
/// the whole selection ([track] only when the dialog asked for one).
typedef AlbumTarget = ({String artist, String album, int? year, int? track});

/// Artist / Album / Year (and optionally a track number), asked once
/// for [count] files — the shared front half of every move-to-album
/// flow (Needs sorting, the track editor's move, the album page's
/// Edit-tracks bulk move). Validation lives in the dialog; the caller
/// gets a complete target or null.
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
                Navigator.of(context)
                    .pop((artist: a, album: b, year: y, track: n));
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
