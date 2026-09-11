import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/experience_view.dart';
import '../services/list_import.dart' show ListImportException;
import '../services/public_address_import.dart';
import '../services/tv_settings.dart';
import '../theme/tokens.dart';
import 'experience_switch.dart';
import 'skaists_bloom.dart';

/// Result of a successful verify-then-Keep. Saving still happens in
/// the caller (Luna's addEntriesToLists path) so the engineering
/// contract stays: read-only probe, then a private library bookmark.
typedef ReceivedPiece = ({String address, String name, int? size});

/// Verify-first receive sheet. New bee is emotion / choose-click —
/// never numbered steps. Raver and Cypherpunk keep the same doors
/// at higher density.
class ReceivePieceDialog extends StatefulWidget {
  const ReceivePieceDialog({super.key, this.base});

  /// Embedded-client URL override for tests.
  final String? base;

  @override
  State<ReceivePieceDialog> createState() => _ReceivePieceDialogState();
}

class _ReceivePieceDialogState extends State<ReceivePieceDialog> {
  final _address = TextEditingController();
  final _name = TextEditingController();
  final _addressFocus = FocusNode();
  bool _checking = false;
  bool _celebrating = false;
  PublicAddressInspection? _inspection;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _name.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  ExperienceCopy _copyOf(BuildContext context) => ExperienceCopy.of(context);

  SkaistsBloomMoment _bloomMoment(ExperienceView view) {
    if (_celebrating) return SkaistsBloomMoment.celebrate;
    if (_inspection != null) {
      return switch (view) {
        ExperienceView.newBee => SkaistsBloomMoment.idle,
        ExperienceView.raver => SkaistsBloomMoment.celebrate,
        ExperienceView.cypherpunk => SkaistsBloomMoment.flash,
      };
    }
    return switch (view) {
      ExperienceView.newBee => SkaistsBloomMoment.idle,
      ExperienceView.raver => SkaistsBloomMoment.celebrate,
      ExperienceView.cypherpunk => SkaistsBloomMoment.still,
    };
  }

  Future<void> _lookUp() async {
    setState(() {
      _checking = true;
      _error = null;
      _inspection = null;
    });
    try {
      final result =
          await inspectPublicAddress(_address.text, base: widget.base);
      if (!mounted) return;
      setState(() {
        _inspection = result;
        _address.text = result.address;
        if (_name.text.trim().isEmpty) {
          _name.text = ExperienceCopy(wiExperienceView.value).defaultName;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _displayError(e));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _displayError(Object error) {
    if (wiExperienceView.value == ExperienceView.cypherpunk &&
        error is ListImportException) {
      return error.message;
    }
    return humanPublicAddressError(error);
  }

  Future<void> _keep() async {
    final inspection = _inspection;
    final name = _name.text.trim();
    if (inspection == null || name.isEmpty) return;
    if (wiExperienceView.value == ExperienceView.raver && !_celebrating) {
      setState(() => _celebrating = true);
      await Future<void>.delayed(const Duration(milliseconds: 720));
      if (!mounted) return;
    }
    Navigator.of(context).pop<ReceivedPiece>(
      (address: inspection.address, name: name, size: inspection.sizeBytes),
    );
  }

  void _notThis() {
    setState(() {
      _inspection = null;
      _error = null;
      _address.clear();
      _name.clear();
    });
    _addressFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ExperienceView>(
      valueListenable: wiExperienceView,
      builder: (context, view, _) {
        final t = WiTokens.of(context);
        final copy = _copyOf(context);
        final tv = TvSettings.instance.enabled;
        final size = _inspection?.sizeBytes;
        final sizeLabel = size == null ? null : formatBytes(size);
        final bloom = _bloomMoment(view);
        return AlertDialog(
          backgroundColor: t.ink2,
          insetPadding: EdgeInsets.symmetric(
            horizontal: tv ? 48 : 20,
            vertical: tv ? 36 : 24,
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SkaistsBloom(moment: bloom, size: tv ? 52 : 44),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      copy.receiveTitle,
                      style: TextStyle(
                        color: t.bone,
                        fontSize: tv ? 20 : 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const ExperienceSwitch(compact: true),
            ],
          ),
          content: SizedBox(
            width: tv ? 560 : 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    copy.receiveEmotion,
                    style: TextStyle(
                      color: t.boneDim,
                      fontSize: tv ? 15 : 13.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _address,
                    focusNode: _addressFocus,
                    autofocus: true,
                    keyboardType: TextInputType.text,
                    style: TextStyle(
                      color: t.bone,
                      fontSize: 14,
                      fontFamily: copy.isCypherpunk ? wiMonoFamily : null,
                      fontFamilyFallback:
                          copy.isCypherpunk ? wiMonoFallback : null,
                    ),
                    decoration: InputDecoration(
                      labelText: copy.addressLabel,
                      labelStyle: TextStyle(color: t.ash),
                      hintText: copy.addressHint,
                      hintStyle: TextStyle(color: t.ash.withValues(alpha: .7)),
                    ),
                    onSubmitted: (_) => _checking ? null : _lookUp(),
                    onChanged: (_) {
                      if (_error != null || _inspection != null) {
                        setState(() {
                          _error = null;
                          _inspection = null;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 14),
                  if (_inspection == null)
                    FilledButton(
                      onPressed: _checking ? null : _lookUp,
                      style: FilledButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: t.ink,
                        minimumSize: Size(0, tv ? 52 : 48),
                      ),
                      child: _checking
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: t.ink,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(copy.lookingUp),
                              ],
                            )
                          : Text(copy.lookUpVerb),
                    ),
                  if (_inspection != null) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        border: Border.all(color: t.accent.withValues(alpha: .45)),
                        borderRadius: BorderRadius.circular(10),
                        color: t.ink,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.verified_outlined,
                                  color: t.accent, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  copy.verifiedLine(sizeLabel),
                                  style: TextStyle(
                                    color: t.accent,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (copy.isCypherpunk) ...[
                            const SizedBox(height: 8),
                            Text(
                              _inspection!.address,
                              style: TextStyle(
                                color: t.ash,
                                fontSize: 11,
                                fontFamily: wiMonoFamily,
                                fontFamilyFallback: wiMonoFallback,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              copy.cypherpunkVerifyNote,
                              style: TextStyle(
                                color: t.ash,
                                fontSize: 11,
                                height: 1.35,
                                fontFamily: wiMonoFamily,
                                fontFamilyFallback: wiMonoFallback,
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Text(
                            copy.rightsLine,
                            style: TextStyle(
                              color: t.boneDim,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _name,
                            style: TextStyle(color: t.bone, fontSize: 14),
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: copy.nameLabel,
                              labelStyle: TextStyle(color: t.ash),
                              hintText: copy.nameHint,
                              hintStyle:
                                  TextStyle(color: t.ash.withValues(alpha: .7)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: _name.text.trim().isEmpty || _celebrating
                        ? null
                        : () => unawaited(_keep()),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: t.ink,
                        minimumSize: Size(0, tv ? 52 : 48),
                      ),
                      child: Text(copy.keepVerb),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: _notThis,
                      child: Text(copy.notThisVerb,
                          style: TextStyle(color: t.ash)),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: t.rust,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _checking ? null : _lookUp,
                          child: Text(copy.tryAgainVerb,
                              style: TextStyle(color: t.accent)),
                        ),
                        TextButton(
                          onPressed: _notThis,
                          child: Text(copy.pasteDifferentVerb,
                              style: TextStyle(color: t.boneDim)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (_inspection == null)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(copy.notThisVerb, style: TextStyle(color: t.ash)),
              ),
          ],
        );
      },
    );
  }
}

/// Opens the receive sheet. Returns null if the user walks away.
Future<ReceivedPiece?> showReceivePieceFlow(
  BuildContext context, {
  String? base,
}) {
  return showDialog<ReceivedPiece>(
    context: context,
    builder: (context) => ReceivePieceDialog(base: base),
  );
}
