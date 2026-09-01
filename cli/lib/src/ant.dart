import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Wrapper around the `ant` CLI (WithAutonomi/ant-client). Uploads are
/// PRIVATE (the default — the datamap stays local, exactly what the
/// .watch-list bundle format carries). The wallet is ant's own: it reads
/// the `SECRET_KEY` environment variable.
class AntCost {
  AntCost({
    required this.fileSize,
    required this.chunkCount,
    required this.storageCostAtto,
    this.gasCostWei,
  });

  final int fileSize;
  final int chunkCount;
  final BigInt storageCostAtto;
  final BigInt? gasCostWei;

  double get storageCostAnt => storageCostAtto / BigInt.from(10).pow(18);
}

/// Parse `ant file cost --json` output (observed shape, ant 0.3.2):
/// `{"file_size":…,"chunk_count":…,"storage_cost_atto":"…",
///   "estimated_gas_cost_wei":"…","payment_mode":"…"}`.
AntCost? parseAntCostJson(String out) {
  try {
    final line = out
        .split('\n')
        .lastWhere((l) => l.trim().startsWith('{'), orElse: () => '');
    final doc = jsonDecode(line) as Map<String, dynamic>;
    return AntCost(
      fileSize: (doc['file_size'] as num).toInt(),
      chunkCount: (doc['chunk_count'] as num).toInt(),
      storageCostAtto: BigInt.parse('${doc['storage_cost_atto']}'),
      gasCostWei: doc['estimated_gas_cost_wei'] != null
          ? BigInt.tryParse('${doc['estimated_gas_cost_wei']}')
          : null,
    );
  } catch (_) {
    return null;
  }
}

class AntUploadResult {
  AntUploadResult({required this.datamapPath, this.address, this.rawJson});

  /// The `.datamap` file ant wrote (named after the uploaded file).
  final String datamapPath;

  /// Address if ant's JSON reported one (private uploads may not).
  final String? address;
  final Map<String, dynamic>? rawJson;
}

class AntException implements Exception {
  AntException(this.message);
  final String message;
  @override
  String toString() => 'AntException: $message';
}

class Ant {
  /// Chunk maths for scaling one live quote across a batch: 4 MiB chunks
  /// with a 3-chunk floor (self-encryption minimum).
  static int chunksFor(int sizeBytes) {
    final n = (sizeBytes + (4 << 20) - 1) ~/ (4 << 20);
    return n < 3 ? 3 : n;
  }

  Future<AntCost?> cost(String path) async {
    final r = await Process.run('ant', ['file', 'cost', '--json', path]);
    if (r.exitCode != 0) return null;
    return parseAntCostJson(r.stdout as String);
  }

  /// `ant wallet balance --json`; null when SECRET_KEY is unset or the
  /// call fails. Shape is version-dependent — returned raw.
  Future<Map<String, dynamic>?> walletBalance() async {
    try {
      final r = await Process.run('ant', ['wallet', 'balance', '--json']);
      if (r.exitCode != 0) return null;
      final line = (r.stdout as String)
          .split('\n')
          .lastWhere((l) => l.trim().startsWith('{'), orElse: () => '');
      if (line.isEmpty) return null;
      return jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  bool get walletConfigured =>
      (Platform.environment['SECRET_KEY'] ?? '').isNotEmpty;

  /// Upload [stagedPath] (already carrying the final W@tch name) from its
  /// own directory, so the datamap lands beside it predictably. Streams
  /// ant's human output through to the console via [onLine].
  Future<AntUploadResult> upload(String stagedPath,
      {void Function(String line)? onLine}) async {
    final dir = p.dirname(stagedPath);
    final base = p.basename(stagedPath);
    final process = await Process.start(
        'ant', ['file', 'upload', '--json', '--overwrite', base],
        workingDirectory: dir);
    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    // forEach futures created BEFORE awaiting exit — a subscription's
    // asFuture() after the stream already closed never completes, and a
    // dropped future lets the whole VM exit silently mid-run.
    final outDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((l) {
      stdoutBuf.writeln(l);
      onLine?.call(l);
    });
    final errDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((l) {
      stderrBuf.writeln(l);
      onLine?.call(l);
    });
    final code = await process.exitCode;
    await outDone;
    await errDone;
    if (code != 0) {
      final tail = (stderrBuf.isNotEmpty ? stderrBuf : stdoutBuf)
          .toString()
          .trim()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      throw AntException(tail.isEmpty
          ? 'ant file upload exited $code'
          : tail.sublist(tail.length > 4 ? tail.length - 4 : 0).join(' | '));
    }
    Map<String, dynamic>? doc;
    String? address;
    for (final line in stdoutBuf.toString().split('\n').reversed) {
      if (!line.trim().startsWith('{')) continue;
      try {
        doc = jsonDecode(line) as Map<String, dynamic>;
        for (final key in ['address', 'data_map_address', 'datamap_address',
            'xor_address', 'file_address']) {
          final v = doc[key];
          if (v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v)) {
            address = v;
          }
        }
        break;
      } catch (_) {}
    }
    // ant names the map `<file>.datamap` beside the CWD; --overwrite keeps
    // the name stable. Prefer a JSON-reported path when present.
    var datamap = doc?['datamap_path']?.toString() ??
        doc?['datamap']?.toString() ??
        p.join(dir, '$base.datamap');
    if (!File(datamap).existsSync()) {
      // Fall back to any fresh candidate next to the staged file.
      final alt = p.join(dir, '$base.datamap');
      if (File(alt).existsSync()) {
        datamap = alt;
      } else {
        throw AntException(
            'upload reported success but no datamap file found at $datamap');
      }
    }
    return AntUploadResult(
        datamapPath: datamap, address: address, rawJson: doc);
  }
}
