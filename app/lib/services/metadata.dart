import 'package:watchit_naming/watchit_naming.dart';

import '../models/media_list.dart';

export 'package:watchit_naming/watchit_naming.dart'
    show
        ParsedName,
        parseMediaName,
        renumberedMusicFileName,
        realbumedMusicFileName,
        sanitizeNamePart;

/// Display metadata for a media entry: artwork, description, year,
/// category.
///
/// Three sources, best wins (see services/metadata_service.dart):
/// live TMDB match cached in SQLite, the small bundled catalog covering
/// the default test movie, and the parsed file name with no artwork.
class MediaMetadata {
  const MediaMetadata({
    required this.title,
    this.year,
    this.overview,
    this.category,
    this.episodeLabel,
    this.posterAsset,
    this.posterFilePath,
    this.rating,
    this.showOverview,
    this.seasonOverview,
    this.airDate,
    this.stillFilePath,
    this.showPosterFilePath,
    this.episodePosterFilePath,
    this.mediaType,
    this.artist,
    this.trackArtist,
  });

  final String title;
  final int? year;
  final String? overview;

  /// Genre names joined with ` · ` (e.g. `Horror · Thriller`), if matched.
  final String? category;

  /// `'movie'` or `'tv'` from the TMDB match; the fallback guesses from
  /// the file name (episode marker → `'tv'`). Drives the auto-by-type
  /// arrangement (services/library_arrangement.dart).
  final String? mediaType;

  /// For TV episodes: `S01E02 · Episode Name` (name when TMDB knows it).
  final String? episodeLabel;

  /// Bundled asset path (e.g. `assets/posters/notld_1968.jpg`), if any.
  final String? posterAsset;

  /// Locally cached artwork file downloaded from TMDB, if any.
  /// Season artwork for episode entries.
  final String? posterFilePath;

  /// TMDB community score out of 10; null when unrated/unmatched.
  final double? rating;

  /// Show/season synopses for episode entries ([overview] is then the
  /// episode's own synopsis).
  final String? showOverview;
  final String? seasonOverview;

  /// Episode air date / movie release date (`2008-01-20`), if known.
  final String? airDate;

  /// Cached episode screenshot file, if any (episode entries only).
  final String? stillFilePath;

  /// Cached show poster file for episode entries ([posterFilePath] is
  /// then the season's artwork).
  final String? showPosterFilePath;

  /// User-authored artwork for this entry only: an episode's own
  /// artwork (Edit details on the episode), or a music track's own
  /// artwork (Edit details on the track). Kept apart from
  /// [posterFilePath] — the season/album-art slot — so season tiles,
  /// album covers and headers, which read the first entry's metadata,
  /// never show one entry's artwork.
  final String? episodePosterFilePath;

  /// Music entries: the album artist ([title] is then the album name).
  /// From the shared album row when set (user-editable via Edit album
  /// details), else the parsed file name.
  final String? artist;

  /// Music tracks: this track's own credit — the per-track row's user
  /// override when set (Edit track details), else the artist parsed
  /// from the track's file name. Never leaks onto album surfaces,
  /// which keep reading [artist].
  final String? trackArtist;
}

/// XOR address of the built-in default movie seeded on first run — the
/// public-domain catalog's NOTLD upload (H.264 8-bit archive.org source,
/// uploaded 2026-08-07; part of kSeedLists in seed_catalog.dart).
const kDefaultMovieAddress =
    '442180e7d60e9a16bfaeb7f00aff6e47c754934986b9010f5f75e101ef4da20e';

/// File name of the built-in default movie as stored on the network.
/// Follows the Plex/Jellyfin naming convention
/// (`Title (Year) {imdb-ttXXXXXXX} - [quality].ext`) — see docs/NAMING.md.
const kDefaultMovieName =
    'Night of the Living Dead (1968) {imdb-tt0063350} - [1080p].mp4';

/// The genuine-1080p NOTLD upload (the 5.68GB H.264 re-encode that was
/// the default movie up to v0.1.0-alpha.47). Back in the seed catalog as
/// a second entry alongside [kDefaultMovieAddress] — same film, same
/// network file name, told apart by size/format info — so it must NOT be
/// listed in [kLegacyDefaultMovieAddresses].
const kDefaultMovie1080Address =
    '66cacd0604b01b2c2f1da1c1c3c05609d3b4cc448cff3b6cdd868e6b7eebcb13';

/// Stale addresses the default movie was seeded under in older releases;
/// migrated to [kDefaultMovieAddress] by [LibraryStore.ensureDefaults].
/// In order: up to v0.1.0-alpha.4 (dead upload), and the AV1 10-bit webm
/// used up to v0.1.0-alpha.15. The 5.68GB re-encode that followed is a
/// catalog entry again ([kDefaultMovie1080Address]), not a stale address.
const kLegacyDefaultMovieAddresses = [
  'ac855e1e8b17cb4ba0884a4e7025bd5f51d95ed69e4fa15ca37290496a400ea0',
  'cebd7965268b61d98907378670f13e55a2694064d0eed7ef4be9c19eaaf03988',
];

const _notld = MediaMetadata(
  title: 'Night of the Living Dead',
  year: 1968,
  overview:
      'Seven strangers barricade themselves inside a rural Pennsylvania '
      'farmhouse as the recently dead rise to feed on the living. George A. '
      'Romero’s landmark 1968 independent film invented the modern '
      'zombie genre and is now in the public domain.',
  posterAsset: 'assets/posters/notld_1968.jpg',
  mediaType: 'movie',
);

/// Bundled catalog, keyed by XOR address.
const _byAddress = <String, MediaMetadata>{
  kDefaultMovieAddress: _notld,
  kDefaultMovie1080Address: _notld,
};

/// Offline fallback metadata for [entry]. Always returns something
/// displayable: catalog hit by address, else a parsed title/year with no
/// artwork. Screens go through `MetadataService.instance.metadataFor`,
/// which upgrades this with the cached/live TMDB match.
MediaMetadata fallbackMetadataFor(MediaEntry entry) {
  final addr = entry.address.toLowerCase().replaceFirst('0x', '');
  final hit = _byAddress[addr];
  if (hit != null) return hit;
  final parsed = parseMediaName(entry.name);
  return MediaMetadata(
    title: parsed.title,
    year: parsed.year,
    episodeLabel: parsed.isEpisode
        ? 'S${parsed.season.toString().padLeft(2, '0')}'
            'E${parsed.episode.toString().padLeft(2, '0')}'
        : trackLabel(parsed),
    mediaType: parsed.isAudio
        ? 'music'
        : parsed.isEpisode
            ? 'tv'
            : 'movie',
    artist: parsed.artist,
  );
}

/// `05 · Track Title` label for a music track (the role the `SxxEyy`
/// label plays for episodes); null for everything else. The file name is
/// the only source — track numbers/titles have no metadata rows.
String? trackLabel(ParsedName parsed) =>
    parsed.isTrack ? '${parsed.trackMarker} · ${parsed.trackTitle}' : null;

/// Cache key for one track's user-authored label (`<albumKey>:tD-NN`) —
/// the slot a music track's own Edit details write to, overlaid onto the
/// shared album row like the show/season keys are for TV. Null for
/// non-tracks.
String? trackLookupKey(ParsedName parsed) => parsed.isTrack
    ? '${parsed.lookupKey}:t${parsed.disc ?? 1}-${parsed.track}'
    : null;

/// `2008-01-20` → `20 Jan 2008` for display; anything that is not an
/// ISO date passes through unchanged.
String formatAirDate(String date) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date);
  if (m == null) return date;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final month = int.parse(m.group(2)!);
  if (month < 1 || month > 12) return date;
  return '${int.parse(m.group(3)!)} ${months[month - 1]} ${m.group(1)}';
}

// ParsedName + parseMediaName moved to packages/watchit_naming
// (2026-09-01): the upload CLI generates names with the same package, so
// a name it writes always parses back to the intended title/year/ids
// here. Re-exported above — call sites are unchanged.
