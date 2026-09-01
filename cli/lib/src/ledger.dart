import 'dart:convert';
import 'dart:io';

/// The content-hash upload ledger (2026-09-01 decision, minimal shape):
/// a global append-only `~/.watchit-upload/ledger.jsonl`, one JSON line
/// per uploaded file. `prepare` looks every source file's sha256 up here
/// and marks hits `already-uploaded` (dedup by content, not path — moved,
/// renamed, and re-organized files never re-quote or re-pay); `upload`
/// appends the line at the same moment the manifest entry flips to
/// `uploaded`; `ledger export` rebuilds a .watch-list bundle offline from
/// these rows (disaster recovery for lost lists).
class LedgerEntry {
  LedgerEntry({
    required this.sha256,
    required this.name,
    required this.sizeBytes,
    required this.date,
    this.address,
    this.datamapPath,
    this.manifestPath,
  });

  /// sha256 of the source file's bytes (streamed once during prepare).
  final String sha256;

  /// Final W@tch name the file was uploaded under.
  final String name;
  final int sizeBytes;

  /// ISO-8601 upload date.
  final String date;

  /// Derived XOR address, when known (recorded when the devserver
  /// retrievability check ran, or ant reported one).
  final String? address;

  /// Where the `.datamap` file was stored (beside the manifest).
  final String? datamapPath;
  final String? manifestPath;

  Map<String, dynamic> toJson() => {
        'sha256': sha256,
        'name': name,
        'size_bytes': sizeBytes,
        'date': date,
        if (address != null) 'address': address,
        if (datamapPath != null) 'datamap': datamapPath,
        if (manifestPath != null) 'manifest': manifestPath,
      };

  static LedgerEntry? fromJson(Map<String, dynamic> m) {
    final sha = m['sha256'];
    final name = m['name'];
    if (sha is! String || name is! String) return null;
    return LedgerEntry(
      sha256: sha,
      name: name,
      sizeBytes: (m['size_bytes'] as num?)?.toInt() ?? 0,
      date: m['date'] as String? ?? '',
      address: m['address'] as String?,
      datamapPath: m['datamap'] as String?,
      manifestPath: m['manifest'] as String?,
    );
  }
}

class Ledger {
  Ledger(this.file, this._bySha);

  final File file;
  final Map<String, LedgerEntry> _bySha;

  static Ledger load(File file) {
    final bySha = <String, LedgerEntry>{};
    if (file.existsSync()) {
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final entry =
              LedgerEntry.fromJson(jsonDecode(line) as Map<String, dynamic>);
          if (entry != null) bySha[entry.sha256] = entry;
        } catch (_) {
          // A corrupt line never blocks the rest of the ledger.
        }
      }
    }
    return Ledger(file, bySha);
  }

  LedgerEntry? lookup(String sha256) => _bySha[sha256];
  int get length => _bySha.length;
  Iterable<LedgerEntry> get entries => _bySha.values;

  /// Append-only write; the in-memory index updates with it.
  void append(LedgerEntry entry) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${jsonEncode(entry.toJson())}\n',
        mode: FileMode.append, flush: true);
    _bySha[entry.sha256] = entry;
  }
}
