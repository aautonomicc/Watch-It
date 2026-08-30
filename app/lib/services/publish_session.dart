import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ffmpeg.dart';
import 'publish_api.dart';
import 'publish_plan.dart';

/// The one running (or finished-but-unacknowledged) Upload batch.
///
/// Lives OUTSIDE the Upload screen so navigating away mid-upload loses
/// nothing: the batch keeps encoding/uploading in the background, and
/// reopening the Upload page shows it exactly where it stands — running
/// progress, a pending error's retry/skip/stop choice, or the done page
/// with its add-to-library actions. Previously the screen owned this
/// state, so returning showed a fresh setup page whose next upload was
/// refused by the core's single-slot job ("an upload is already
/// running") with no way back to the batch.
///
/// One batch at a time by design (the core's paid upload slot is single
/// too); the Upload screen only offers the setup page when [idle].
class PublishSession extends ChangeNotifier {
  PublishSession._();

  static PublishSession instance = PublishSession._();

  /// Fresh instance for tests (aborts any running loop first).
  @visibleForTesting
  static void resetForTesting() {
    instance._aborted = true;
    final pending = instance._errorAction;
    if (pending != null && !pending.isCompleted) {
      pending.complete(PublishErrorAction.stop);
    }
    instance._cleanupTempDir();
    instance = PublishSession._();
  }

  PublishApi? _api;
  FfmpegService? _ffmpeg;

  /// The ffmpeg integration a running batch encodes with — the Upload
  /// screen must not cancel this instance when it disposes.
  FfmpegService? get ffmpegInUse => idle ? null : _ffmpeg;

  PublishStage stage = PublishStage.idle;
  List<PublishQueueEntry> queue = [];
  int current = 0;
  Completer<PublishErrorAction>? _errorAction;
  Directory? _tempDir;
  bool _aborted = false;

  bool get idle => stage == PublishStage.idle;

  /// The entry the run stage is showing (current, clamped).
  PublishQueueEntry get currentEntry =>
      current < queue.length ? queue[current] : queue.last;

  List<PublishQueueEntry> get published =>
      [for (final e in queue) if (e.result != null) e];

  /// Kick off a batch. The caller (the Upload screen's setup page)
  /// guarantees [idle].
  void start({
    required PublishApi api,
    required FfmpegService ffmpeg,
    required List<PublishItem> items,
  }) {
    assert(idle);
    _api = api;
    _ffmpeg = ffmpeg;
    if (items.any((i) => i.needsEncode)) {
      // Sync on purpose: async file IO never completes in the widget
      // tests' fake-async zone, and this is a one-off cheap call.
      _tempDir = Directory.systemTemp.createTempSync('watchit-publish');
    }
    queue = [for (final item in items) PublishQueueEntry(item)];
    current = 0;
    stage = PublishStage.running;
    notifyListeners();
    unawaited(_run());
  }

  /// Answer a failed entry's retry/skip/stop choice.
  void resolveError(PublishErrorAction action) {
    final pending = _errorAction;
    if (pending != null && !pending.isCompleted) pending.complete(action);
  }

  /// Acknowledge a finished batch ("Upload more") — back to idle so the
  /// Upload screen shows the setup page again.
  void clear() {
    if (stage != PublishStage.done) return;
    stage = PublishStage.idle;
    queue = [];
    current = 0;
    _api = null;
    _ffmpeg = null;
    notifyListeners();
  }

  Future<void> _run() async {
    for (var i = 0; i < queue.length; i++) {
      if (_aborted) return;
      final entry = queue[i];
      current = i;
      notifyListeners();
      var done = false;
      while (!done) {
        try {
          await _runEntry(entry);
          done = true;
        } catch (e) {
          if (_aborted) return;
          entry.status = PublishEntryStatus.error;
          entry.error = '$e';
          notifyListeners();
          _errorAction = Completer<PublishErrorAction>();
          final action = await _errorAction!.future;
          _errorAction = null;
          if (_aborted) return;
          switch (action) {
            case PublishErrorAction.retry:
              entry.error = null;
              notifyListeners();
            case PublishErrorAction.skip:
              entry.status = PublishEntryStatus.skipped;
              notifyListeners();
              done = true;
            case PublishErrorAction.stop:
              _finishRun(markRemainingSkipped: true);
              return;
          }
        }
      }
    }
    _finishRun();
  }

  Future<void> _runEntry(PublishQueueEntry entry) async {
    final item = entry.item;
    var uploadPath = item.source.path;
    if (item.needsEncode) {
      // A retry after an upload failure reuses the finished encode.
      final existing = entry.tempPath;
      if (existing != null && File(existing).existsSync()) {
        uploadPath = existing;
      } else {
        entry.status = PublishEntryStatus.encoding;
        entry.encodeFraction = null;
        notifyListeners();
        final output =
            '${_tempDir!.path}${Platform.pathSeparator}${item.outputName}';
        await _ffmpeg!.encode(
          input: item.source.path,
          output: output,
          tier: item.tier,
          probe: item.source.probe,
          onProgress: (fraction) {
            entry.encodeFraction = fraction;
            notifyListeners();
          },
        );
        if (_aborted) throw FfmpegException('cancelled');
        entry.tempPath = output;
        uploadPath = output;
      }
    }
    entry.status = PublishEntryStatus.uploading;
    entry.job = null;
    notifyListeners();
    final id = await _api!.startUpload(uploadPath, name: item.outputName);
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_aborted) return;
      UploadJob job;
      try {
        job = await _api!.jobStatus(id);
      } catch (_) {
        continue; // Transient poll failure — next tick retries.
      }
      entry.job = job;
      notifyListeners();
      final result = job.result;
      if (job.phase == 'done' && result != null) {
        entry.result = result;
        entry.status = PublishEntryStatus.done;
        notifyListeners();
        _deleteTemp(entry);
        return;
      }
      if (job.phase == 'error') {
        throw PublishApiException(job.error ?? 'upload failed');
      }
    }
  }

  void _finishRun({bool markRemainingSkipped = false}) {
    if (markRemainingSkipped) {
      for (final entry in queue) {
        if (entry.status == PublishEntryStatus.pending ||
            entry.status == PublishEntryStatus.error) {
          entry.status = PublishEntryStatus.skipped;
        }
      }
    }
    stage = PublishStage.done;
    notifyListeners();
    _cleanupTempDir();
  }

  void _deleteTemp(PublishQueueEntry entry) {
    final path = entry.tempPath;
    if (path == null) return;
    entry.tempPath = null;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  void _cleanupTempDir() {
    final dir = _tempDir;
    _tempDir = null;
    if (dir == null) return;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

enum PublishStage { idle, running, done }

enum PublishEntryStatus { pending, encoding, uploading, done, error, skipped }

enum PublishErrorAction { retry, skip, stop }

class PublishQueueEntry {
  PublishQueueEntry(this.item);
  final PublishItem item;
  PublishEntryStatus status = PublishEntryStatus.pending;
  double? encodeFraction;
  UploadJob? job;
  UploadResult? result;
  String? error;
  String? tempPath;
}
