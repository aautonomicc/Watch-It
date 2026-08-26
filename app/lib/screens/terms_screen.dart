import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/terms.dart';
import '../theme/tokens.dart';

/// The Terms of Use & Disclaimer, in two modes: with [onAccept] set it
/// is the first-launch gate (no back navigation, Accept/Exit bar at the
/// bottom); without it it is a plain readable page pushed from
/// Settings → About.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key, this.onAccept});

  /// Called when the user accepts. Non-null = gate mode.
  final VoidCallback? onAccept;

  bool get _isGate => onAccept != null;

  void _exitApp() {
    // Desktop has no OS back stack to pop to — leave the process.
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      exit(0);
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return PopScope(
      // The gate must not be escapable via the system back gesture.
      canPop: !_isGate,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: t.ink,
          elevation: 0,
          automaticallyImplyLeading: !_isGate,
          title: Text(
            'Terms of Use & Disclaimer',
            style: TextStyle(color: t.bone, fontSize: 17),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Text(
              kTermsIntro,
              style: TextStyle(color: t.boneDim, fontSize: 13.5, height: 1.4),
            ),
            for (final section in kTermsSections) ...[
              Padding(
                padding: const EdgeInsets.only(top: 20, bottom: 6),
                child: Text(
                  section.title,
                  style: TextStyle(
                    color: t.bone,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                section.body,
                style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.45),
              ),
            ],
          ],
        ),
        bottomNavigationBar: _isGate
            ? SafeArea(
                child: Container(
                  color: t.ink2,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: _exitApp,
                        child: Text('Exit', style: TextStyle(color: t.ash)),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: onAccept,
                        style: FilledButton.styleFrom(
                          backgroundColor: t.accent,
                          foregroundColor: t.ink,
                        ),
                        child: const Text('I agree'),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }
}
