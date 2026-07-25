import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/home_sections.dart';
import '../services/library_store.dart';
import '../theme/tokens.dart';

/// Settings → Home screen: reorder home rows by drag handle and toggle
/// their visibility. Special-row visibility persists in
/// `home_sections_v1`; list-row visibility writes [MediaList.enabled],
/// the same flag as the Media Lists screen checkbox.
class HomeLayoutScreen extends StatefulWidget {
  const HomeLayoutScreen({super.key});

  @override
  State<HomeLayoutScreen> createState() => _HomeLayoutScreenState();
}

class _HomeLayoutScreenState extends State<HomeLayoutScreen> {
  List<MediaList>? _lists;
  List<HomeSection> _sections = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lists = await LibraryStore.load();
    final sections =
        reconcileHomeSections(await AppSettings.homeSections(), lists);
    if (!mounted) return;
    setState(() {
      _lists = lists;
      _sections = sections;
    });
  }

  MediaList? _listFor(HomeSection section) {
    final id = section.listId;
    if (id == null) return null;
    final lists = _lists ?? const <MediaList>[];
    for (final l in lists) {
      if (l.id == id) return l;
    }
    return null;
  }

  // onReorderItem delivers newIndex already adjusted for the removal.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    final sections = [..._sections];
    sections.insert(newIndex, sections.removeAt(oldIndex));
    setState(() => _sections = sections);
    await AppSettings.setHomeSections(sections);
  }

  Future<void> _setVisible(int index, bool visible) async {
    final section = _sections[index];
    final sections = [..._sections];
    sections[index] = section.copyWith(visible: visible);
    setState(() => _sections = sections);
    if (section.isSpecial) {
      await AppSettings.setHomeSections(sections);
      return;
    }
    // List rows: MediaList.enabled is the single source of truth, shared
    // with the Media Lists screen checkbox.
    final lists = [...?_lists];
    final i = lists.indexWhere((l) => l.id == section.listId);
    if (i == -1) return;
    lists[i] = lists[i].copyWith(enabled: visible);
    setState(() => _lists = lists);
    await LibraryStore.save(lists);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final lists = _lists;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title:
            Text('Home screen', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: lists == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Drag to reorder rows. Unticked rows are hidden from '
                    'home; rows with nothing to show hide themselves.',
                    style: TextStyle(fontSize: 12, color: t.ash),
                  ),
                ),
                Expanded(
                  child: ReorderableListView(
                    buildDefaultDragHandles: false,
                    onReorderItem: _reorder,
                    children: [
                      for (final (i, section) in _sections.indexed)
                        _sectionTile(t, i, section),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _sectionTile(WiTokens t, int index, HomeSection section) {
    final list = _listFor(section);
    final subtitle = section.isSpecial
        ? null
        : '${list?.entries.length ?? 0} '
            '${(list?.entries.length ?? 0) == 1 ? 'entry' : 'entries'}';
    return ListTile(
      key: ValueKey(section.id),
      leading: Checkbox(
        value: section.visible,
        activeColor: t.copper,
        onChanged: (v) => _setVisible(index, v ?? true),
      ),
      title: Text(
        list?.title ?? section.title,
        style: TextStyle(
          fontSize: 15,
          color: section.visible ? t.bone : t.ash,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: TextStyle(fontSize: 12, color: t.ash)),
      trailing: ReorderableDragStartListener(
        index: index,
        child: Icon(Icons.drag_handle, color: t.ash),
      ),
    );
  }
}
