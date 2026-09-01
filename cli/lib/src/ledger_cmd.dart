import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'ledger.dart';
import 'bundle_out.dart';

/// `ledger list` / `ledger export` — the disaster-recovery half of the
/// content-hash ledger: rebuild a `.watch-list` bundle offline from
/// ledger rows (the datamaps recorded beside each row's manifest).
Future<int> runLedger(List<String> args) async {
  if (args.isEmpty || (args[0] != 'list' && args[0] != 'export')) {
    stderr.writeln('usage: watchit-upload ledger list\n'
        '       watchit-upload ledger export [--out PATH] '
        '[--list-name NAME] [--match SUBSTRING]');
    return 2;
  }
  final config = CliConfig.load();
  final ledger = Ledger.load(config.ledgerFile);

  if (args[0] == 'list') {
    if (ledger.length == 0) {
      stdout.writeln('ledger is empty (${config.ledgerFile.path}).');
      return 0;
    }
    for (final e in ledger.entries) {
      stdout.writeln('${e.date.split('T').first}  '
          '${(e.sizeBytes / (1024 * 1024)).toStringAsFixed(1).padLeft(8)} MB'
          '  ${e.name}'
          '${File(e.datamapPath ?? '').existsSync() ? '' : '  [datamap missing]'}');
    }
    stdout.writeln('${ledger.length} upload(s).');
    return 0;
  }

  String out = 'Recovered.watch-list';
  String listName = 'Recovered';
  String? match;
  for (var i = 1; i < args.length; i++) {
    switch (args[i]) {
      case '--out':
        out = args[++i];
      case '--list-name':
        listName = args[++i];
      case '--match':
        match = args[++i].toLowerCase();
      default:
        stderr.writeln('unknown option ${args[i]}');
        return 2;
    }
  }
  final entries = <BundleOutEntry>[];
  var missing = 0;
  for (final e in ledger.entries) {
    if (match != null && !e.name.toLowerCase().contains(match)) continue;
    final map = e.datamapPath != null ? File(e.datamapPath!) : null;
    if (map == null || !map.existsSync()) {
      missing++;
      stdout.writeln('skip (datamap missing): ${e.name}');
      continue;
    }
    entries.add(BundleOutEntry(
      name: e.name,
      datamapBytes: Uint8List.fromList(map.readAsBytesSync()),
    ));
  }
  if (entries.isEmpty) {
    stderr.writeln('nothing to export'
        '${missing > 0 ? ' ($missing datamap file(s) missing)' : ''}.');
    return 1;
  }
  writeBundle(File(out), listName, entries);
  stdout.writeln('wrote $out: ${entries.length} entr(y/ies)'
      '${missing > 0 ? ', $missing skipped (datamap missing)' : ''}.');
  return 0;
}
