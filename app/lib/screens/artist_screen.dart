import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/artist_info.dart';
import '../services/download_manager.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import '../widgets/messenger.dart';
import '../widgets/poster_cards.dart';
import 'album_screen.dart';

/// One artist: portrait, facts and bio on top (keyless MusicBrainz →
/// Wikidata → Wikipedia chain via [ArtistInfoService], pulled once and
/// cached — the page renders offline from the cache), then every album
/// of theirs in the list as square cover tiles, sorted by year. Tapping
/// an album opens its [AlbumScreen] — the music mirror of ShowScreen's
/// show → season → episode drill-down.
class ArtistScreen extends StatelessWidget {
  const ArtistScreen({super.key, required this.group});

  /// The artist's albums as folded by [groupShows]; never fewer than
  /// two.
  final HomeArtist group;

  /// The `{mbid-...}` release tags on the artist's tracks — the artist
  /// lookup's identity signal (a release names its artist exactly;
  /// name search is the collision-prone fallback).
  List<String> get _releaseMbids => [
        for (final album in group.albums)
          for (final track in album.tracks)
            if (parseMediaName(track.name).releaseMbid != null)
              parseMediaName(track.name).releaseMbid!,
      ];

  @override
  Widget build(BuildContext context) {
    // Rebuild as CAA covers land in the cache, as downloads change the
    // album tiles' badges, and as the artist info chain resolves.
    return ListenableBuilder(
      listenable: Listenable.merge([
        MetadataService.instance,
        DownloadManager.instance,
        ArtistInfoService.instance,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  Future<void> _refresh(BuildContext context, String displayName) async {
    try {
      await ArtistInfoService.instance.refresh(
        group.artist,
        displayName: displayName,
        releaseMbids: _releaseMbids,
      );
    } catch (_) {
      wiMessengerKey.currentState?.showSnackBar(const SnackBar(
          content: Text("Couldn't update artist info — check the "
              'connection and try again.')));
    }
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    // A user-corrected artist credit (Edit track details) beats the
    // parsed name, same as on the cards.
    final meta =
        MetadataService.instance.metadataFor(group.albums.first.tracks.first);
    final artist = meta.artist ?? group.artist;
    final info = ArtistInfoService.instance.infoFor(
      group.artist,
      displayName: artist,
      releaseMbids: _releaseMbids,
    );
    final refreshing = ArtistInfoService.instance.refreshing(group.artist);
    final albums = group.albums.length;
    final tracks = group.trackCount;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(artist,
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
        actions: [
          if (refreshing)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: t.ash),
                ),
              ),
            )
          else
            IconButton(
              icon: Icon(Icons.refresh, color: t.boneDim),
              tooltip: 'Refresh artist info',
              onPressed: () => _refresh(context, artist),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _Portrait(info: info, tokens: t),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      artist,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: t.bone,
                      ),
                    ),
                    if (info?.factsLine != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        info!.factsLine!,
                        style: TextStyle(fontSize: 13, color: t.boneDim),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      '$albums albums · $tracks tracks',
                      style: TextStyle(fontSize: 13, color: t.ash),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (info?.bio != null) ...[
            const SizedBox(height: 16),
            ExpandableBio(text: info!.bio!, tokens: t),
            const SizedBox(height: 6),
            // CC BY-SA: the bio must credit and link its source article.
            GestureDetector(
              onTap: info.bioUrl == null
                  ? null
                  : () => launchUrl(Uri.parse(info.bioUrl!)),
              child: Text(
                'Bio from Wikipedia (CC BY-SA)',
                style: TextStyle(
                  fontSize: 10.5,
                  color: t.ash,
                  decoration: info.bioUrl == null
                      ? null
                      : TextDecoration.underline,
                  decorationColor: t.ash,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          sectionLabel(t, 'ALBUMS'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 16,
            children: [
              for (final album in group.albums)
                AlbumCard(
                  group: album,
                  tokens: t,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => AlbumScreen(group: album)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Circular artist portrait (the channel-avatar idiom: circles mark
/// identity, rectangles mark media); a music-note person placeholder
/// until the chain lands one.
class _Portrait extends StatelessWidget {
  const _Portrait({required this.info, required this.tokens});

  final ArtistInfo? info;
  final WiTokens tokens;

  @override
  Widget build(BuildContext context) {
    const size = 96.0;
    final path = info?.portraitPath;
    if (path == null) {
      return Container(
        width: size,
        height: size,
        decoration:
            BoxDecoration(color: tokens.ink2, shape: BoxShape.circle),
        child: Icon(Icons.person, size: 44, color: tokens.ash),
      );
    }
    return ClipOval(
      child: Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }
}

/// The bio paragraph, collapsed to four lines with a More/Less toggle
/// when it is long (the channel-description expandable idiom).
class ExpandableBio extends StatefulWidget {
  const ExpandableBio({super.key, required this.text, required this.tokens});

  final String text;
  final WiTokens tokens;

  @override
  State<ExpandableBio> createState() => _ExpandableBioState();
}

class _ExpandableBioState extends State<ExpandableBio> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tokens;
    // Roughly four comfortable lines — shorter bios just render whole.
    final long = widget.text.length > 280;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.text,
          maxLines: long && !_expanded ? 4 : null,
          overflow: long && !_expanded ? TextOverflow.ellipsis : null,
          style: TextStyle(fontSize: 13.5, height: 1.5, color: t.boneDim),
        ),
        if (long)
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _expanded ? 'Less' : 'More',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: t.accent,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
