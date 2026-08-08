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
