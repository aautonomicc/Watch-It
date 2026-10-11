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

  /// The resolved server base — for unauthenticated sibling routes like
  /// `GET /datamap/{addr}` (batch uploader's bundle bytes).
  String get base => _base;

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
      kind: json['kind'] as String?,
      keysHeld: json['keys_held'] as bool?,
      locked: json['locked'] as bool? ?? false,
      protected: json['protected'] as bool? ?? false,
    );
  }

  /// Decrypt the passphrase-protected wallet file into memory for this
  /// run (the file stays encrypted on disk). Returns the unlocked status.
  Future<WalletStatus> unlockWallet(String passphrase) async {
    final json = await _request('POST', '/wallet/unlock',
        body: {'passphrase': passphrase});
    return WalletStatus(
      configured: json['configured'] as bool? ?? false,
      address: json['address'] as String?,
      storage: json['storage'] as String?,
      kind: json['kind'] as String?,
      keysHeld: json['keys_held'] as bool?,
      locked: json['locked'] as bool? ?? false,
      protected: json['protected'] as bool? ?? false,
    );
  }

  /// Encrypt the fallback wallet file at rest under [passphrase]
  /// (file-stored software keys only — W@tch asks for the passphrase
  /// after each restart from then on).
  Future<void> setWalletPassphrase(String passphrase) =>
      _request('POST', '/wallet/passphrase', body: {'passphrase': passphrase});

  /// Rewrite the fallback wallet file in the clear (requires the wallet
  /// to be unlocked).
  Future<void> clearWalletPassphrase() =>
      _request('DELETE', '/wallet/passphrase');

  /// Is a device conversation waiting for a HUMAN at the Trezor right
  /// now (a confirmation tap, the address screen)? Polled by
  /// TrezorAttentionService during hardware-wallet flows so the app can
  /// explain each tap the moment the device asks for it.
  Future<TrezorActivity> trezorActivity() async {
    final json = await _request('GET', '/trezor/activity');
    return TrezorActivity(
      active: json['active'] as bool? ?? false,
      seq: json['seq'] as int? ?? 0,
      action: json['action'] as String?,
    );
  }

  /// Is a Trezor answering on USB? Silent on the device.
  Future<TrezorProbe> trezorProbe() async {
    final json = await _request('GET', '/wallet/trezor');
    return TrezorProbe(
      found: json['found'] as bool? ?? false,
      address: json['address'] as String?,
      error: json['error'] as String?,
    );
  }

  /// Run the hardware-wallet setup ceremony: the device signs the frozen
  /// backup-identity message twice (two confirmations on the Trezor,
  /// nothing spent) and the wallet becomes this install's payment +
  /// backup identity. [shareKeys] keeps the backup READ key on this
  /// computer (the default) so linked devices can follow backups without
  /// the device. Blocks until the user confirms or cancels on the Trezor.
  Future<WalletStatus> trezorSetup({bool shareKeys = true}) async {
    final json = await _request('POST', '/wallet/trezor',
        body: {'share_keys': shareKeys});
    return WalletStatus(
      configured: true,
      address: json['address'] as String?,
      storage: json['storage'] as String?,
      kind: 'trezor',
      keysHeld: json['keys_held'] as bool?,
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

  /// Start the pooled batch upload — EVERY file in one paid batch, one
  /// merkle payment transaction per ≤256-chunk sub-batch instead of one+
  /// per file (the upload-all flow). Returns the job id to poll with
  /// [batchStatus].
  Future<int> startBatchUpload(List<({String path, String name})> files) async {
    final json = await _request('POST', '/upload/batch', body: {
      'files': [
        for (final f in files) {'path': f.path, 'name': f.name},
      ],
    });
    return json['id'] as int;
  }

  Future<BatchUploadJob> batchStatus(int id) async {
    final json = await _request('GET', '/upload/batch/$id');
    return BatchUploadJob(
      id: id,
      phase: json['phase'] as String? ?? 'unknown',
      done: json['done'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
      paymentsDone: json['payments_done'] as int? ?? 0,
      paymentsTotal: json['payments_total'] as int? ?? 0,
      error: json['error'] as String?,
      costAtto: BigInt.tryParse(json['cost_atto'] as String? ?? '') ??
          BigInt.zero,
      files: [
        for (final f in (json['files'] as List? ?? const []))
          BatchUploadFile(
            name: (f as Map<String, dynamic>)['name'] as String? ?? '',
            status: f['status'] as String? ?? 'pending',
            error: f['error'] as String?,
            address: f['address'] as String?,
            size: f['size'] as int? ?? 0,
            chunks: f['chunks'] as int? ?? 0,
          ),
      ],
    );
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
  const WalletStatus({
    required this.configured,
    this.address,
    this.storage,
    this.kind,
    this.keysHeld,
    this.locked = false,
    this.protected = false,
  });
  final bool configured;
  final String? address;

  /// The passphrase-protected wallet file has not been unlocked this run:
  /// only the public address is known until `POST /wallet/unlock`.
  final bool locked;

  /// The fallback wallet file is passphrase-encrypted at rest (whether or
  /// not it is currently unlocked).
  final bool protected;

  /// `keychain` or `file` — `file` means no OS keychain was available and
  /// the key sits in a mode-0600 app file; the UI says so. For a hardware
  /// wallet only the public marker lives there, so the warning is moot.
  final String? storage;

  /// `software` (key on this computer) or `trezor` (key stays in the
  /// device; payments confirm on it). Old cores omit it — software.
  final String? kind;

  /// Hardware wallets only: whether the backup READ key was kept at
  /// setup (the sharing default). Null for software wallets.
  final bool? keysHeld;

  bool get isHardware => kind == 'trezor';
}

/// `GET /wallet/trezor` — is a device answering on USB right now?
/// One snapshot of the core's Trezor attention beacon: whether the
/// device is waiting for a tap, which kind of tap (`sign-identity` |
/// `confirm-address` | `sign-payment`), and a sequence number that grows
/// per action so a poller can tell a new tap from one it has already
/// announced.
class TrezorActivity {
  const TrezorActivity({required this.active, required this.seq, this.action});
  final bool active;
  final int seq;
  final String? action;
}

class TrezorProbe {
  const TrezorProbe({required this.found, this.address, this.error});
  final bool found;
  final String? address;
  final String? error;
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

/// `GET /upload/batch/{id}` — the pooled batch job: phase-scoped
/// progress (encrypting counts files, quoting/storing count chunks),
/// payment transactions done/expected, and per-file outcomes in input
/// order.
class BatchUploadJob {
  const BatchUploadJob({
    required this.id,
    required this.phase,
    required this.done,
    required this.total,
    required this.paymentsDone,
    required this.paymentsTotal,
    required this.costAtto,
    required this.files,
    this.error,
  });
  final int id;
  final String phase;
  final int done;
  final int total;
  final int paymentsDone;
  final int paymentsTotal;
  final BigInt costAtto;
  final List<BatchUploadFile> files;
  final String? error;

  bool get finished => phase == 'done' || phase == 'error';
}

class BatchUploadFile {
  const BatchUploadFile({
    required this.name,
    required this.status,
    required this.size,
    required this.chunks,
    this.error,
    this.address,
  });
  final String name;

  /// pending → uploading → done | failed
  final String status;
  final String? error;
  final String? address;
  final int size;
  final int chunks;
}

class UploadResult {
  const UploadResult({
    required this.address,
    required this.size,
    required this.chunks,
    required this.costAtto,
  });
  final String address;
  final int size;
  final int chunks;
  final BigInt costAtto;
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
