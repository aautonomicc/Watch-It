import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/intake_draft.dart';
import '../models/media_credits.dart';
import '../models/media_list.dart' show formatBytes;
import '../services/batch_upload.dart' show BatchStage, BatchUploadSession;
import '../services/intake_store.dart';
import '../services/library_store.dart';
import '../services/profiles.dart';
import '../theme/tokens.dart';
import '../widgets/poster_crop_dialog.dart';
import 'batch_upload_screen.dart';
import 'publish_screen.dart' show isDesktopPlatform;
import 'settings_screen.dart' show promptForText;

/// One picked file handed to the intake flow — a seam so tests (and any
/// future share-intent entry) can inject picks without the platform
/// file picker. [path] is only durable on desktop.
typedef IntakeFilePick = Future<List<({String name, String path, int? size})>>
    Function();

Future<List<({String name, String path, int? size})>> _realFilePick() async {
  final files = await openFiles(acceptedTypeGroups: [
    const XTypeGroup(label: 'Media files', extensions: [
      'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'mpg', 'ts',
      'mp3', 'flac', 'm4a', 'ogg', 'oga', 'opus', 'wav', 'aac',
      'jpg', 'jpeg', 'png', 'webp',
    ]),
    const XTypeGroup(label: 'All files'),
  ]);
  return [
    for (final f in files)
      (name: f.name, path: f.path, size: await _safeLength(f)),
  ];
}

Future<int?> _safeLength(XFile f) async {
  try {
    return await f.length();
  } catch (_) {
    return null;
  }
}

/// Pull the first web URL out of Android's Share-sheet text. YouTube shares
/// often include a title or message around the URL; the intake card keeps
/// that source intact for the user to review before saving.
String? extractSharedHttpUrl(String text) {
  final match = RegExp(r'https?://[^\s<>]+', caseSensitive: false)
      .firstMatch(text);
  if (match == null) return null;
  final raw = match.group(0)!.replaceFirst(RegExp(r'[.,;!?)]*$'), '');
  final uri = Uri.tryParse(raw);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return uri.toString();
}

/// Add to W@tch: the intake desk for media that is not on the network
/// yet. Pick local files or paste a source link, review one card per
/// item, and save drafts on this device — no upload, no payment, no
/// publishing happens here. A pasted link is a reference record; W@tch
/// never downloads from it. File drafts hand off to the existing batch
/// upload flow (price, wallet approval, resume and dedup unchanged),
/// after which their credits move onto the real file records.
///
/// Drafts are device-local: they are not library entries, never playable
/// on TV, and never synced. Other devices see media only after a real
/// upload plus a .watch-list transfer (or a channel publication).
class IntakeScreen extends StatefulWidget {
  const IntakeScreen({
    super.key,
    this.filesPicker = _realFilePick,
    this.artworkPicker = _realArtworkPick,
    this.postersDirProvider,
    this.uploadOpener,
  });

  /// Test seam for the platform file picker.
  final IntakeFilePick filesPicker;

  /// Test seam for artwork picking (returns cropped bytes, or null).
  final Future<Uint8List?> Function() artworkPicker;

  /// Test override for where intake artwork is stored.
  final Future<Directory> Function()? postersDirProvider;

  /// Test seam replacing the upload handoff (path + list → carried
  /// draft count). Production opens the real BatchUploadScreen and
  /// carries credits afterwards.
  final Future<int> Function(BuildContext context, IntakeDraft draft)?
      uploadOpener;

  static Future<Uint8List?> _realArtworkPick() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
          label: 'Images',
          extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp']),
      XTypeGroup(label: 'All files'),
    ]);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length > 10 * 1024 * 1024) return null;
    return bytes;
  }

  @override
  State<IntakeScreen> createState() => _IntakeScreenState();
}

class _IntakeScreenState extends State<IntakeScreen> {
  static const _shareChannel = MethodChannel('watchit/intake');
  final _linkController = TextEditingController();
  String? _linkError;
  List<IntakeDraft> _drafts = [];
  final List<IntakeDraft> _pending = [];
  List<String> _listTitles = const [];
  bool _busy = false;

  bool get _isKid => ProfileStore.instance.isKid;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _reload();
    await _consumeSharedText();
  }

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final drafts = await IntakeStore.loadAll();
    final lists = await LibraryStore.load();
    if (!mounted) return;
    setState(() {
      _drafts = drafts;
      _listTitles = [
        for (final l in lists)
          if (!l.isChannel) l.title,
      ];
    });
  }

  Future<void> _consumeSharedText() async {
    String? shared;
    try {
      shared = await _shareChannel.invokeMethod<String>('consumeSharedText');
    } on MissingPluginException {
      // Desktop and widget tests have no Android share channel.
      return;
    } on PlatformException {
      return;
    }
    if (!mounted || shared == null || shared.trim().isEmpty) return;
    final url = extractSharedHttpUrl(shared);
    if (url == null) {
      _snack('That shared item did not contain a web link.');
      return;
    }
    if (_isKid) {
      _snack('Adding media is available from an adult profile.');
      return;
    }
    setState(() {
      _pending.add(IntakeDraft(
        id: IntakeDraft.newId(),
        kind: IntakeDraft.kindLink,
        label: _sharedLabel(url),
        sourceUrl: url,
      ));
    });
    _snack('Link ready for review — nothing downloaded.');
  }

  String _sharedLabel(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    if (host == 'youtu.be' || host.endsWith('.youtube.com') ||
        host == 'youtube.com') {
      final videoId = uri?.queryParameters['v'];
      final playlistId = uri?.queryParameters['list'];
      if (videoId != null && videoId.isNotEmpty) {
        return 'YouTube video · $videoId';
      }
      if (playlistId != null && playlistId.isNotEmpty) {
        return 'YouTube playlist · $playlistId';
      }
      return 'YouTube source';
    }
    return IntakeDraft.suggestLabel(url) ?? 'Source link';
  }

  Future<void> _pickFiles() async {
    if (_busy) return;
    setState(() => _busy = true);
    List<({String name, String path, int? size})> picks;
    try {
      picks = await widget.filesPicker();
    } catch (_) {
      picks = const [];
    }
    if (!mounted) return;
    if (picks.isEmpty) {
      setState(() => _busy = false);
      return;
    }
    final drafts = [
      for (final pick in picks) _draftFromPick(pick),
    ];
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pending.addAll(drafts);
    });
  }

  IntakeDraft _draftFromPick(
      ({String name, String path, int? size}) pick) {
    // yt-dlp writes <video-id>.info.json beside the media. Reading that
    // sidecar turns an authorized laptop import into a nearly complete
    // review card while still requiring the user to confirm every field.
    final keepPath = isDesktopPlatform && pick.path.trim().isNotEmpty;
    var label = pick.name;
    String? sourceUrl;
    String? creator;
    var sourceTitle = '';
    if (keepPath) {
      final file = File(pick.path);
      final dot = file.path.lastIndexOf('.');
      final stem = dot > file.path.lastIndexOf(Platform.pathSeparator)
          ? file.path.substring(0, dot)
          : file.path;
      final info = File('$stem.info.json');
      if (info.existsSync()) {
        try {
          final decoded = jsonDecode(info.readAsStringSync());
          if (decoded is Map) {
            String? text(String key) {
              final value = decoded[key];
              return value is String && value.trim().isNotEmpty
                  ? value.trim()
                  : null;
            }

            sourceTitle = text('title') ?? '';
            label = sourceTitle.isEmpty ? label : sourceTitle;
            creator = text('uploader') ?? text('channel') ?? text('artist');
            sourceUrl = text('webpage_url') ?? text('original_url');
          }
        } catch (_) {
          // A malformed sidecar must not block a perfectly valid media pick.
        }
      }
    }
    return IntakeDraft(
      id: IntakeDraft.newId(),
      kind: IntakeDraft.kindFile,
      label: label,
      localPath: keepPath ? pick.path : null,
      sizeBytes: pick.size,
      sourceUrl: sourceUrl,
      credits: MediaCredits(
        title: sourceTitle,
        creator: creator ?? '',
        sourceUrl: sourceUrl ?? '',
      ),
    );
  }

  void _addLink() {
    final url = _linkController.text.trim();
    if (url.isEmpty) {
      setState(() => _linkError = 'Paste a source link first.');
      return;
    }
    if (!MediaCredits.isWebUrl(url)) {
      setState(() =>
          _linkError = 'Links must be plain HTTP or HTTPS addresses.');
      return;
    }
    setState(() {
      _linkError = null;
      _pending.add(IntakeDraft(
        id: IntakeDraft.newId(),
        kind: IntakeDraft.kindLink,
        label: IntakeDraft.suggestLabel(url) ?? 'Source link',
        sourceUrl: url,
      ));
      _linkController.clear();
    });
  }

  Future<void> _savePending(IntakeDraft draft) async {
    if (_isKid) return;
    try {
      await IntakeStore.save(draft);
    } on FormatException catch (e) {
      _snack(e.message);
      return;
    } catch (_) {
      _snack('Could not save that draft.');
      return;
    }
    setState(() {
      _pending.remove(draft);
    });
    await _reload();
  }

  void _discardPending(IntakeDraft draft) {
    setState(() => _pending.remove(draft));
  }

  Future<void> _deleteDraft(IntakeDraft draft) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this draft?'),
        content: Text(
          '"${draft.label}" will be removed from this device. Nothing on '
          'the network is touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await IntakeStore.delete(draft.id);
    await _reload();
  }

  /// Hand a file draft into the existing batch upload flow. Everything
  /// about pricing, wallet approval, resume and dedup stays inside that
  /// flow; on return, credits ride onto whatever actually uploaded and
  /// the consumed draft disappears.
  Future<void> _uploadDraft(IntakeDraft draft) async {
    if (_isKid) return;
    final path = draft.localPath?.trim() ?? '';
    if (path.isEmpty || !File(path).existsSync()) {
      _snack('That file is no longer at its recorded place — edit the '
          'draft to choose it again.');
      return;
    }
    final opener =
        widget.uploadOpener ?? _openRealUpload;
    final carried = await opener(context, draft);
    await _reload();
    if (!mounted) return;
    if (carried > 0) {
      _snack('Uploaded — credits moved onto the resulting file '
          '${carried == 1 ? 'record' : 'records'}.');
    }
  }

  Future<int> _openRealUpload(BuildContext context, IntakeDraft draft) async {
    final session = BatchUploadSession.instance;
    if (!session.idle) {
      if (mounted) {
        _snack('An upload is already running — finish it first.');
      }
      return 0;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BatchUploadScreen(
        initialPaths: [draft.localPath!],
        initialList: draft.listTitle,
      ),
    ));
    if (session.stage != BatchStage.done) return 0;
    final uploads = [
      for (final e in session.uploadedEntries)
        if (e.address != null) (source: e.source, address: e.address!),
    ];
    return carryCreditsIntoUploads(uploads);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    // Wide laptop windows get a readable column, not stretched fields.
    final body = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Bring media to W@tch in two ways: choose files from this '
              'device, or paste a link to where you found them. Saving '
              'keeps a draft on this device only — nothing is uploaded, '
              'paid for or published here.',
              style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'A pasted or shared link is a reference record. W@tch does '
              'not download from links; choose an authorized local file '
              'when you are ready to upload.',
              style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            _chooseSection(t),
            if (_pending.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('REVIEW',
                  style: _sectionStyle(t)),
              const SizedBox(height: 4),
              for (final draft in List<IntakeDraft>.of(_pending))
                _PendingCard(
                  draft: draft,
                  listTitles: _listTitles,
                  isKid: _isKid,
                  artworkPicker: widget.artworkPicker,
                  postersDirProvider: widget.postersDirProvider,
                  onSave: () => _savePending(draft),
                  onDiscard: () => _discardPending(draft),
                  onPickList: _promptNewList,
                ),
            ],
            const SizedBox(height: 24),
            Text('SAVED ON THIS DEVICE',
                style: _sectionStyle(t)),
            const SizedBox(height: 4),
            if (_drafts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No drafts yet. Files and links you review above are '
                  'kept here until you remove them or they upload.',
                  style: TextStyle(color: t.boneDim, fontSize: 12.5),
                ),
              )
            else
              for (final draft in _drafts) _DraftRow(draft: draft,
                  onUpload: () => _uploadDraft(draft),
                  onEdit: _editDraft,
                  onDelete: () => _deleteDraft(draft)),
            const SizedBox(height: 20),
            Text(
              'Drafts stay on this device — they never appear on the TV '
              'and are not synced. Uploaded media joins this device\'s '
              'library; other devices see it after a .watch-list '
              'transfer, and a channel publish is a separate, public '
              'step. Uploads themselves stay private to you and your '
              'linked devices.',
              style: TextStyle(color: t.ash, fontSize: 12, height: 1.45),
            ),
          ],
        ),
      ),
    );
    return Scaffold(
      backgroundColor: t.ink,
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Add to W@tch',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: body,
    );
  }

  TextStyle _sectionStyle(WiTokens t) => TextStyle(
        fontSize: 11,
        letterSpacing: 1.5,
        fontWeight: FontWeight.w700,
        color: t.ash,
      );

  Widget _chooseSection(WiTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy || _isKid ? null : _pickFiles,
            icon: const Icon(Icons.folder_open),
            label: Text(_busy ? 'Choosing…' : 'Choose media files'),
          ),
        ),
        if (!isDesktopPlatform) ...[
          const SizedBox(height: 6),
          Text(
            'On this phone the draft records the file\'s name and '
            'details; upload from a laptop where the file lives.',
            style: TextStyle(color: t.ash, fontSize: 12),
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('intake-link-field'),
          controller: _linkController,
          enabled: !_isKid,
          decoration: InputDecoration(
            labelText: 'Or paste a source link',
            hintText: 'https://…',
            errorText: _linkError,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Add link',
              icon: const Icon(Icons.add_link),
              onPressed: _isKid ? null : _addLink,
            ),
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
          onSubmitted: (_) => _isKid ? null : _addLink(),
        ),
      ],
    );
  }

  Future<String?> _promptNewList() async {
    return promptForText(
      context,
      title: 'New collection',
      hint: 'Collection name',
    );
  }

  Future<void> _editDraft(IntakeDraft draft) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DraftEditorSheet(
        draft: draft,
        listTitles: _listTitles,
        isKid: _isKid,
        artworkPicker: widget.artworkPicker,
        postersDirProvider: widget.postersDirProvider,
        onPickList: _promptNewList,
      ),
    );
    if (saved == true) await _reload();
  }
}

/// The review card for one not-yet-saved draft — keyboard-friendly,
/// advanced details collapsed by default.
class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.draft,
    required this.listTitles,
    required this.isKid,
    required this.artworkPicker,
    required this.postersDirProvider,
    required this.onSave,
    required this.onDiscard,
    required this.onPickList,
  });

  final IntakeDraft draft;
  final List<String> listTitles;
  final bool isKid;
  final Future<Uint8List?> Function() artworkPicker;
  final Future<Directory> Function()? postersDirProvider;
  final VoidCallback onSave;
  final VoidCallback onDiscard;
  final Future<String?> Function() onPickList;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Card(
      color: t.ink2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _DraftForm(
          key: ValueKey('intake-form-${draft.id}'),
          draft: draft,
          listTitles: listTitles,
          isKid: isKid,
          artworkPicker: artworkPicker,
          postersDirProvider: postersDirProvider,
          onPickList: onPickList,
          footer: (apply) => Wrap(
            spacing: 12,
            children: [
              FilledButton(
                onPressed: isKid
                    ? null
                    : () async {
                        if (await apply()) onSave();
                      },
                child: const Text('Save draft'),
              ),
              TextButton(
                onPressed: onDiscard,
                child: const Text('Discard'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet for editing a saved draft (same fields as the card).
class _DraftEditorSheet extends StatelessWidget {
  const _DraftEditorSheet({
    required this.draft,
    required this.listTitles,
    required this.isKid,
    required this.artworkPicker,
    required this.postersDirProvider,
    required this.onPickList,
  });

  final IntakeDraft draft;
  final List<String> listTitles;
  final bool isKid;
  final Future<Uint8List?> Function() artworkPicker;
  final Future<Directory> Function()? postersDirProvider;
  final Future<String?> Function() onPickList;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Edit draft', style: TextStyle(color: t.bone, fontSize: 16)),
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: _DraftForm(
                draft: draft,
                listTitles: listTitles,
                isKid: isKid,
                artworkPicker: artworkPicker,
                postersDirProvider: postersDirProvider,
                onPickList: onPickList,
                footer: (apply) => Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(
                      onPressed: isKid
                          ? null
                          : () async {
                              if (await apply()) {
                                try {
                                  await IntakeStore.save(draft);
                                  if (context.mounted) {
                                    Navigator.of(context).pop(true);
                                  }
                                  return;
                                } on FormatException catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                            SnackBar(content: Text(e.message)));
                                  }
                                } catch (_) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'Could not save that draft.')));
                                  }
                                }
                              }
                            },
                      child: const Text('Save changes'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One saved draft row: kind, label, chips, and its actions.
class _DraftRow extends StatelessWidget {
  const _DraftRow({
    required this.draft,
    required this.onUpload,
    required this.onEdit,
    required this.onDelete,
  });

  final IntakeDraft draft;
  final VoidCallback onUpload;
  final ValueChanged<IntakeDraft> onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final canUpload = isDesktopPlatform &&
        draft.isFile &&
        (draft.localPath?.trim().isNotEmpty ?? false);
    final missing = canUpload && !File(draft.localPath!).existsSync();
    return Card(
      color: t.ink2,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  draft.isLink ? Icons.link : Icons.description_outlined,
                  color: draft.isLink ? t.accent : t.boneDim,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    draft.label,
                    style: TextStyle(color: t.bone, fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                PopupMenuButton<String>(
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                        value: 'edit', child: Text('Edit details')),
                    if (canUpload && !missing)
                      const PopupMenuItem(
                          value: 'upload',
                          child: Text('Upload this file…')),
                    const PopupMenuItem(
                        value: 'delete', child: Text('Remove draft')),
                  ],
                  onSelected: (v) => switch (v) {
                    'edit' => onEdit(draft),
                    'upload' => onUpload(),
                    'delete' => onDelete(),
                    _ => null,
                  },
                ),
              ],
            ),
            const SizedBox(height: 2),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _chip(t, draft.isLink ? 'Reference link' : 'Local file'),
                if (draft.listTitle != null)
                  _chip(t, 'For "${draft.listTitle}"'),
                if (draft.language != null && draft.language!.isNotEmpty)
                  _chip(t, draft.language!),
                if (draft.sizeBytes != null && draft.isFile)
                  _chip(t, formatBytes(draft.sizeBytes!)),
                if (draft.isLink && draft.sourceUrl != null)
                  _chip(t, _hostOf(draft.sourceUrl!), truncate: true),
              ],
            ),
            if (draft.isLink && draft.sourceUrl != null) ...[
              const SizedBox(height: 4),
              Text(
                draft.sourceUrl!,
                style: TextStyle(color: t.ash, fontSize: 11.5),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
            if (missing) ...[
              const SizedBox(height: 4),
              Text(
                'File not found at its recorded place — edit the draft to '
                'choose it again.',
                style: TextStyle(color: t.rust, fontSize: 11.5),
              ),
            ] else if (draft.isFile && !canUpload) ...[
              const SizedBox(height: 4),
              Text(
                'Upload from a laptop where the file lives; this record '
                'stays on this device.',
                style: TextStyle(color: t.ash, fontSize: 11.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _hostOf(String url) {
    return Uri.tryParse(url)?.host ?? url;
  }

  Widget _chip(WiTokens t, String text, {bool truncate = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: t.ink,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        truncate && text.length > 32 ? '${text.substring(0, 31)}…' : text,
        style: TextStyle(color: t.boneDim, fontSize: 11),
      ),
    );
  }
}

/// The shared review-card form. Edits [draft] in place through
/// controllers. The footer builder receives `apply`, which syncs the
/// controllers into the draft, validates and returns whether the draft
/// is sound — the parent then persists (card) or pops (sheet). The form
/// itself never navigates.
class _DraftForm extends StatefulWidget {
  const _DraftForm({
    super.key,
    required this.draft,
    required this.listTitles,
    required this.isKid,
    required this.artworkPicker,
    required this.postersDirProvider,
    required this.onPickList,
    required this.footer,
  });

  final IntakeDraft draft;
  final List<String> listTitles;
  final bool isKid;
  final Future<Uint8List?> Function() artworkPicker;
  final Future<Directory> Function()? postersDirProvider;
  final Future<String?> Function() onPickList;
  final Widget Function(Future<bool> Function() apply) footer;

  @override
  State<_DraftForm> createState() => _DraftFormState();
}

class _DraftFormState extends State<_DraftForm> {
  static const _newListTile = '…new collection';
  static const _decideAtUpload = '';

  late final _title = TextEditingController(text: widget.draft.label);
  late final _creator =
      TextEditingController(text: widget.draft.credits.creator);
  late final _url =
      TextEditingController(text: widget.draft.sourceUrl ?? '');
  late final _language =
      TextEditingController(text: widget.draft.language ?? '');
  late final _sourceTitle =
      TextEditingController(text: widget.draft.credits.title);
  late final _licenseName =
      TextEditingController(text: widget.draft.credits.licenseName);
  late final _licenseUrl =
      TextEditingController(text: widget.draft.credits.licenseUrl);
  late final _attribution =
      TextEditingController(text: widget.draft.credits.attribution);
  late final _changes =
      TextEditingController(text: widget.draft.credits.changes);

  String? _listChoice;
  Uint8List? _artPreview;
  String? _error;

  @override
  void initState() {
    super.initState();
    _listChoice = widget.draft.listTitle ?? _decideAtUpload;
    if (widget.draft.artworkFile != null) {
      IntakeStore.readArtwork(
        widget.draft.artworkFile,
        postersDirProvider: widget.postersDirProvider,
      ).then((bytes) {
        if (mounted && bytes != null) {
          setState(() => _artPreview = bytes);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _creator,
      _url,
      _language,
      _sourceTitle,
      _licenseName,
      _licenseUrl,
      _attribution,
      _changes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickArtwork() async {
    final bytes = await widget.artworkPicker();
    if (bytes == null || !mounted) return;
    final cropped = await showDialog<Uint8List>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PosterCropDialog(bytes: bytes),
    );
    if (cropped == null || !mounted) return;
    try {
      final name = await IntakeStore.saveArtwork(
        cropped,
        postersDirProvider: widget.postersDirProvider,
      );
      widget.draft.artworkFile = name;
      setState(() => _artPreview = cropped);
    } catch (_) {
      setState(() => _error = 'Could not keep that image.');
    }
  }

  /// Sync the controllers into the draft and validate. Returns false
  /// (with the error shown) when the draft is not sound.
  Future<bool> apply() async {
    final draft = widget.draft;
    draft.label = _title.text;
    draft.sourceUrl = _url.text.trim().isEmpty ? null : _url.text.trim();
    draft.credits = MediaCredits(
      title: _sourceTitle.text,
      creator: _creator.text,
      sourceUrl: draft.sourceUrl ?? '',
      licenseName: _licenseName.text,
      licenseUrl: _licenseUrl.text,
      attribution: _attribution.text,
      changes: _changes.text,
    );
    draft.language = _language.text.trim().isEmpty ? null : _language.text;
    draft.listTitle =
        (_listChoice == _decideAtUpload) ? null : _listChoice;
    try {
      draft.validate();
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return false;
    }
    setState(() => _error = null);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final draft = widget.draft;
    final urlRequired = draft.isLink;
    return Form(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: widget.isKid ? null : _pickArtwork,
                child: Container(
                  width: 60,
                  height: 90,
                  decoration: BoxDecoration(
                    color: t.ink,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: _artPreview != null
                      ? Image.memory(_artPreview!, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _artFallback(t))
                      : _artFallback(t),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  key: const ValueKey('intake-title'),
                  controller: _title,
                  enabled: !widget.isKid,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                  maxLength: IntakeDraft.labelLimit,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('intake-creator'),
            controller: _creator,
            enabled: !widget.isKid,
            decoration: const InputDecoration(
              labelText: 'Creator / performers',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
            maxLength: 512,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('intake-url'),
            controller: _url,
            enabled: !widget.isKid,
            decoration: InputDecoration(
              labelText: urlRequired
                  ? 'Original source URL (required)'
                  : 'Original source URL (optional)',
              border: const OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            maxLength: 2048,
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              // Phone widths stack the two fields side by side would
              // squeeze both below usable; laptop widths keep the row.
              final narrow = constraints.maxWidth < 520;
              final languageField = TextFormField(
                key: const ValueKey('intake-language'),
                controller: _language,
                enabled: !widget.isKid,
                decoration: const InputDecoration(
                  labelText: 'Language (optional)',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  FilteringTextInputFormatter.singleLineFormatter,
                ],
                maxLength: IntakeDraft.languageLimit,
              );
              final collectionField = DropdownButtonFormField<String>(
                key: const ValueKey('intake-collection'),
                initialValue: _listChoice,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Collection',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: _decideAtUpload,
                    child: Text('Decide at upload'),
                  ),
                  for (final title in widget.listTitles)
                    DropdownMenuItem(value: title, child: Text(title)),
                  const DropdownMenuItem(
                    value: _newListTile,
                    child: Text('New collection…'),
                  ),
                ],
                onChanged: widget.isKid
                    ? null
                    : (v) async {
                        if (v == _newListTile) {
                          final typed = await widget.onPickList();
                          final trimmed = typed?.trim();
                          if (trimmed == null || trimmed.isEmpty) return;
                          setState(() => _listChoice = trimmed);
                        } else {
                          setState(() => _listChoice = v);
                        }
                      },
              );
              return narrow
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        languageField,
                        const SizedBox(height: 12),
                        collectionField,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: languageField),
                        const SizedBox(width: 12),
                        Expanded(child: collectionField),
                      ],
                    );
            },
          ),
          const SizedBox(height: 8),
          Theme(
            data: Theme.of(context)
                .copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text('Advanced details',
                  style: TextStyle(color: t.boneDim, fontSize: 13)),
              children: [
                TextFormField(
                  controller: _sourceTitle,
                  enabled: !widget.isKid,
                  decoration: const InputDecoration(
                    labelText: 'Source title (if different)',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                  maxLength: 512,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _licenseName,
                  enabled: !widget.isKid,
                  decoration: const InputDecoration(
                    labelText: 'Licence name',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                  maxLength: 256,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _licenseUrl,
                  enabled: !widget.isKid,
                  decoration: const InputDecoration(
                    labelText: 'Licence URL',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  maxLength: 2048,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _attribution,
                  enabled: !widget.isKid,
                  decoration: const InputDecoration(
                    labelText: 'Attribution / copyright notice',
                    border: OutlineInputBorder(),
                  ),
                  maxLength: 4096,
                  minLines: 1,
                  maxLines: 4,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _changes,
                  enabled: !widget.isKid,
                  decoration: const InputDecoration(
                    labelText: 'Changes to the original',
                    border: OutlineInputBorder(),
                  ),
                  maxLength: 4096,
                  minLines: 1,
                  maxLines: 4,
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(color: t.rust, fontSize: 12.5)),
            ),
          const SizedBox(height: 12),
          widget.footer(apply),
        ],
      ),
    );
  }

  Widget _artFallback(WiTokens t) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_outlined, color: t.ash, size: 20),
          const SizedBox(height: 2),
          Text(
            'Artwork',
            style: TextStyle(color: t.ash, fontSize: 9),
          ),
        ],
      );
}
