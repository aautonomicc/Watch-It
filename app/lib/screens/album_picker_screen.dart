import 'dart:async';

import 'package:flutter/material.dart';

import '../services/library_search.dart' show normalizeSearchText;
import '../services/metadata.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';

/// What the album picker pops with: an existing album chosen from the
/// library, or the request to create a new one via the free-text
/// dialog ([artistPrefill] carries the search query along so a typed
/// name isn't retyped).
sealed class AlbumPickResult {
  const AlbumPickResult();
}

class ExistingAlbumPick extends AlbumPickResult {
  const ExistingAlbumPick(this.album);

  final HomeAlbum album;
}

class NewAlbumPick extends AlbumPickResult {
  const NewAlbumPick({this.artistPrefill});

  final String? artistPrefill;
}

/// Full-screen searchable album chooser for the move-to-album flows
/// (2026-09-14, replaces typing the target album into free-text fields
/// — typos forked albums): the library's albums grouped the way the
/// wall folds them — an artist with several albums expands, single
/// albums and compilations sit flat — with a search field over
/// artist/album/track names and a pinned "New album…" row that falls
/// through to the free-text dialog. Single-select: tapping an album
/// returns it.
class AlbumPickerScreen extends StatefulWidget {
  const AlbumPickerScreen({
    super.key,
    required this.items,
    required this.count,
  });

  /// The library's album fold ([groupShows] output filtered to
  /// [HomeAlbum]/[HomeArtist]), minus the album being moved FROM.
  final List<HomeItem> items;

  /// How many files are being moved (title wording).
  final int count;

  @override
  State<AlbumPickerScreen> createState() => _AlbumPickerScreenState();
}

class _AlbumPickerScreenState extends State<AlbumPickerScreen> {
  static const _debounce = Duration(milliseconds: 150);

  final _query = TextEditingController();
  Timer? _debounceTimer;
  String _needle = '';

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryEdited);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onQueryEdited() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      if (!mounted) return;
      setState(() => _needle = normalizeSearchText(_query.text));
    });
  }

  bool _albumMatches(HomeAlbum album) {
    if (_needle.isEmpty) return true;
    if (normalizeSearchText('${album.artist} ${album.album}')
        .contains(_needle)) {
      return true;
    }
    for (final track in album.tracks) {
      final p = parseMediaName(track.name);
      final title = p.trackTitle ?? p.title;
      if (normalizeSearchText('${p.artist ?? ''} $title')
          .contains(_needle)) {
        return true;
      }
    }
    return false;
  }

  void _pick(HomeAlbum album) =>
      Navigator.of(context).pop(ExistingAlbumPick(album));

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(
            'Move ${widget.count == 1 ? '1 file' : '${widget.count} files'} '
            'to album',
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _query,
              autofocus: false,
              style: TextStyle(color: t.bone, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search albums…',
                hintStyle: TextStyle(color: t.ash, fontSize: 14),
                prefixIcon: Icon(Icons.search, color: t.ash, size: 20),
                suffixIcon: _needle.isEmpty && _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: Icon(Icons.close, color: t.ash, size: 18),
                        onPressed: () {
                          _debounceTimer?.cancel();
                          _query.clear();
                          setState(() => _needle = '');
                        },
                      ),
                isDense: true,
                filled: true,
                fillColor: t.ink2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // Pinned above the scroll: the free-text creation path.
          ListTile(
            dense: true,
            leading: Icon(Icons.add, size: 20, color: t.accent),
            title: Text('New album…',
                style: TextStyle(color: t.accent, fontSize: 13.5)),
            subtitle: Text('Type the artist, album and year yourself',
                style: TextStyle(color: t.ash, fontSize: 11)),
            onTap: () => Navigator.of(context).pop(NewAlbumPick(
                artistPrefill:
                    _query.text.trim().isEmpty ? null : _query.text.trim())),
          ),
          Divider(height: 1, color: t.ink2),
          Expanded(child: _albumList(t)),
        ],
      ),
    );
  }

  Widget _albumList(WiTokens t) {
    final searching = _needle.isNotEmpty;
    final rows = <Widget>[];
    for (final item in widget.items) {
      switch (item) {
        case HomeAlbum():
          if (_albumMatches(item)) {
            rows.add(_albumRow(t, item));
          }
        case HomeArtist():
          final matching = [
            for (final album in item.albums)
              if (_albumMatches(album)) album,
          ];
          if (matching.isEmpty) break;
          if (searching) {
            // A query flattens the tree — matches render directly.
            rows.addAll([for (final a in matching) _albumRow(t, a)]);
          } else {
            rows.add(_artistTile(t, item));
          }
        default:
          break;
      }
    }
    if (rows.isEmpty) {
      return Center(
        child: Text(
            searching
                ? 'No album matches.'
                : 'No albums in the library yet — use "New album…".',
            style: TextStyle(color: t.boneDim, fontSize: 13)),
      );
    }
    return ListView(
      key: const PageStorageKey('albumPickerList'),
      padding: const EdgeInsets.only(bottom: 24),
      children: rows,
    );
  }

  Widget _artistTile(WiTokens t, HomeArtist artist) => ExpansionTile(
        key: PageStorageKey('artist|${artist.artist}'),
        leading: Icon(Icons.person_outline, size: 20, color: t.ash),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text(artist.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.bone, fontSize: 13.5)),
        subtitle: Text(
          '${artist.albums.length} albums · ${artist.trackCount} tracks',
          style: TextStyle(color: t.ash, fontSize: 11),
        ),
        iconColor: t.boneDim,
        collapsedIconColor: t.ash,
        children: [
          for (final album in artist.albums)
            _albumRow(t, album, indent: true),
        ],
      );

  Widget _albumRow(WiTokens t, HomeAlbum album, {bool indent = false}) =>
      ListTile(
        key: ValueKey('album|${album.artist}|${album.album}|${album.year}'),
        dense: true,
        contentPadding:
            EdgeInsets.only(left: indent ? 28 : 12, right: 12),
        leading: Icon(Icons.album_outlined, size: 20, color: t.ash),
        title: Text(
          album.year == null
              ? album.album
              : '${album.album} (${album.year})',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.bone, fontSize: 13.5),
        ),
        subtitle: Text(
          '${album.artist} · ${album.tracks.length} '
          '${album.tracks.length == 1 ? 'track' : 'tracks'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.ash, fontSize: 11),
        ),
        onTap: () => _pick(album),
      );
}
