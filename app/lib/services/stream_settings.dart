import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_list.dart';

/// Gateway used to stream Autonomi content over HTTP (an AntTP instance).
/// Configurable in Settings; the default points at the dev gateway on ella.
/// Phase 0 stand-in until the embedded ant-core fetch spike lands.
class StreamSettings {
  // LAN address of the AntTP service on ella; reaching it from outside the
  // home network needs a router port-forward and the public IP here instead.
  static const _key = 'gateway_url_v1';
  static const defaultGateway = 'http://192.168.20.2:18888';

  static Future<String> gatewayUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) ?? defaultGateway;
  }

  static Future<void> setGatewayUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, url.trim());
  }
}

/// HTTP URL that streams [entry] through [gateway], or null when no
/// gateway is configured.
String? streamUrl(String gateway, MediaEntry entry) {
  final base = gateway.trim().replaceFirst(RegExp(r'/+$'), '');
  if (base.isEmpty) return null;
  final addr = entry.address.toLowerCase().replaceFirst('0x', '');
  return '$base/$addr';
}
