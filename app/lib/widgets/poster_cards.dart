import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import 'download_badge.dart';
import 'watch_progress.dart';

/// Wall card for a single (non-episode) entry: poster with watch bar and
/// download badge, title/year underneath. Shared by the home shelves and
/// the per-list browse grid.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.entry,
    required this.tokens,
    required this.onTap,
    this.versionCount = 1,
  });

  final MediaEntry entry;
  final WiTokens tokens;
  final VoidCallback onTap;

  /// Number of uploads of this title folded into the card (see
  /// [HomeEntry.versions]); above 1 the info line reads `2 versions`
  /// instead of one upload's format — the detail page's version picker
  /// tells them apart.
  final int versionCount;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final meta = MetadataService.instance.metadataFor(entry);
    final badge = entryDownloadBadge(t, entry);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 180,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    entryPosterImage(meta, fit: BoxFit.cover) ??
                        Container(
                          color: t.ink2,
                          child: Icon(Icons.movie_outlined,
                              color: t.ash, size: 40),
                        ),
                    ?entryWatchBar(t, entry),
                    ?badge,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              meta.year != null ? '${meta.title} (${meta.year})' : meta.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
            // Format/size of this upload — or, when several uploads of
            // the title are folded into this one card, the version count.
            if (versionCount > 1
                    ? '$versionCount versions'
                    : formatInfoLine(entry)
                case final line?)
              Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: t.ash),
              ),
          ],
        ),
      ),
    );
  }
}

/// An album folded into one wall card: square cover art (music covers
/// are 1:1, not the 2:3 poster shape) with the album title and
/// artist/track count underneath. Tap opens the album page, which lists
/// the tracks.
class AlbumCard extends StatelessWidget {
  const AlbumCard({
    super.key,
    required this.group,
    required this.tokens,
    required this.onTap,
  });

  final HomeAlbum group;
  final WiTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // Any track's match carries the album title and cover art.
    final meta = MetadataService.instance.metadataFor(group.tracks.first);
    final n = group.tracks.length;
    final badge = groupDownloadBadge(t, group.tracks);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    posterImage(meta, fit: BoxFit.cover) ??
                        Container(
                          color: t.ink2,
                          child: Icon(Icons.album_outlined,
                              color: t.ash, size: 40),
                        ),
                    ?badge,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              meta.title.isEmpty ? group.album : meta.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
            Text(
              // A user-set album credit (Edit album details) beats
              // everything; else a compilation's group credit beats any
              // single track's row.
              '${meta.albumArtist ?? (group.isCompilation ? group.artist : meta.artist ?? group.artist)} · $n '
              '${n == 1 ? 'track' : 'tracks'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: t.ash),
            ),
          ],
        ),
      ),
    );
  }
}

/// All of an artist's albums folded into one wall card (the music mirror
/// of [ShowCard]): an adaptive collage of album covers — each album
/// shown once (halves for 2, a half plus two quarters for 3, a 2×2 grid
/// for 4+) — with the artist name and album/track counts underneath.
/// Tap opens the artist page, which lists the albums.
class ArtistCard extends StatelessWidget {
  const ArtistCard({
    super.key,
    required this.group,
    required this.tokens,
    required this.onTap,
  });

  final HomeArtist group;
  final WiTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // A user-corrected artist credit (Edit track details) beats the
    // parsed name, same as on AlbumCard.
    final meta =
        MetadataService.instance.metadataFor(group.albums.first.tracks.first);
    final albums = group.albums;
    final tracks = group.trackCount;
    final badge =
        groupDownloadBadge(t, [for (final a in albums) ...a.tracks]);
    // One collage cell showing one album's cover — each album appears
    // exactly once; the layout below adapts to how many there are.
    Widget cell(int i) {
      final m = MetadataService.instance.metadataFor(albums[i].tracks.first);
      return Expanded(
        child: posterImage(m, fit: BoxFit.cover) ??
            Container(
              color: t.ink2,
              child: Icon(Icons.album_outlined, color: t.ash, size: 20),
            ),
      );
    }

    // Adaptive collage: 2 albums = side-by-side halves, 3 = one
    // full-height half plus two stacked quarters, 4+ = a 2×2 grid of
    // the first four.
    final collage = switch (albums.length) {
      1 => Row(children: [cell(0)]),
      2 => Row(children: [
          cell(0),
          const SizedBox(width: 1),
          cell(1),
        ]),
      3 => Row(children: [
          cell(0),
          const SizedBox(width: 1),
          Expanded(
              child: Column(children: [
            cell(1),
            const SizedBox(height: 1),
            cell(2),
          ])),
        ]),
      _ => Column(children: [
          Expanded(
              child: Row(children: [
            cell(0),
            const SizedBox(width: 1),
            cell(1),
          ])),
          const SizedBox(height: 1),
          Expanded(
              child: Row(children: [
            cell(2),
            const SizedBox(width: 1),
            cell(3),
          ])),
        ]),
    };

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    collage,
                    ?badge,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              meta.artist ?? group.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
            Text(
              '${albums.length} albums · $tracks tracks',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: t.ash),
            ),
          ],
        ),
      ),
    );
  }
}

/// A whole show folded into one wall card: the show's main poster with
/// its name and season/episode counts underneath. Tap opens the show
/// page, which lists the seasons.
class ShowCard extends StatelessWidget {
  const ShowCard({
    super.key,
    required this.group,
    required this.tokens,
    required this.onTap,
  });

  final HomeShow group;
  final WiTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // Any episode's match carries the show title and show artwork.
    final meta = MetadataService.instance
        .metadataFor(group.seasons.first.episodes.first);
    final seasons = group.seasons.length;
    final count = group.episodeCount;
    final badge = groupDownloadBadge(
        t, [for (final s in group.seasons) ...s.episodes]);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 180,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    showPosterImage(meta, fit: BoxFit.cover) ??
                        Container(
                          color: t.ink2,
                          child: Icon(Icons.live_tv_outlined,
                              color: t.ash, size: 40),
                        ),
                    ?badge,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              meta.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
            Text(
              seasons == 1
                  ? 'Season ${group.seasons.single.season} · $count ep'
                  : '$seasons seasons · $count ep',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: t.ash),
            ),
          ],
        ),
      ),
    );
  }
}
