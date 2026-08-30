import 'dart:convert';

import 'package:http/http.dart' as http;

import 'embedded_client.dart';

/// Client for the embedded server's wallet + Publish upload endpoints.
///
/// These routes are guarded by the FFI-provided auth token (they spend
/// real ANT or manage the wallet key), so every call sends
/// `x-watchit-auth`. Errors surface as [PublishApiException] carrying the
/// server's plain-text explanation, which is written for end users.
class PublishApi {
  PublishApi({String? base, String? token})
      : _baseOverride = base,
        _tokenOverride = token;

  final String? _baseOverride;
  final String? _tokenOverride;

  String get _base {
    final base = _baseOverride ?? EmbeddedClient.baseUrl();
    if (base == null) {
      throw PublishApiException('the embedded client is not running');
    }
    return base.replaceFirst(RegExp(r'/+$'), '');
  }

  Map<String, String> get _headers {
    final token = _tokenOverride ?? EmbeddedClient.authToken();
    return {
      'content-type': 'application/json',
      'x-watchit-auth': ?token,
    };
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    Set<int> okStatuses = const {200},
  }) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('$_base$path');
      final http.Response res = switch (method) {
        'GET' => await client.get(uri, headers: _headers),
        'POST' => await client.post(uri,
            headers: _headers, body: body == null ? null : jsonEncode(body)),
        'DELETE' => await client.delete(uri, headers: _headers),
        _ => throw ArgumentError(method),
      };
      if (!okStatuses.contains(res.statusCode) && res.statusCode != 204) {
        throw PublishApiException(
            res.body.trim().isEmpty ? 'request failed (${res.statusCode})' : res.body.trim());
      }
      if (res.statusCode == 204 || res.body.isEmpty) return const {};
      return jsonDecode(res.body) as Map<String, dynamic>;
    } on PublishApiException {
      rethrow;
    } catch (e) {
      throw PublishApiException('could not reach the embedded client: $e');
    } finally {
      client.close();
    }
  }

  Future<WalletStatus> walletStatus() async {
    final json = await _request('GET', '/wallet');
    return WalletStatus(
      configured: json['configured'] as bool? ?? false,
      address: json['address'] as String?,
      storage: json['storage'] as String?,
    );
  }

  /// A fresh 12-word mnemonic + its address. Nothing is stored until the
  /// phrase is imported after the backup ceremony.
  Future<GeneratedWallet> generateWallet() async {
    final json = await _request('POST', '/wallet/generate');
    return GeneratedWallet(
      mnemonic: json['mnemonic'] as String,
      address: json['address'] as String,
    );
  }

  /// Import a wallet by seed phrase or raw private key; returns the
  /// resulting [WalletStatus].
  Future<WalletStatus> importWallet({String? mnemonic, String? privateKey}) async {
    final json = await _request('POST', '/wallet', body: {
      'mnemonic': ?mnemonic,
      'private_key': ?privateKey,
    });
    return WalletStatus(
      configured: true,
      address: json['address'] as String?,
      storage: json['storage'] as String?,
    );
  }

  Future<void> removeWallet() => _request('DELETE', '/wallet');

  Future<WalletBalances> balances() async {
    final json = await _request('GET', '/wallet/balances');
    return WalletBalances(
      antAtto: BigInt.parse(json['ant_atto'] as String),
      ethWei: BigInt.parse(json['eth_wei'] as String),
    );
  }

  Future<UploadEstimate> estimate(String path) async {
    final json = await _request('POST', '/upload/estimate', body: {'path': path});
    return UploadEstimate(
      fileSize: json['file_size'] as int? ?? 0,
      chunkCount: json['chunk_count'] as int? ?? 0,
      costAtto: BigInt.parse(json['storage_cost_atto'] as String),
      gasWei: BigInt.parse(json['estimated_gas_cost_wei'] as String),
      confidence: json['confidence'] as String? ?? '',
    );
  }

  /// Start the upload; returns the job id to poll with [jobStatus].
  Future<int> startUpload(String path, {String? name}) async {
    final json = await _request('POST', '/upload', body: {
      'path': path,
      'name': ?name,
    });
    return json['id'] as int;
  }

  Future<UploadJob> jobStatus(int id) async {
    final json = await _request('GET', '/upload/$id');
    final result = json['result'] as Map<String, dynamic>?;
    return UploadJob(
      id: id,
      phase: json['phase'] as String? ?? 'unknown',
      done: json['done'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
      error: json['error'] as String?,
      result: result == null
          ? null
          : UploadResult(
              address: result['address'] as String,
              size: result['size'] as int? ?? 0,
              chunks: result['chunks'] as int? ?? 0,
              costAtto: BigInt.parse(result['cost_atto'] as String),
              seq: result['seq'] as int?,
              announced: result['announced'] as bool? ?? true,
            ),
    );
  }
}

class PublishApiException implements Exception {
  PublishApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WalletStatus {
  const WalletStatus({required this.configured, this.address, this.storage});
  final bool configured;
  final String? address;

  /// `keychain` or `file` — `file` means no OS keychain was available and
  /// the key sits in a mode-0600 app file; the UI says so.
  final String? storage;
}

class GeneratedWallet {
  const GeneratedWallet({required this.mnemonic, required this.address});
  final String mnemonic;
  final String address;
}

class WalletBalances {
  const WalletBalances({required this.antAtto, required this.ethWei});
  final BigInt antAtto;
  final BigInt ethWei;
}

class UploadEstimate {
  const UploadEstimate({
    required this.fileSize,
    required this.chunkCount,
    required this.costAtto,
    required this.gasWei,
    required this.confidence,
  });
  final int fileSize;
  final int chunkCount;
  final BigInt costAtto;
  final BigInt gasWei;
  final String confidence;

  /// Every sampled chunk is already on the network — storing is free.
  bool get alreadyStored => confidence.contains('AlreadyStored');
}

class UploadJob {
  const UploadJob({
    required this.id,
    required this.phase,
    required this.done,
    required this.total,
    this.error,
    this.result,
  });
  final int id;
  final String phase;
  final int done;
  final int total;
  final String? error;
  final UploadResult? result;

  bool get finished => phase == 'done' || phase == 'error';
}

class UploadResult {
  const UploadResult({
    required this.address,
    required this.size,
    required this.chunks,
    required this.costAtto,
    this.seq,
    this.announced = true,
  });
  final String address;
  final int size;
  final int chunks;
  final BigInt costAtto;

  /// Channel-publish jobs only: the head sequence number announced for
  /// this manifest.
  final int? seq;

  /// Channel-publish jobs only: false when the signed head is saved but
  /// not gossiped yet (the channels switch was off) — it goes out
  /// automatically when the switch is back on. Absent (old cores) reads
  /// true.
  final bool announced;
}

/// Format a raw 18-decimal base-unit amount (ANT atto / ETH wei) as a
/// human number, e.g. `1500000000000000000` → `1.5`. Keeps at most [dp]
/// decimal places, trimming trailing zeros; tiny non-zero amounts render
/// as `<0.000001` rather than a misleading `0`.
String formatUnits(BigInt raw, {int dp = 6}) {
  final base = BigInt.from(10).pow(18);
  final whole = raw ~/ base;
  final frac = raw % base;
  if (frac == BigInt.zero) return '$whole';
  var fracText = frac.toString().padLeft(18, '0').substring(0, dp);
  fracText = fracText.replaceFirst(RegExp(r'0+$'), '');
  if (fracText.isEmpty) {
    if (whole == BigInt.zero) return '<0.${'0' * (dp - 1)}1';
    return '$whole';
  }
  return '$whole.$fracText';
}
