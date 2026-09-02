import 'package:flutter/material.dart';

import '../services/import_review.dart';
import '../services/match_review.dart';
import '../theme/tokens.dart';
import '../widgets/match_review_cards.dart';

/// Review screen for datamap imports — the batch uploader's match
/// carousel without the upload legs. [ImportReviewSession] does the
/// work and survives navigation; this screen renders whichever stage
/// it is in: matching progress, the confirm carousel, then the added
/// summary. Entry point: My Media → Add to library with `.datamap`
/// picks (media_lists_screen.dart).
class ImportReviewScreen extends StatefulWidget {
  const ImportReviewScreen({super.key});

  @override
  State<ImportReviewScreen> createState() => _ImportReviewScreenState();
}

class _ImportReviewScreenState extends State<ImportReviewScreen> {
  final ImportReviewSession _session = ImportReviewSession.instance;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      backgroundColor: t.ink,
      appBar: AppBar(
        backgroundColor: t.ink,
        foregroundColor: t.bone,
        title: const Text('Import review'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: switch (_session.stage) {
          ImportReviewStage.idle ||
          ImportReviewStage.matching ||
          ImportReviewStage.reviewing =>
            _matchingChildren(t),
          ImportReviewStage.applying => _applyingChildren(t),
          ImportReviewStage.done => _doneChildren(t),
        },
      ),
    );
  }

  // ── matching + carousel ──────────────────────────────────────────────

  List<Widget> _matchingChildren(WiTokens t) {
    final confirm = _session.pendingConfirm;
    final albumConfirm = _session.pendingAlbumConfirm;
    final reviewing = _session.reviewingMatches;
    final decided = switch (_session.confirmables
        .elementAtOrNull(_session.confirmIndex)) {
      final BatchConfirm c => c.decided,
      final AlbumConfirm a => a.decided,
      _ => false,
    };
    return [
      if (reviewing) ...[
        Row(
          children: [
            IconButton(
              tooltip: 'Previous',
              onPressed: _session.confirmIndex > 0
                  ? _session.confirmPrevious
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                'Review matches · ${_session.confirmIndex + 1} of '
                '${_session.confirmables.length}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: t.bone,
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Next',
              onPressed:
                  _session.confirmIndex < _session.confirmables.length - 1
                      ? _session.confirmNext
                      : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (decided) ...[
          const SizedBox(height: 4),
          Text(
            'Already answered — a new choice replaces the earlier one.',
            style: TextStyle(color: t.ash, fontSize: 12),
          ),
        ],
      ] else ...[
        Text(
          'Matching imports · ${_session.matchDone} of '
          '${_session.matchTotal}',
          style: TextStyle(
              color: t.bone, fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: _session.matchTotal == 0
              ? null
              : _session.matchDone / _session.matchTotal,
          backgroundColor: t.ink2,
        ),
        const SizedBox(height: 8),
        if (_session.currentName != null)
          Text(_session.currentName!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.boneDim, fontSize: 13)),
        const SizedBox(height: 6),
        Text(
          'Looking each name up on MusicBrainz / TMDB so imports land '
          'sorted with artwork and descriptions. Clean matches are '
          'accepted automatically; anything uncertain gets one look.',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
      ],
      if (confirm != null) ...[
        const SizedBox(height: 12),
        MatchConfirmCard(session: _session, confirm: confirm),
      ],
      if (albumConfirm != null) ...[
        const SizedBox(height: 12),
        AlbumMatchConfirmCard(session: _session, confirm: albumConfirm),
      ],
      if (reviewing && _session.undecidedConfirmCount == 0) ...[
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _session.finishConfirms,
          icon: const Icon(Icons.done_all),
          label: const Text('Add to library'),
        ),
      ],
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: _session.finishRemainingAsIs,
            child: Text('Skip matching — add the rest as-is',
                style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () {
              _session.cancelAll();
              Navigator.of(context).pop();
            },
            child: Text('Cancel import', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    ];
  }

  // ── applying ─────────────────────────────────────────────────────────

  List<Widget> _applyingChildren(WiTokens t) => [
        const SizedBox(height: 32),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 16),
        Center(
          child: Text('Adding to your library…',
              style: TextStyle(color: t.boneDim, fontSize: 13)),
        ),
      ];

  // ── done ─────────────────────────────────────────────────────────────

  List<Widget> _doneChildren(WiTokens t) {
    final lists = _session.listTitles.join(', ');
    final parts = [
      if (_session.matchedCount > 0) '${_session.matchedCount} matched',
      if (_session.customCount > 0)
        '${_session.customCount} with manual details',
      if (_session.asIsCount > 0)
        '${_session.asIsCount} kept as-is',
      if (_session.skippedCount > 0) '${_session.skippedCount} not added',
    ];
    return [
      Text(
        _session.addedCount == 0
            ? 'Nothing added'
            : 'Added ${_session.addedCount} '
                '${_session.addedCount == 1 ? 'entry' : 'entries'} to '
                '$lists',
        style: TextStyle(
            color: t.bone, fontSize: 16, fontWeight: FontWeight.w600),
      ),
      if (parts.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(parts.join(' · '),
            style: TextStyle(color: t.ash, fontSize: 12)),
      ],
      if (_session.applyError != null) ...[
        const SizedBox(height: 8),
        Text('Something went wrong: ${_session.applyError}',
            style: TextStyle(color: t.rust, fontSize: 12)),
      ],
      const SizedBox(height: 12),
      for (final item in _session.items)
        if (item.status != 'skipped')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  item.status == 'matched' || item.status == 'custom'
                      ? Icons.check
                      : Icons.remove,
                  size: 14,
                  color: item.status == 'matched' || item.status == 'custom'
                      ? t.signalOk
                      : t.ash,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    item.finalName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: t.boneDim,
                        fontSize: 12,
                        fontFamily: wiMonoFamily,
                        fontFamilyFallback: wiMonoFallback),
                  ),
                ),
              ],
            ),
          ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () {
          _session.clear();
          Navigator.of(context).pop();
        },
        child: const Text('Done'),
      ),
    ];
  }
}
