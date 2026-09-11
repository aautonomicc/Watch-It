import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/organize.dart';
import '../theme/tokens.dart';
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
    final input = await _askAlbum();
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
    final confirmed = await _confirmPlan(plan.items);
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

  /// Artist / Album / Year, asked once for the whole selection.
  Future<({String artist, String album, int? year})?> _askAlbum() {
    final artist = TextEditingController();
    final album = TextEditingController();
    final year = TextEditingController();
    final n = _selected.length;
    return showDialog<({String artist, String album, int? year})>(
      context: context,
      builder: (context) {
        final t = WiTokens.of(context);
        String? error;
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: t.ink2,
            title: Text('Move ${n == 1 ? '1 file' : '$n files'} to album',
                style: TextStyle(color: t.bone, fontSize: 16)),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The files are renamed into the album, numbered '
                    'after its existing tracks. You\'ll see the new '
                    'names before anything changes.',
                    style:
                        TextStyle(color: t.ash, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: artist,
                    autofocus: true,
                    style: TextStyle(color: t.bone, fontSize: 14),
                    decoration: const InputDecoration(labelText: 'Artist'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: album,
                    style: TextStyle(color: t.bone, fontSize: 14),
                    decoration: const InputDecoration(labelText: 'Album'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: year,
                    keyboardType: TextInputType.number,
                    style: TextStyle(color: t.bone, fontSize: 14),
                    decoration: const InputDecoration(
                        labelText: 'Year (optional)'),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(error!,
                        style: TextStyle(color: t.rust, fontSize: 12)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Cancel', style: TextStyle(color: t.ash)),
              ),
              FilledButton(
                onPressed: () {
                  final a = artist.text.trim();
                  final b = album.text.trim();
                  final yText = year.text.trim();
                  final y = yText.isEmpty ? null : int.tryParse(yText);
                  if (a.isEmpty || b.isEmpty) {
                    setDialogState(
                        () => error = 'Artist and album are both needed.');
                    return;
                  }
                  if (yText.isNotEmpty && y == null) {
                    setDialogState(() => error = 'Year must be a number.');
                    return;
                  }
                  Navigator.of(context)
                      .pop((artist: a, album: b, year: y));
                },
                child: const Text('Preview new names'),
              ),
            ],
          );
        });
      },
    );
  }

  /// The before → after preview — nothing is renamed until Apply.
  Future<bool?> _confirmPlan(List<OrganizePlanItem> items) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        final t = WiTokens.of(context);
        return AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Rename ${items.length == 1 ? '1 file' : '${items.length} files'}?',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: SizedBox(
            width: 480,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final it in items) ...[
                  Text(it.entry.name,
                      style: TextStyle(
                          color: t.ash,
                          fontSize: 11.5,
                          fontFamily: wiMonoFamily,
                          fontFamilyFallback: wiMonoFallback)),
                  Padding(
                    padding: const EdgeInsets.only(top: 1, bottom: 8),
                    child: Text('→  ${it.newName}',
                        style: TextStyle(
                            color: t.bone,
                            fontSize: 11.5,
                            fontFamily: wiMonoFamily,
                            fontFamilyFallback: wiMonoFallback)),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.ash)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
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
