import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../screens/list_home_screen.dart';
import '../screens/playlist_screen.dart';
import '../screens/settings_screen.dart';
import '../services/app_settings.dart';
import '../services/home_sections.dart';
import '../services/library_arrangement.dart';
import '../services/library_store.dart';
import '../services/metadata_service.dart';
import '../services/profiles.dart';
import '../services/channels_api.dart';
import '../services/embedded_client.dart';
import '../theme/tokens.dart';
import 'channel_avatar.dart';
import 'drawer_status.dart';

/// Width of the pinned side-panel variant of the drawer (a touch
/// narrower than the modal drawer's 304 default — it shares the window
/// with the poster wall permanently).
const double kPinnedDrawerWidth = 290;

/// Minimum window width (logical px) at which the home screen pins the
/// drawer open on desktop. Below it — a squeezed desktop window, or any
/// mobile screen — home falls back to the modal far-right-burger layout,
/// so the panel can never crowd out the wall.
const double kPinnedDrawerMinWindowWidth = 1000;

/// Modal left drawer for hopping between browsable lists (the enabled
/// user lists). Mounted on the home screen and on every list page
/// (there, [currentListId] marks the open list and navigation replaces
/// the page instead of stacking). With [pinned] the same content renders
/// as a fixed side panel instead (wide desktop home windows): no Drawer
/// chrome, and navigation stops popping — there is no modal to close.
class WiLibraryDrawer extends StatefulWidget {
  const WiLibraryDrawer({
    super.key,
    this.currentListId,
    this.pinned = false,
    this.healthProvider,
    this.channelsStatusProvider,
  });

  /// Id of the list page the drawer is mounted on; null on home.
  final String? currentListId;

  /// Render as a permanent side panel instead of a modal drawer.
  final bool pinned;

  /// Test override for [EmbeddedClient.health] (status rows).
  final Future<ClientHealth> Function()? healthProvider;

  /// Test override for [ChannelsApi.status] (status rows).
  final Future<ChannelsStatus> Function()? channelsStatusProvider;

  @override
  State<WiLibraryDrawer> createState() => _WiLibraryDrawerState();
}

class _WiLibraryDrawerState extends State<WiLibraryDrawer> {
  List<MediaList>? _lists;
  List<HomeSection> _storedSections = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Kid profiles browse only their allow-listed lists.
    final lists =
        ProfileStore.instance.visibleLists(await LibraryStore.load());
    final stored = await AppSettings.homeSections();
    if (!mounted) return;
    setState(() {
      _lists = lists;
      _storedSections = stored;
    });
  }

  void _openList(MediaList list) {
    final navigator = Navigator.of(context);
    if (!widget.pinned) navigator.pop(); // close the modal drawer
    if (list.id == widget.currentListId) return;
    final route =
        MaterialPageRoute<void>(builder: (_) => ListHomeScreen(list: list));
    // From a list page, replace it — hopping list → list must not stack.
    if (widget.currentListId != null) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
  }

  void _openPage(Widget page) {
    final navigator = Navigator.of(context);
    if (!widget.pinned) navigator.pop();
    navigator.push(MaterialPageRoute<void>(builder: (_) => page));
  }

  void _openPlaylist(MediaList list) {
    final navigator = Navigator.of(context);
    if (!widget.pinned) navigator.pop();
    if (list.id == widget.currentListId) return;
    final route = MaterialPageRoute<void>(
        builder: (_) => PlaylistScreen(playlistId: list.id));
    if (widget.currentListId != null) {
      navigator.pushReplacement(route);
    } else {
      navigator.push(route);
    }
  }

  Future<void> _newPlaylist() async {
    final title = await promptForText(context,
        title: 'New playlist', hint: 'Playlist name');
    if (title == null || title.trim().isEmpty || !mounted) return;
    final playlist = await createPlaylist(title.trim());
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    _openPlaylist(playlist);
  }

  /// Channel rows lead with the channel's mini avatar (podcasts-icon
  /// fallback keeps the old look); plain lists keep the library icon.
  Widget _leadingFor(MediaList list, WiTokens t) => list.isChannel
      ? ChannelAvatar(memberName: list.channelAvatar, size: 20)
      : Icon(Icons.video_library_outlined,
          color: list.id == widget.currentListId ? t.accent : t.boneDim,
          size: 20);

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final content = _content(t);
    // Pinned: a plain fixed-width Material — Drawer chrome (elevation,
    // end-side rounding) belongs to the modal overlay, not a panel.
    if (widget.pinned) {
      return Material(
        color: t.ink,
        child: SizedBox(width: kPinnedDrawerWidth, child: content),
      );
    }
    return Drawer(backgroundColor: t.ink, child: content);
  }

  Widget _content(WiTokens t) {
    return SafeArea(
        // Titles refine as TMDB matches land elsewhere in the app.
        child: ListenableBuilder(
          listenable: MetadataService.instance,
          builder: (context, _) {
            final lists = _lists;
            // Same order and visibility as the home screen's rows.
            final browsable =
                lists == null ? null : browsableLists(lists, _storedSections);
            return ListView(
              children: [
                // Connection status leads the drawer (2026-08-30, moved
                // up from below Settings): peers, My W@tch, Channels.
                const SizedBox(height: 12),
                WiDrawerStatus(
                  healthProvider: widget.healthProvider,
                  channelsStatusProvider: widget.channelsStatusProvider,
                ),
                Divider(color: t.line, height: 24),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    'Library',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: t.ash,
                    ),
                  ),
                ),
                if (browsable == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (browsable.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Text(
                      'Nothing to browse yet — add media on the My Media '
                      'page (Settings → My Media).',
                      style: TextStyle(fontSize: 12, color: t.boneDim),
                    ),
                  )
                else
                  for (final list in browsable)
                    ListTile(
                      dense: true,
                      selected: list.id == widget.currentListId,
                      selectedTileColor: t.ink2,
                      leading: _leadingFor(list, t),
                      title: Text(
                        list.title,
                        style: TextStyle(color: t.bone, fontSize: 14),
                      ),
                      trailing: Text(
                        '${list.entries.length}',
                        style: TextStyle(color: t.ash, fontSize: 12),
                      ),
                      onTap: () => _openList(list),
                    ),
                // Playlists get their own section below Library: they
                // are ordered track sets, not wall shelves, so they
                // never appear on the home wall (2026-09-11 decision).
                if (_lists != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      'Playlists',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: t.ash,
                      ),
                    ),
                  ),
                  for (final list in _lists!)
                    if (list.isPlaylist)
                      ListTile(
                        dense: true,
                        selected: list.id == widget.currentListId,
                        selectedTileColor: t.ink2,
                        leading: Icon(Icons.queue_music,
                            color: list.id == widget.currentListId
                                ? t.accent
                                : t.boneDim,
                            size: 20),
                        title: Text(
                          list.title,
                          style: TextStyle(color: t.bone, fontSize: 14),
                        ),
                        trailing: Text(
                          '${list.entries.length}',
                          style: TextStyle(color: t.ash, fontSize: 12),
                        ),
                        onTap: () => _openPlaylist(list),
                      ),
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.add, color: t.boneDim, size: 20),
                    title: Text('New playlist',
                        style: TextStyle(color: t.boneDim, fontSize: 14)),
                    onTap: _newPlaylist,
                  ),
                ],
                Divider(color: t.line, height: 24),
                // My Media, Channels, My W@tch, Upload, and Downloads
                // live under Settings → CONTENT — the drawer is slimmed
                // down to status rows + list navigation + Settings.
                ListTile(
                  dense: true,
                  leading: Icon(Icons.settings_outlined,
                      color: t.boneDim, size: 20),
                  title: Text('Settings',
                      style: TextStyle(color: t.bone, fontSize: 14)),
                  onTap: () => _openPage(const SettingsScreen()),
                ),
              ],
            );
          },
        ),
    );
  }
}
