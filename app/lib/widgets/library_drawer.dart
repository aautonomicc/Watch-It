import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../screens/list_home_screen.dart';
import '../screens/media_lists_screen.dart';
import '../screens/publish_screen.dart';
import '../screens/settings_screen.dart';
import '../services/library_arrangement.dart';
import '../services/library_store.dart';
import '../services/metadata_service.dart';
import '../theme/tokens.dart';

/// Modal left drawer for hopping between browsable lists: enabled user
/// lists, or the virtual Movies / TV Shows pair in auto mode. Mounted on
/// the home screen and on every list page (there, [currentListId] marks
/// the open list and navigation replaces the page instead of stacking).
class WiLibraryDrawer extends StatefulWidget {
  const WiLibraryDrawer({super.key, this.currentListId});

  /// Id of the list page the drawer is mounted on; null on home.
  final String? currentListId;

  @override
  State<WiLibraryDrawer> createState() => _WiLibraryDrawerState();
}

class _WiLibraryDrawerState extends State<WiLibraryDrawer> {
  List<MediaList>? _lists;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ArrangementStore.instance.ensureLoaded();
    final lists = await LibraryStore.load();
    if (mounted) setState(() => _lists = lists);
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

  IconData _iconFor(MediaList list) => switch (list.id) {
        kAutoMoviesListId => Icons.movie_outlined,
        kAutoTvShowsListId => Icons.live_tv_outlined,
        _ => Icons.video_library_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Drawer(
      backgroundColor: t.ink,
      child: SafeArea(
        // Counts and the auto split refine as TMDB matches land; the
        // whole drawer flips when the arrangement changes elsewhere.
        child: ListenableBuilder(
          listenable: Listenable.merge(
              [MetadataService.instance, ArrangementStore.instance]),
          builder: (context, _) {
            final lists = _lists;
            final browsable = lists == null
                ? null
                : browsableLists(lists, ArrangementStore.instance.value,
                    hiddenAutoIds: ArrangementStore.instance.hiddenAutoIds);
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
                      'Nothing to browse yet — add media on the Media '
                      'page.',
                      style: TextStyle(fontSize: 12, color: t.boneDim),
                    ),
                  )
                else
                  for (final list in browsable)
                    ListTile(
                      dense: true,
                      selected: list.id == widget.currentListId,
                      selectedTileColor: t.ink2,
                      leading: Icon(_iconFor(list),
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
                      onTap: () => _openList(list),
                    ),
                Divider(color: t.line, height: 24),
                ListTile(
                  dense: true,
                  leading: Icon(Icons.playlist_add_check,
                      color: t.boneDim, size: 20),
                  title: Text('Media',
                      style: TextStyle(color: t.bone, fontSize: 14)),
                  onTap: () => _openPage(const MediaListsScreen()),
                ),
                // Desktop-only this edition: uploads need local files
                // and the internal wallet (see docs/PLAN-alpha55.md).
                if (isDesktopPlatform)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.cloud_upload_outlined,
                        color: t.boneDim, size: 20),
                    title: Text('Upload',
                        style: TextStyle(color: t.bone, fontSize: 14)),
                    subtitle: Text('Private · only your devices',
                        style: TextStyle(color: t.ash, fontSize: 11)),
                    onTap: () => _openPage(const PublishScreen()),
                  ),
                // My W@tch lives under Settings → Network since the
                // drawer slimmed down to library navigation + entry
                // points (the home status bar also links to it).
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
      ),
    );
  }
}
