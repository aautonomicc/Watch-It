import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/organize.dart';
import '../theme/tokens.dart';
import '../widgets/organize_dialogs.dart';
import '../widgets/playlist_picker.dart';
import 'detail_screen.dart';

/// Every audio entry whose file name does NOT parse as a music track —
/// unidentified tracks, DJ mixes, hand-named files — with checkboxes:
/// select some, then either "Move to album…" (one Artist/Album/Year
/// entry renames them all into the track convention, with a before →
/// after preview and track numbers continuing after the album's
/// existing tracks) or "Add to playlist…" (the right home for mixes).
class NeedsSortingScreen extends StatefulWidget {
  const NeedsSortingScreen({super.key});

  @override
  State<NeedsSortingScreen> createState() => _NeedsSortingScreenState();
}

class _NeedsSortingScreenState extends State<NeedsSortingScreen> {
  List<MediaEntry> _entries = const [];
  final _selected = <int>{};
  bool _loaded = false;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final lists = await LibraryStore.load();
    if (!mounted) return;
    setState(() {
      _entries = unsortedAudioEntries(lists);
      _selected.removeWhere((i) => i >= _entries.length);
      _loaded = true;
    });
  }

  List<MediaEntry> get _selection =>
      [for (final i in _selected.toList()..sort()) _entries[i]];

  Future<void> _moveToAlbum() async {
    final input = await askAlbumDialog(context, count: _selected.length);
    if (input == null || !mounted) return;
    setState(() => _working = true);
    final plan = await planOrganize(
      _selection,
      artist: input.artist,
      album: input.album,
      year: input.year,
    );
    if (!mounted) return;
    setState(() => _working = false);
    if (plan.error != null) {
      _snack(plan.error!);
      return;
    }
    final confirmed = await confirmOrganizePlanDialog(context, plan.items);
    if (confirmed != true || !mounted) return;
    setState(() => _working = true);
    final n = await applyOrganize(plan.items);
    if (!mounted) return;
    setState(() {
      _working = false;
      _selected.clear();
    });
    _snack(n == 1
        ? '1 track moved into "${input.album}".'
        : '$n tracks moved into "${input.album}".');
    await _reload();
  }

  Future<void> _addToPlaylist() async {
    await addToPlaylistFlow(context, _selection);
    if (mounted) setState(() => _selected.clear());
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final allSelected =
        _entries.isNotEmpty && _selected.length == _entries.length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Needs sorting',
                style: TextStyle(color: t.bone, fontSize: 18)),
            Text(
              '${_entries.length} unsorted audio '
              '${_entries.length == 1 ? 'file' : 'files'}',
              style: TextStyle(color: t.ash, fontSize: 11),
            ),
          ],
        ),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              tooltip: allSelected ? 'Select none' : 'Select all',
              icon: Icon(
                  allSelected
                      ? Icons.deselect
                      : Icons.select_all,
                  color: t.boneDim),
              onPressed: () => setState(() {
                if (allSelected) {
                  _selected.clear();
                } else {
                  _selected
                      .addAll(List.generate(_entries.length, (i) => i));
                }
              }),
            ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Nothing needs sorting — every audio file follows '
                      'the track naming pattern and sits in an album.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: t.boneDim),
                    ),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'These audio files don\'t follow the '
                        '"Artist - Album (Year) - NN Title" pattern, so '
                        'they sit outside every album. Select some and '
                        'move them into an album (they are renamed to '
                        'match), or add mixes to a playlist. The info '
                        'button opens a file\'s own page.',
                        style: TextStyle(
                            fontSize: 12, color: t.ash, height: 1.4),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _entries.length,
                        itemBuilder: (context, i) {
                          final e = _entries[i];
                          final parsed = parseMediaName(e.name);
                          return CheckboxListTile(
                            value: _selected.contains(i),
                            dense: true,
                            controlAffinity:
                                ListTileControlAffinity.leading,
                            activeColor: t.accent,
                            onChanged: (on) => setState(() {
                              on == true
                                  ? _selected.add(i)
                                  : _selected.remove(i);
                            }),
                            title: Text(
                              parsed.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: t.bone, fontSize: 13.5),
                            ),
                            subtitle: Text(
                              e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: t.ash,
                                  fontSize: 11,
                                  fontFamily: wiMonoFamily,
                                  fontFamilyFallback: wiMonoFallback),
                            ),
                            secondary: IconButton(
                              tooltip: 'File details',
                              icon: Icon(Icons.info_outline,
                                  size: 16, color: t.ash),
                              onPressed: () async {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          DetailScreen(entry: e)),
                                );
                                await _reload();
                              },
                            ),
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed:
                                    _selected.isEmpty || _working
                                        ? null
                                        : _moveToAlbum,
                                icon: const Icon(Icons.album_outlined,
                                    size: 18),
                                label: Text(_selected.isEmpty
                                    ? 'Move to album…'
                                    : 'Move ${_selected.length} to album…'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed:
                                    _selected.isEmpty || _working
                                        ? null
                                        : _addToPlaylist,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: t.bone,
                                  side: BorderSide(color: t.ash),
                                ),
                                icon: const Icon(Icons.playlist_add,
                                    size: 18),
                                label: const Text('Add to playlist…'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
