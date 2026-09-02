import 'package:flutter/material.dart';

import '../services/download_manager.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import '../widgets/poster_cards.dart';
import 'album_screen.dart';

/// One artist: name and counts on top, then every album of theirs in
/// the list as square cover tiles, sorted by year. Tapping an album
/// opens its [AlbumScreen] — the music mirror of ShowScreen's
/// show → season → episode drill-down.
class ArtistScreen extends StatelessWidget {
  const ArtistScreen({super.key, required this.group});

  /// The artist's albums as folded by [groupShows]; never fewer than
  /// two.
  final HomeArtist group;

  @override
  Widget build(BuildContext context) {
    // Rebuild as CAA covers land in the cache and as downloads change
    // the album tiles' badges.
    return ListenableBuilder(
      listenable: Listenable.merge(
          [MetadataService.instance, DownloadManager.instance]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    // A user-corrected artist credit (Edit track details) beats the
    // parsed name, same as on the cards.
    final meta =
        MetadataService.instance.metadataFor(group.albums.first.tracks.first);
    final artist = meta.artist ?? group.artist;
    final albums = group.albums.length;
    final tracks = group.trackCount;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(artist,
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            artist,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: t.bone,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$albums albums · $tracks tracks',
            style: TextStyle(fontSize: 13, color: t.ash),
          ),
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
