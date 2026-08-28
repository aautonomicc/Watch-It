import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/exit_info.dart';
import '../theme/tokens.dart';
import '../widgets/messenger.dart';

/// Android's own record of why the app previously closed (crashes,
/// system kills, normal exits), shown so a device with no debug access
/// can report a crash: reproduce it, reopen the app, copy this page.
class ExitInfoScreen extends StatefulWidget {
  const ExitInfoScreen({super.key, this.service});

  final ExitInfoService? service;

  @override
  State<ExitInfoScreen> createState() => _ExitInfoScreenState();
}

class _ExitInfoScreenState extends State<ExitInfoScreen> {
  List<ExitRecord>? _records;

  ExitInfoService get _service => widget.service ?? ExitInfoService.instance;

  @override
  void initState() {
    super.initState();
    _service.fetch().then((records) {
      if (mounted) setState(() => _records = records);
    });
  }

  Future<void> _copyAll() async {
    final records = _records ?? const <ExitRecord>[];
    final text = records.isEmpty
        ? 'No recorded exits.'
        : records.map((r) => r.reportText).join('\n---\n');
    await Clipboard.setData(ClipboardData(text: text));
    wiMessengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('Exit report copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final records = _records;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Why did the app close?',
            style: TextStyle(color: t.bone, fontSize: 17)),
        actions: [
          IconButton(
            icon: Icon(Icons.copy_all, color: t.ash),
            tooltip: 'Copy the whole report',
            onPressed: _copyAll,
          ),
        ],
      ),
      body: records == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text(
                  'Android keeps a record of why this app last closed — '
                  'including crashes the app itself never saw. After the '
                  'app closes on its own, reopen it, come back here and '
                  'use Copy to share the report.',
                  style:
                      TextStyle(color: t.ash, fontSize: 12.5, height: 1.4),
                ),
                const SizedBox(height: 12),
                if (records.isEmpty)
                  Text(
                    'No recorded exits yet.',
                    style: TextStyle(color: t.boneDim, fontSize: 14),
                  ),
                for (final r in records) _RecordCard(record: r),
              ],
            ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record});

  final ExitRecord record;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final highlight = record.isAbnormal;
    return Card(
      color: t.ink2,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  highlight
                      ? Icons.warning_amber_outlined
                      : Icons.check_circle_outline,
                  size: 18,
                  color: highlight ? Colors.amber : t.ash,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    record.reasonName,
                    style: TextStyle(
                      color: highlight ? Colors.amber : t.bone,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${record.time} · code ${record.reason} · '
              'status ${record.status}',
              style: TextStyle(color: t.ash, fontSize: 12),
            ),
            if (record.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              SelectableText(
                record.description,
                style: TextStyle(color: t.boneDim, fontSize: 12.5),
              ),
            ],
            if (record.trace.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                record.trace,
                style: TextStyle(
                  color: t.boneDim,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.3,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
