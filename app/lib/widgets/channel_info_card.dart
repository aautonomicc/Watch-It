import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_list.dart';
import '../screens/channels_screen.dart';
import '../services/channel_service.dart';
import '../theme/tokens.dart';
import 'channel_badge.dart';
import 'channel_avatar.dart';

/// The channel's face — the full-width profile header above a channel
/// list's poster grid: 72px circular avatar, name, "by author · N
/// entries", description (2 lines, tap to expand), and the channel's
/// `wchn1-` code with tap-to-copy.
///
/// The code line is deliberate anti-impersonation UI: there is no handle
/// registry and no uniqueness — anyone can type any author name — so the
/// code stays the only real identity and is always in sight, styled
/// exactly like the QR dialog shows it. On the owner's own channel the
/// card gains an edit pencil (the profile edits ride the next publish).
class ChannelInfoCard extends StatefulWidget {
  const ChannelInfoCard({super.key, required this.list, this.onEdited});

  final MediaList list;

  /// Called after the own-channel edit screen saved changes.
  final VoidCallback? onEdited;

  @override
  State<ChannelInfoCard> createState() => _ChannelInfoCardState();
}

class _ChannelInfoCardState extends State<ChannelInfoCard> {
  String _description = '';
  bool _expanded = false;
  bool _isOwn = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pubkey = widget.list.channelPubkey;
    if (pubkey == null) return;
    // Description lives on the subscription record (from the last
    // imported manifest) — or, for the owner's own channel, on the
    // channel config. Both are best-effort: the card renders without.
    final record = await ChannelService.instance.record(pubkey);
    var description = record?.description ?? '';
    var isOwn = false;
    if (record == null) {
      try {
        final status = await ChannelService.instance.api.status();
        final own = status.own;
        if (own != null && own.pubkey.toLowerCase() == pubkey) {
          isOwn = true;
          description = own.description;
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _description = description;
        _isOwn = isOwn;
      });
    }
  }

  Future<void> _edit() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const EditChannelScreen()),
    );
    if (changed == true) {
      unawaited(ChannelService.instance.syncNow());
      widget.onEdited?.call();
      await _load();
    }
  }

  void _copyCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Channel code copied')));
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final list = widget.list;
    final author = list.channelAuthor;
    final count = list.entries.length;
    final infoLine = [
      if (author != null && author.isNotEmpty) 'by $author',
      '$count ${count == 1 ? 'entry' : 'entries'}',
    ].join(' · ');
    final code = channelCodeFromPubkeyHex(list.channelPubkey ?? '');
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.ink2,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: t.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChannelAvatar(memberName: list.channelAvatar, size: 72),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        list.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: t.bone,
                            fontSize: 18,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (_isOwn)
                      IconButton(
                        tooltip: 'Edit channel details',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.edit_outlined,
                            color: t.ash, size: 18),
                        onPressed: _edit,
                      ),
                    const ChannelBadge(),
                  ],
                ),
                Text(infoLine,
                    style: TextStyle(color: t.ash, fontSize: 12.5)),
                if (_description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: GestureDetector(
                      onTap: () =>
                          setState(() => _expanded = !_expanded),
                      child: Text(
                        _description,
                        maxLines: _expanded ? null : 2,
                        overflow:
                            _expanded ? null : TextOverflow.ellipsis,
                        style: TextStyle(
                            color: t.boneDim,
                            fontSize: 12.5,
                            height: 1.35),
                      ),
                    ),
                  ),
                if (code.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: InkWell(
                      onTap: () => _copyCode(code),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              code,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: wiMonoFamily,
                                fontFamilyFallback: wiMonoFallback,
                                fontSize: 11,
                                color: WiTokens.channelAmber,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.copy, color: t.ash, size: 13),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
