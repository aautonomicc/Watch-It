import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../screens/list_home_screen.dart';
import '../screens/settings_screen.dart';
import '../services/app_settings.dart';
import '../services/home_sections.dart';
import '../services/library_arrangement.dart';
import '../services/library_store.dart';
import '../services/metadata_service.dart';
import '../services/channels_api.dart';
import '../services/embedded_client.dart';
import '../theme/tokens.dart';
import 'channel_avatar.dart';
import 'drawer_status.dart';

/// Modal left drawer for hopping between browsable lists (the enabled
/// user lists). Mounted on the home screen and on every list page
/// (there, [currentListId] marks the open list and navigation replaces
/// the page instead of stacking).
class WiLibraryDrawer extends StatefulWidget {
  const WiLibraryDrawer({
    super.key,
    this.currentListId,
    this.healthProvider,
    this.channelsStatusProvider,
  });

  /// Id of the list page the drawer is mounted on; null on home.
  final String? currentListId;

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
    final lists = await LibraryStore.load();
    final stored = await AppSettings.homeSections();
    if (!mounted) return;
    setState(() {
      _lists = lists;
      _storedSections = stored;
    });
  }

  void _openList(MediaList list) {
    final navigator = Navigator.of(context);
    navigator.pop(); // close the drawer
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
    navigator.pop();
    navigator.push(MaterialPageRoute<void>(builder: (_) => page));
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
    return Drawer(
      backgroundColor: t.ink,
      child: SafeArea(
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                Divider(color: t.line, height: 24),
                // My Media, Channels, and Upload live under Settings →
                // LIBRARY; My W@tch under Settings → Network — the
                // drawer is slimmed down to list navigation + Settings.
                ListTile(
                  dense: true,
                  leading: Icon(Icons.settings_outlined,
                      color: t.boneDim, size: 20),
                  title: Text('Settings',
                      style: TextStyle(color: t.bone, fontSize: 14)),
                  onTap: () => _openPage(const SettingsScreen()),
                ),
                Divider(color: t.line, height: 24),
                // Connection status lives here since 2026-08-29 (moved
                // off the home screen): peers, My W@tch, Channels.
                WiDrawerStatus(
                  healthProvider: widget.healthProvider,
                  channelsStatusProvider: widget.channelsStatusProvider,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
