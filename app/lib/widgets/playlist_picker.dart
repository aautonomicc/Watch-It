import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/profiles.dart';
import '../theme/tokens.dart';
import '../screens/settings_screen.dart' show promptForText;

/// A playlist's icon, derived from what it holds (2026-09-12 decision —
/// content-derived, never typed at creation, so mixed playlists stay
/// legal with no schema change): all-audio = the classic queue-music,
/// all-video = the movie symbol, mixed = playlist-play. Empty playlists
/// read as music until something video joins.
IconData playlistContentIcon(MediaList playlist) {
  var hasAudio = false;
  var hasVideo = false;
  for (final e in playlist.entries) {
    parseMediaName(e.name).isAudio ? hasAudio = true : hasVideo = true;
  }
  if (hasVideo && !hasAudio) return Icons.movie_outlined;
  if (hasVideo && hasAudio) return Icons.playlist_play;
  return Icons.queue_music;
}

/// The shared "Add to playlist" flow: pick one of the user's playlists
/// (or create a new one), then append [tracks] — audio or video, any
/// mix — to it (deduplicated by address — a playlist holds each title
/// once). Reports the outcome in a snackbar. Used by track/album/detail
/// actions and the Needs-sorting screen.
Future<void> addToPlaylistFlow(
    BuildContext context, List<MediaEntry> tracks) async {
  if (tracks.isEmpty) return;
  final lists = ProfileStore.instance.visibleLists(await LibraryStore.load());
  final playlists = [for (final l in lists) if (l.isPlaylist) l];
  if (!context.mounted) return;
  final choice = await showDialog<Object>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      return SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Add to playlist',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          for (final p in playlists)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(p),
              child: Row(
                children: [
                  Icon(playlistContentIcon(p), size: 18, color: t.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(p.title,
                        style: TextStyle(color: t.bone, fontSize: 14)),
                  ),
                  Text('${p.entries.length}',
                      style: TextStyle(color: t.ash, fontSize: 12)),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('new'),
            child: Row(
              children: [
                Icon(Icons.add, size: 18, color: t.boneDim),
                const SizedBox(width: 10),
                Text('New playlist…',
                    style: TextStyle(color: t.boneDim, fontSize: 14)),
              ],
            ),
          ),
        ],
      );
    },
  );
  if (choice == null || !context.mounted) return;
  MediaList playlist;
  if (choice == 'new') {
    final title = await promptForText(context,
        title: 'New playlist', hint: 'Playlist name');
    if (title == null || title.trim().isEmpty) return;
    playlist = await createPlaylist(title.trim());
  } else {
    playlist = choice as MediaList;
  }
  final added = await addTracksToPlaylist(playlist.id, tracks);
  if (!context.mounted) return;
  final message = switch (added) {
    -1 => 'That playlist no longer exists.',
    0 => tracks.length == 1
        ? 'Already in "${playlist.title}".'
        : 'All of those are already in "${playlist.title}".',
    1 => 'Added 1 item to "${playlist.title}".',
    _ => 'Added $added items to "${playlist.title}".',
  };
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}
