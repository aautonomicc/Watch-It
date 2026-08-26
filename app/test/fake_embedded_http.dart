import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// In-zone fake of the embedded client's HTTP API for widget tests.
///
/// Widget tests run in a fake-async zone where real localhost sockets
/// never complete, so the import/export services' HTTP goes through
/// [HttpOverrides] instead: set `HttpOverrides.global = FakeEmbeddedHttp()`
/// in setUp (and null it in tearDown). Covers both `dart:io` HttpClient
/// call sites and `package:http` (whose IOClient opens requests through
/// the same override).
///
/// Routes, mirroring the Rust server:
/// - `POST /datamap`: body starting `0xBA 0xD1` → 400; body starting
///   `0xBA 0xD5` → 503 (a shrunk map that needs the network while not
///   connected); otherwise the "derived address" is the first body byte
///   spread over 64 hex chars, so tests can predict it from the member
///   bytes.
/// - `GET /datamap/<addr>`: serves [datamaps], else 404.
/// - `GET /xor/<addr>`: serves [xorContent], else 404.
/// - `PUT /rootmap/<addr>`: body `[6, 6, 6]` → 422 (tampered), else 204;
///   bodies recorded in [rootmapPuts].
class FakeEmbeddedHttp extends HttpOverrides {
  final Map<String, List<int>> datamaps = {};
  final Map<String, List<int>> xorContent = {};
  final Set<String> storedRootmaps = {};
  final Map<String, List<int>> rootmapPuts = {};
  final List<String> requests = [];

  /// Wallet state for the `/wallet` routes: null = not configured.
  /// `POST /wallet` "derives" an address by hashing the body so tests can
  /// assert generate→import consistency without real key math.
  Map<String, dynamic>? wallet;

  /// My W@tch state `GET /mywatch` plays back; link/join/unlink mutate it
  /// the way the Rust core would. Tests override it for the linked views.
  Map<String, dynamic> myWatchStatus = {
    'supported': true,
    'linked': false,
    'state': 'off',
    'devices': const [],
  };

  /// Invite `POST /mywatch/link` and `GET /mywatch/invite` hand out.
  String myWatchInvite = 'wtch1-${'cd' * 32}';

  /// Raw bodies of every `POST /mywatch/announce`.
  final List<String> myWatchAnnounces = [];

  /// Mnemonic that `POST /wallet/generate` hands out.
  String generatedMnemonic =
      'test test test test test test test test test test test junk';

  /// Balances `GET /wallet/balances` reports (raw 18-decimal strings).
  String antAtto = '1500000000000000000';
  String ethWei = '20000000000000000';

  /// Responses `GET /upload/<id>` plays back, in order (the last one
  /// repeats). Empty → the job reports done immediately with its result.
  /// Replayed from the start for every new `POST /upload`.
  final List<Map<String, dynamic>> uploadStates = [];
  int _uploadPolls = 0;
  int _uploadsStarted = 0;
  Map<String, dynamic> uploadResult = {
    'address': 'ab' * 32,
    'size': 5,
    'chunks': 1,
    'cost_atto': '250000000000000000',
    'gas_wei': '1000000000000',
  };

  /// Per-upload results by start order (batch tests); falls back to
  /// [uploadResult] when the list is shorter than the job id.
  List<Map<String, dynamic>> uploadResults = [];

  /// Non-null → `POST /upload/estimate` fails with (status, message).
  (int, String)? estimateFailure;

  /// The `size` every `POST /datamap` reports — tests override it to
  /// exercise size limits.
  int datamapSize = 100;

  /// Any base URL works — routing only looks at the path.
  static const String base = 'http://127.0.0.1:9';

  static String addrForByte(int byte) =>
      byte.toRadixString(16).padLeft(2, '0') * 32;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(_handle);

  (int, List<int>) _handle(String method, Uri url, List<int> body) {
    final path = url.path;
    requests.add('$method $path');
    if (method == 'POST' && path == '/datamap') {
      if (body.length >= 2 && body[0] == 0xBA && body[1] == 0xD1) {
        return (400, utf8.encode('not a data map'));
      }
      if (body.length >= 2 && body[0] == 0xBA && body[1] == 0xD5) {
        return (
          503,
          utf8.encode('not connected to the network — this shrunk data '
              'map needs the network to expand')
        );
      }
      return (
        200,
        utf8.encode(jsonEncode({
          'address': addrForByte(body.isEmpty ? 0 : body.first),
          'size': datamapSize,
          'chunks': 1,
        }))
      );
    }
    if (path == '/wallet' || path.startsWith('/wallet/')) {
      return _handleWallet(method, path, body);
    }
    if (path == '/mywatch' || path.startsWith('/mywatch/')) {
      return _handleMyWatch(method, path, body);
    }
    if (method == 'POST' && path == '/upload/estimate') {
      final fail = estimateFailure;
      if (fail != null) return (fail.$1, utf8.encode(fail.$2));
      return (
        200,
        utf8.encode(jsonEncode({
          'file_size': 5,
          'chunk_count': 3,
          'storage_cost_atto': '250000000000000000',
          'estimated_gas_cost_wei': '1000000000000',
          'confidence': 'PricedSample',
        }))
      );
    }
    if (method == 'POST' && path == '/upload') {
      if (wallet == null) {
        return (
          400,
          utf8.encode('no upload wallet configured — set one up in '
              'Settings → Wallet')
        );
      }
      _uploadPolls = 0;
      _uploadsStarted++;
      return (200, utf8.encode(jsonEncode({'id': _uploadsStarted})));
    }
    if (method == 'GET' && path.startsWith('/upload/')) {
      final id = int.parse(path.substring('/upload/'.length));
      final result =
          id <= uploadResults.length ? uploadResults[id - 1] : uploadResult;
      final state = uploadStates.isEmpty
          ? {
              'phase': 'done',
              'done': 1,
              'total': 1,
              'error': null,
              'result': result,
            }
          : uploadStates[
              _uploadPolls.clamp(0, uploadStates.length - 1)];
      _uploadPolls++;
      return (
        200,
        utf8.encode(jsonEncode({
          'id': id,
          'name': 'upload',
          'done': 0,
          'total': 0,
          ...state,
        }))
      );
    }
    if (method == 'GET' && path.startsWith('/datamap/')) {
      final map = datamaps[path.substring('/datamap/'.length)];
      return map == null ? (404, const <int>[]) : (200, map);
    }
    if (method == 'GET' && path.startsWith('/xor/')) {
      final content = xorContent[path.substring('/xor/'.length)];
      return content == null ? (404, const <int>[]) : (200, content);
    }
    if (method == 'GET' && path.startsWith('/rootmap/')) {
      final addr = path.substring('/rootmap/'.length);
      return storedRootmaps.contains(addr) || rootmapPuts.containsKey(addr)
          ? (200, const <int>[1])
          : (404, const <int>[]);
    }
    if (method == 'PUT' && path.startsWith('/rootmap/')) {
      if (body.length == 3 && body.every((b) => b == 6)) {
        return (422, const <int>[]);
      }
      rootmapPuts[path.substring('/rootmap/'.length)] = body;
      return (204, const <int>[]);
    }
    return (404, const <int>[]);
  }

  (int, List<int>) _handleMyWatch(String method, String path, List<int> body) {
    if (method == 'GET' && path == '/mywatch') {
      return (200, utf8.encode(jsonEncode(myWatchStatus)));
    }
    if (method == 'POST' && path == '/mywatch/link') {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final name = (json['device_name'] as String? ?? '').trim();
      if (name.isEmpty) return (400, utf8.encode('device name is required'));
      if (myWatchStatus['linked'] == true) {
        return (400, utf8.encode('this device is already linked — unlink first'));
      }
      myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'device_name': name,
        'agent_id': 'aa' * 32,
        'last_sync_ms': 0,
        'devices': const [],
      };
      return (200, utf8.encode(jsonEncode({'invite': myWatchInvite})));
    }
    if (method == 'POST' && path == '/mywatch/join') {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final name = (json['device_name'] as String? ?? '').trim();
      final invite = (json['invite'] as String? ?? '').trim();
      if (name.isEmpty) return (400, utf8.encode('device name is required'));
      if (!invite.startsWith('wtch1-')) {
        return (400, utf8.encode('not a My W@tch invite code'));
      }
      myWatchStatus = {
        'supported': true,
        'linked': true,
        'state': 'ready',
        'device_name': name,
        'agent_id': 'bb' * 32,
        'last_sync_ms': 0,
        'devices': const [],
      };
      return (200, utf8.encode(jsonEncode({'joined': true})));
    }
    if (method == 'GET' && path == '/mywatch/invite') {
      if (myWatchStatus['linked'] != true) {
        return (400, utf8.encode('this device is not linked'));
      }
      return (200, utf8.encode(jsonEncode({'invite': myWatchInvite})));
    }
    if (method == 'POST' && path == '/mywatch/announce') {
      myWatchAnnounces.add(utf8.decode(body));
      return (200, utf8.encode(jsonEncode({'announced': true})));
    }
    if (method == 'DELETE' && path == '/mywatch') {
      myWatchStatus = {
        'supported': true,
        'linked': false,
        'state': 'off',
        'devices': const [],
      };
      return (200, utf8.encode(jsonEncode({'unlinked': true})));
    }
    return (404, const <int>[]);
  }

  (int, List<int>) _handleWallet(String method, String path, List<int> body) {
    if (method == 'GET' && path == '/wallet') {
      final w = wallet;
      return (
        200,
        utf8.encode(jsonEncode(w == null
            ? {'configured': false}
            : {'configured': true, ...w}))
      );
    }
    if (method == 'POST' && path == '/wallet/generate') {
      return (
        200,
        utf8.encode(jsonEncode({
          'mnemonic': generatedMnemonic,
          'address': _addressFor(generatedMnemonic),
        }))
      );
    }
    if (method == 'POST' && path == '/wallet') {
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      final secret =
          (json['mnemonic'] ?? json['private_key']) as String?;
      if (secret == null || secret.trim().isEmpty) {
        return (400, utf8.encode('body must have a key or mnemonic'));
      }
      if (json.containsKey('private_key') &&
          !RegExp(r'^(0x)?[0-9a-fA-F]{64}$').hasMatch(secret.trim())) {
        return (
          400,
          utf8.encode('not a valid private key (expect 64 hex characters)')
        );
      }
      wallet = {'address': _addressFor(secret), 'storage': 'keychain'};
      return (200, utf8.encode(jsonEncode(wallet)));
    }
    if (method == 'DELETE' && path == '/wallet') {
      wallet = null;
      return (204, const <int>[]);
    }
    if (method == 'GET' && path == '/wallet/balances') {
      if (wallet == null) {
        return (404, utf8.encode('no wallet configured'));
      }
      return (
        200,
        utf8.encode(jsonEncode({'ant_atto': antAtto, 'eth_wei': ethWei}))
      );
    }
    return (404, const <int>[]);
  }

  /// Deterministic pretend address: 0x + first 40 hex chars of the
  /// secret's code units, so the same input always maps to the same
  /// address (generate → import round trips agree).
  static String _addressFor(String secret) {
    final hex = StringBuffer();
    for (final unit in secret.trim().codeUnits) {
      hex.write((unit & 0xff).toRadixString(16).padLeft(2, '0'));
      if (hex.length >= 40) break;
    }
    return '0x${hex.toString().padRight(40, '0').substring(0, 40)}';
  }
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.handler);
  final (int, List<int>) Function(String, Uri, List<int>) handler;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(method, url, handler);

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  void close({bool force = false}) {}

  // package:http's IOClient only opens requests and closes the client;
  // anything else reaching here is a test bug worth a loud failure.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClient.${invocation.memberName}');
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.method, this.uri, this.handler);

  @override
  final String method;
  @override
  final Uri uri;
  final (int, List<int>) Function(String, Uri, List<int>) handler;
  final List<int> _body = [];

  @override
  final HttpHeaders headers = _FakeHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  bool bufferOutput = true;

  @override
  void add(List<int> data) => _body.addAll(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach(_body.addAll);

  @override
  Future<HttpClientResponse> close() async {
    final (status, body) = handler(method, uri, _body);
    return _FakeResponse(status, body);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClientRequest.${invocation.memberName}');
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this._body);

  @override
  final int statusCode;
  final List<int> _body;

  @override
  int get contentLength => _body.length;
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => '';
  @override
  final HttpHeaders headers = _FakeHeaders();
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  List<RedirectInfo> get redirects => const [];

  @override
  X509Certificate? get certificate => null;

  @override
  List<Cookie> get cookies => const [];

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([_body]).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpClientResponse.${invocation.memberName}');
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = ['$value'];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(name.toLowerCase(), () => []).add('$value');
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  String? value(String name) => _values[name.toLowerCase()]?.join(', ');

  @override
  ContentType? contentType;

  @override
  int contentLength = -1;

  @override
  bool chunkedTransferEncoding = false;

  @override
  void removeAll(String name) => _values.remove(name.toLowerCase());

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('HttpHeaders.${invocation.memberName}');
}
