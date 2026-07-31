import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// The transport class the OS says we are on. W@tch only distinguishes
/// what its policies need: cellular (metered by assumption) vs everything
/// else, and "no network at all".
enum NetworkTransport { wifi, ethernet, cellular, other, none }

/// App-wide view of the OS-level network transport, fed by
/// connectivity_plus (Android, and Linux via NetworkManager — the two
/// platforms the reconnect/network-policy work targets).
///
/// Two consumers:
///  * reconnect fast-path — any change to a usable transport should kick
///    the embedded client's reconnect supervisor (listen + [hasNetwork]);
///  * network policies (Settings → Network) — downloads/streaming gates
///    read [onCellular].
///
/// Starts as [NetworkTransport.other] (unknown, permissive): on platforms
/// where the plugin is unavailable nothing is ever gated.
class NetworkEvents extends ChangeNotifier {
  NetworkEvents({this._stream, this._check});

  /// Replaceable for tests (fresh instance per test).
  static NetworkEvents instance = NetworkEvents();

  final Stream<List<ConnectivityResult>>? _stream;
  final Future<List<ConnectivityResult>> Function()? _check;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  NetworkTransport _transport = NetworkTransport.other;
  NetworkTransport get transport => _transport;

  /// On mobile data (and not simultaneously on Wi-Fi/ethernet).
  bool get onCellular => _transport == NetworkTransport.cellular;

  /// Some usable transport exists (unknown counts as usable).
  bool get hasNetwork => _transport != NetworkTransport.none;

  /// Begin listening for OS transport changes (call once from main).
  /// Safe everywhere: platforms without a connectivity backend just stay
  /// in the permissive unknown state.
  void start() {
    if (_sub != null) return;
    try {
      final connectivity = Connectivity();
      unawaited((_check ?? connectivity.checkConnectivity)()
          .then(_apply)
          .catchError((_) {}));
      _sub = (_stream ?? connectivity.onConnectivityChanged)
          .listen(_apply, onError: (_) {});
    } catch (_) {
      // No backend (tests, exotic desktops): stay permissive.
    }
  }

  void _apply(List<ConnectivityResult> results) {
    final next = classifyTransports(results);
    if (next == _transport) return;
    _transport = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}

/// Collapse connectivity_plus's result list to one transport. The list
/// can hold several entries (wifi+vpn, ethernet+wifi); the fastest
/// non-metered transport wins, so a phone on Wi-Fi with mobile data on
/// standby counts as Wi-Fi.
NetworkTransport classifyTransports(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.ethernet)) {
    return NetworkTransport.ethernet;
  }
  if (results.contains(ConnectivityResult.wifi)) return NetworkTransport.wifi;
  if (results.contains(ConnectivityResult.mobile)) {
    return NetworkTransport.cellular;
  }
  if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
    return NetworkTransport.none;
  }
  return NetworkTransport.other; // vpn/bluetooth/other: usable, not metered
}
