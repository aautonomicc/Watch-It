import 'app_settings.dart';
import 'network_events.dart';

/// Verdict for starting (or chaining into) streamed playback right now.
enum StreamingGate {
  /// Go ahead.
  allow,

  /// On mobile data with the Ask policy and no consent yet this
  /// session — the caller shows the "stream anyway?" prompt.
  ask,

  /// On mobile data with the Wi-Fi-only policy — blocked.
  block,
}

/// One "yes, use mobile data" answer covers the rest of the session
/// (also lets the Up-next chain keep rolling after the user consented).
class CellularStreamingConsent {
  static bool granted = false;
}

/// The network-policy verdict for streamed playback. Anything but a
/// cellular transport streams freely; the policies only govern mobile
/// data. Downloaded titles play locally and never come through here.
Future<StreamingGate> streamingGateNow({NetworkEvents? network}) async {
  final n = network ?? NetworkEvents.instance;
  if (!n.onCellular) return StreamingGate.allow;
  return switch (await AppSettings.streamingNetworkPolicy()) {
    StreamingNetworkPolicy.allow => StreamingGate.allow,
    StreamingNetworkPolicy.wifiOnly => StreamingGate.block,
    StreamingNetworkPolicy.ask => CellularStreamingConsent.granted
        ? StreamingGate.allow
        : StreamingGate.ask,
  };
}
