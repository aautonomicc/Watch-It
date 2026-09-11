import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;

import '../models/media_list.dart';
import 'library_store.dart';
import 'metadata.dart';
import 'user_metadata.dart';

/// Organizing music: renaming audio entries into the
/// `Artist - Album (Year) - NN Title` convention. Albums are file-name
/// folds (season_grouping.dart), so an audio file whose name does not
/// parse as a track belongs to NO album and its "album" edits used to
/// change nothing — the fix is renaming the file so it folds naturally.
/// The entry's address never changes: playback, downloads, watch state
/// and the upload ledger never notice a rename.

/// True when [entry] is audio that does NOT parse as a music-convention
/// track — the "needs sorting" population (unidentified tracks, mixes,
/// anything hand-named outside the convention).
bool isUnsortedAudio(MediaEntry entry) {
  final p = parseMediaName(entry.name);
  return p.isAudio && !p.isTrack;
}

/// Every unsorted audio entry across the library's own lists (channels
/// mirror someone else's manifest and are read-only; playlists hold
/// copies of entries that also live in a regular list), deduplicated by
/// (address, name) and sorted by name.
List<MediaEntry> unsortedAudioEntries(List<MediaList> lists) {
  final seen = <(String, String)>{};
  final out = <MediaEntry>[];
  for (final l in lists) {
    if (l.isChannel || l.isPlaylist) continue;
    for (final e in l.entries) {
      if (!isUnsortedAudio(e)) continue;
      if (seen.add((e.address.toLowerCase(), e.name))) out.add(e);
    }
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// The audio extension of [name] (with the dot), or `.mp3` as a last
/// resort — the renamed file keeps its own extension.
String audioExtensionOf(String name) {
  final m = RegExp(r'\.(flac|mp3|ogg|oga|opus|m4a|wav|aac|wma)$',
          caseSensitive: false)
      .firstMatch(name);
  return m == null ? '.mp3' : m.group(0)!;
}

/// The highest track number any library track claims in the album
/// [album] ([year]) — artist-agnostic, like the wall's album fold — so
/// bulk moves can continue numbering after the existing tracks. 0 when
/// the album holds nothing yet.
int highestTrackNumberIn(List<MediaList> lists,
    {required String album, int? year}) {
  final albumLower = album.trim().toLowerCase();
  var highest = 0;
  for (final l in lists) {
    if (l.isChannel) continue;
    for (final e in l.entries) {
      final p = parseMediaName(e.name);
      if (!p.isTrack) continue;
      if (p.title.trim().toLowerCase() != albumLower) continue;
      if (year != null && p.year != null && p.year != year) continue;
      if (p.track! > highest) highest = p.track!;
    }
  }
  return highest;
}

/// One planned rename: [entry] under its new convention name.
typedef OrganizePlanItem = ({MediaEntry entry, String newName});

/// The outcome of planning a move-to-album: the renames to apply, or
/// the message explaining why the plan is impossible.
typedef OrganizePlan = ({List<OrganizePlanItem> items, String? error});

/// Plan renaming [selection] (any audio entries, in order) into the
/// album [album] ([artist], [year]): track numbers continue after the
/// album's existing tracks — or use [startTrack]/explicit [tracks] when
/// given — and each entry's track title is its user-edited display
/// title when one exists, else the title parsed from its file name.
///
/// Nothing is written; [applyOrganize] executes the plan. The plan
/// refuses (error) when a name cannot be generated losslessly or a
/// target track number is already taken by an entry outside the
/// selection.
Future<OrganizePlan> planOrganize(
  List<MediaEntry> selection, {
  required String artist,
  required String album,
  int? year,
  List<int>? tracks,
  List<String?>? titles,
  List<MediaList>? lists,
}) async {
  if (selection.isEmpty) {
    return (items: const <OrganizePlanItem>[], error: 'Nothing selected.');
  }
  final all = lists ?? await LibraryStore.load();
  final cleanArtist = sanitizeNamePart(artist);
  final cleanAlbum = sanitizeNamePart(album);
  if (cleanArtist.isEmpty || cleanAlbum.isEmpty) {
    return (
      items: const <OrganizePlanItem>[],
      error: 'Artist and album are both needed.'
    );
  }
  // Numbers already taken in the target album by entries OUTSIDE the
  // selection (a selected entry vacates its own number).
  final selected = {
    for (final e in selection) (e.address.toLowerCase(), e.name),
  };
  final albumLower = cleanAlbum.trim().toLowerCase();
  final taken = <int, String>{};
  for (final l in all) {
    if (l.isChannel) continue;
    for (final e in l.entries) {
      if (selected.contains((e.address.toLowerCase(), e.name))) continue;
      final p = parseMediaName(e.name);
      if (!p.isTrack || p.title.trim().toLowerCase() != albumLower) {
        continue;
      }
      if (year != null && p.year != null && p.year != year) continue;
      taken[p.track!] = p.trackTitle!;
    }
  }
  var next = (taken.keys.isEmpty ? 0 : taken.keys.reduce((a, b) => a > b ? a : b)) + 1;
  final items = <OrganizePlanItem>[];
  for (final (i, entry) in selection.indexed) {
    final parsed = parseMediaName(entry.name);
    if (!parsed.isAudio) {
      return (
        items: const <OrganizePlanItem>[],
        error: '"${entry.name}" is not an audio file.'
      );
    }
    int number;
    if (tracks != null) {
      number = tracks[i];
      final holder = taken[number];
      if (holder != null) {
        return (
          items: const <OrganizePlanItem>[],
          error: 'Track ${number.toString().padLeft(2, '0')} is already '
              'taken in this album by "$holder" — pick another number.'
        );
      }
    } else {
      number = next++;
    }
    taken[number] = parsed.trackTitle ?? parsed.title;
    // The caller's title override first (the editor's typed title),
    // else a user-edited display title (the old workaround for
    // unrenamable files) — either becomes the real track title in the
    // new file name; last resort is the title parsed from the name.
    var trackTitle = parsed.trackTitle ?? parsed.title;
    final override = titles?[i]?.trim();
    if (override != null && override.isNotEmpty) {
      trackTitle = override;
    } else {
      final row = await metadataRowFor(parsed.lookupKey);
      if (!parsed.isTrack &&
          (row?.userEdited ?? false) &&
          (row!.title ?? '').trim().isNotEmpty) {
        trackTitle = row.title!.trim();
      }
    }
    final newName = musicFileName(
      artist: cleanArtist,
      album: cleanAlbum,
      year: year,
      track: number,
      title: trackTitle,
      ext: audioExtensionOf(entry.name),
    );
    final check = parseMediaName(newName);
    if (!check.isTrack || check.track != number) {
      return (
        items: const <OrganizePlanItem>[],
        error: '"${entry.name}" cannot be renamed into the track naming '
            'convention.'
      );
    }
    items.add((entry: entry, newName: newName));
  }
  return (items: items, error: null);
}

/// Execute [items]: rename each entry everywhere the library holds it
/// (same name + address, in any list — playlists included, so playlist
/// rows follow the rename), stamping the rename for My W@tch sync, and
/// migrate each entry's old user-edited metadata row (description /
/// artwork saved while the file was unsorted) onto its new track key.
/// Returns how many entries were renamed.
Future<int> applyOrganize(
  List<OrganizePlanItem> items, {
  Future<Directory> Function()? postersDirProvider,
}) async {
  if (items.isEmpty) return 0;
  final renames = <(String, String), String>{
    for (final it in items)
      (it.entry.address.toLowerCase(), it.entry.name): it.newName,
  };
  final lists = await LibraryStore.load();
  var renamedCount = 0;
  final updated = [
    for (final l in lists)
      l.copyWith(entries: [
        for (final e in l.entries)
          switch (renames[(e.address.toLowerCase(), e.name)]) {
            null => e,
            final newName => () {
                renamedCount++;
                return e.renamed(newName);
              }(),
          },
      ]),
  ];
  await LibraryStore.save(updated);
  for (final it in items) {
    final oldParsed = parseMediaName(it.entry.name);
    final newParsed = parseMediaName(it.newName);
    await _migrateUnsortedRow(
      oldKey: oldParsed.lookupKey,
      newParsed: newParsed,
      postersDirProvider: postersDirProvider,
    );
  }
  return renamedCount;
}

/// Carry an unsorted entry's user row (custom description/artwork under
/// its old `movie:`-style key) onto the renamed track's own row, then
/// clear the old key. The custom title already became the file name's
/// track title in [planOrganize]; description and artwork move here.
Future<void> _migrateUnsortedRow({
  required String oldKey,
  required ParsedName newParsed,
  Future<Directory> Function()? postersDirProvider,
}) async {
  final trackKey = trackLookupKey(newParsed);
  if (trackKey == null || oldKey == trackKey) return;
  final row = await metadataRowFor(oldKey);
  if (row == null || !row.userEdited) return;
  final overview = row.overview;
  var posterBytes = <int>[];
  if (row.posterFile != null) {
    final dir = await (postersDirProvider ?? defaultPostersDir)();
    final f = File('${dir.path}/${row.posterFile}');
    if (f.existsSync()) posterBytes = f.readAsBytesSync();
  }
  await clearUserEdits(oldKey, postersDirProvider: postersDirProvider);
  if ((overview == null || overview.trim().isEmpty) && posterBytes.isEmpty) {
    return;
  }
  Value<String?> poster = const Value.absent();
  if (posterBytes.isNotEmpty) {
    poster = Value(await saveUserPoster(
        trackKey, Uint8List.fromList(posterBytes),
        postersDirProvider: postersDirProvider));
  }
  await saveUserDetails(
    lookupKey: trackKey,
    title: newParsed.title,
    overview: overview,
    posterFile: poster,
    postersDirProvider: postersDirProvider,
  );
}
