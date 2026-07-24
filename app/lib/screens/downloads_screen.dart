import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/download_manager.dart';
import '../theme/tokens.dart';

/// Settings → Downloads: the download queue with per-item pause/resume/
/// remove, pause-all/resume-all, the storage location (desktop), and the
/// pause-on-playback behaviour.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  String? _downloadDir;
  PauseDownloadsOnPlay _pauseOnPlay = PauseDownloadsOnPlay.ask;

  /// Addresses ticked for deletion via the per-item checkboxes.
  final Set<String> _selected = {};

  /// Custom folders are desktop-only; Android keeps downloads app-private
  /// so no storage permissions are ever needed.
  bool get _canPickFolder =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.ensureLoaded();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final dir = await AppSettings.downloadDirPath();
    final pauseOnPlay = await AppSettings.pauseDownloadsOnPlay();
    if (mounted) {
      setState(() {
        _downloadDir = dir;
        _pauseOnPlay = pauseOnPlay;
      });
    }
  }

  Future<void> _pickFolder() async {
    final picked = await getDirectoryPath();
    if (picked == null) return;
    await AppSettings.setDownloadDirPath(picked);
    if (mounted) setState(() => _downloadDir = picked);
  }

  Future<void> _resetFolder() async {
    await AppSettings.setDownloadDirPath(null);
    if (mounted) setState(() => _downloadDir = null);
  }

  Future<void> _pickPauseOnPlay() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<PauseDownloadsOnPlay>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('When playback starts',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<PauseDownloadsOnPlay>(
            groupValue: _pauseOnPlay,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in PauseDownloadsOnPlay.values)
                  RadioListTile<PauseDownloadsOnPlay>(
                    value: option,
                    activeColor: t.copper,
                    title: Text(
                      pauseOnPlayLabel(option),
                      style: TextStyle(color: t.bone, fontSize: 14),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await AppSettings.setPauseDownloadsOnPlay(picked);
    if (mounted) setState(() => _pauseOnPlay = picked);
  }

  Future<void> _confirmRemove(DownloadTask task) async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Remove download?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          '"${task.name}" is deleted from this device. The file stays on '
          'Autonomi — you can download or stream it again any time.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Remove', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed == true) await DownloadManager.instance.remove(task.address);
  }

  /// Delete the ticked downloads, or every download when [all].
  Future<void> _confirmDeleteMany({required bool all}) async {
    final manager = DownloadManager.instance;
    final addresses =
        all ? [for (final task in manager.tasks) task.address] : _selected.toList();
    if (addresses.isEmpty) return;
    final t = WiTokens.of(context);
    final count = addresses.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text(
          all
              ? 'Delete all downloads?'
              : 'Delete $count ${count == 1 ? 'download' : 'downloads'}?',
          style: TextStyle(color: t.bone, fontSize: 16),
        ),
        content: Text(
          'The ${count == 1 ? 'file is' : 'files are'} deleted from this '
          'device. Everything stays on Autonomi — you can download or '
          'stream it again any time.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Delete', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await manager.removeMany(addresses);
    if (mounted) setState(_selected.clear);
  }

  Widget _sectionLabel(WiTokens t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
            color: t.ash,
          ),
        ),
      );

  Widget _taskTile(WiTokens t, DownloadTask task) {
    final (statusText, statusColor) = switch (task.status) {
      DownloadStatus.queued => ('Queued', t.boneDim),
      DownloadStatus.downloading => ('Downloading', t.copper),
      DownloadStatus.paused => ('Paused', t.boneDim),
      DownloadStatus.done => ('Downloaded', t.copper),
      DownloadStatus.error => (task.error ?? 'Failed', t.rust),
    };
    final active = task.active;
    final resumable = task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 8, 8),
      child: Row(
        children: [
          Checkbox(
            value: _selected.contains(task.address),
            activeColor: t.copper,
            checkColor: t.ink,
            side: BorderSide(color: t.ash),
            visualDensity: VisualDensity.compact,
            onChanged: (checked) => setState(() => checked == true
                ? _selected.add(task.address)
                : _selected.remove(task.address)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.bone, fontSize: 13.5),
                ),
                const SizedBox(height: 6),
                if (task.status != DownloadStatus.done) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 4,
                      child: LinearProgressIndicator(
                        value: task.progress,
                        backgroundColor: t.ink2,
                        color: t.copper,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                ],
                Text(
                  task.status == DownloadStatus.done
                      ? '$statusText · ${downloadSizeLabel(task)}'
                      : '$statusText · ${downloadSizeLabel(task)}'
                          '${task.progress != null ? ' · '
                              '${(task.progress! * 100).round()}%' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: statusColor, fontSize: 11.5),
                ),
              ],
            ),
          ),
          if (active)
            IconButton(
              tooltip: 'Pause',
              icon: Icon(Icons.pause, color: t.boneDim, size: 20),
              onPressed: () => DownloadManager.instance.pause(task.address),
            ),
          if (resumable)
            IconButton(
              tooltip: task.status == DownloadStatus.error
                  ? 'Retry'
                  : 'Resume',
              icon: Icon(
                  task.status == DownloadStatus.error
                      ? Icons.refresh
                      : Icons.play_arrow,
                  color: t.copper,
                  size: 20),
              onPressed: () => DownloadManager.instance.resume(task.address),
            ),
          IconButton(
            tooltip: 'Remove',
            icon: Icon(Icons.delete_outline, color: t.ash, size: 20),
            onPressed: () => _confirmRemove(task),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final manager = DownloadManager.instance;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title:
            Text('Downloads', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final tasks = manager.tasks;
          // Drop selections whose task has since left the queue.
          _selected.removeWhere(
              (addr) => !tasks.any((task) => task.address == addr));
          final anyActive = manager.hasActive;
          final anyPaused = tasks.any((task) =>
              task.status == DownloadStatus.paused ||
              task.status == DownloadStatus.error);
          return ListView(
            children: [
              _sectionLabel(t, 'QUEUE'),
              if (tasks.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Nothing downloaded yet — use the Download button on '
                    'any movie or episode page.',
                    style: TextStyle(fontSize: 12.5, color: t.ash),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      if (anyActive)
                        TextButton.icon(
                          onPressed: manager.pauseAll,
                          icon: Icon(Icons.pause, size: 16, color: t.boneDim),
                          label: Text('Pause all',
                              style: TextStyle(
                                  color: t.boneDim, fontSize: 12.5)),
                        ),
                      if (anyPaused)
                        TextButton.icon(
                          onPressed: manager.resumeAll,
                          icon: Icon(Icons.play_arrow,
                              size: 16, color: t.copper),
                          label: Text('Resume all',
                              style: TextStyle(
                                  color: t.copper, fontSize: 12.5)),
                        ),
                      if (_selected.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => _confirmDeleteMany(all: false),
                          icon: Icon(Icons.delete_outline,
                              size: 16, color: t.rust),
                          label: Text('Delete selected (${_selected.length})',
                              style:
                                  TextStyle(color: t.rust, fontSize: 12.5)),
                        ),
                      TextButton.icon(
                        onPressed: () => _confirmDeleteMany(all: true),
                        icon: Icon(Icons.delete_sweep_outlined,
                            size: 16, color: t.rust),
                        label: Text('Delete all',
                            style: TextStyle(color: t.rust, fontSize: 12.5)),
                      ),
                    ],
                  ),
                ),
                for (final task in tasks) _taskTile(t, task),
              ],
              _sectionLabel(t, 'STORAGE'),
              ListTile(
                leading: Icon(Icons.folder_outlined, color: t.copper),
                title: Text('Download location',
                    style: TextStyle(color: t.bone, fontSize: 15)),
                subtitle: Text(
                  !_canPickFolder
                      ? 'App-private storage (no permissions needed)'
                      : _downloadDir ?? 'App data folder (default)',
                  style: TextStyle(color: t.ash, fontSize: 12),
                ),
                trailing: _canPickFolder
                    ? Icon(Icons.chevron_right, color: t.ash)
                    : null,
                onTap: _canPickFolder ? _pickFolder : null,
              ),
              if (_canPickFolder && _downloadDir != null)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _resetFolder,
                      child: Text('Use the default folder again',
                          style:
                              TextStyle(color: t.boneDim, fontSize: 12.5)),
                    ),
                  ),
                ),
              if (_canPickFolder)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'New downloads are saved here; files already '
                    'downloaded stay where they are.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
              _sectionLabel(t, 'PLAYBACK'),
              ListTile(
                leading: Icon(Icons.pause_circle_outline, color: t.copper),
                title: Text('Downloads while playing',
                    style: TextStyle(color: t.bone, fontSize: 15)),
                subtitle: Text(
                  pauseOnPlayLabel(_pauseOnPlay),
                  style: TextStyle(color: t.ash, fontSize: 12),
                ),
                trailing: Icon(Icons.chevron_right, color: t.ash),
                onTap: _pickPauseOnPlay,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  'Streaming and downloading share the network connection, '
                  'so pausing downloads during playback can help on slower '
                  'lines. Paused downloads resume automatically when the '
                  'player closes. Playing an already-downloaded file never '
                  'pauses anything.',
                  style: TextStyle(fontSize: 11.5, color: t.ash),
                ),
              ),
              const SizedBox(height: 40),
            ],
          );
        },
      ),
    );
  }
}

/// Human label for the pause-on-playback behaviour options.
String pauseOnPlayLabel(PauseDownloadsOnPlay value) => switch (value) {
      PauseDownloadsOnPlay.ask => 'Ask every time',
      PauseDownloadsOnPlay.always => 'Always pause downloads',
      PauseDownloadsOnPlay.never => 'Never pause downloads',
    };
