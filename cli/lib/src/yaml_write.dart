/// Minimal YAML emitter for the manifest and sidecar files — the values
/// we write are maps, lists, strings, numbers, bools, and null. Strings
/// that could confuse a YAML parser are quoted; multi-line strings are
/// emitted as JSON-style double-quoted scalars (valid YAML). Output is
/// meant to be hand-edited between `prepare` and `upload`, so plain
/// values stay plain.
library;

import 'dart:convert';

String yamlDocument(Object? value) => '${_emit(value, 0, false)}\n';

final _plain = RegExp(r"^[A-Za-z0-9][A-Za-z0-9 ._/@()\[\]{}#&+',!$%^;=-]*$");
final _looksTyped = RegExp(
    r'^(true|false|null|yes|no|on|off|~|[-+]?[\d.].*)$',
    caseSensitive: false);

String _scalar(Object? v) {
  if (v == null) return 'null';
  if (v is bool || v is num) return '$v';
  final s = v.toString();
  if (s.isEmpty) return "''";
  if (s.contains('\n') || s.contains('\r') || s.contains('\t')) {
    return json.encode(s);
  }
  if (_plain.hasMatch(s) &&
      !_looksTyped.hasMatch(s) &&
      !s.endsWith(' ') &&
      !s.contains(': ') &&
      !s.contains(' #')) {
    return s;
  }
  return "'${s.replaceAll("'", "''")}'";
}

String _emit(Object? value, int indent, bool inline) {
  final pad = '  ' * indent;
  if (value is Map) {
    if (value.isEmpty) return inline ? '{}' : '$pad{}';
    final buf = StringBuffer();
    var first = true;
    for (final e in value.entries) {
      final key = _scalar(e.key);
      final prefix = first && inline ? '' : pad;
      first = false;
      final v = e.value;
      if (v is Map && v.isNotEmpty || v is List && v.isNotEmpty) {
        buf.writeln('$prefix$key:');
        buf.write(_emit(v, indent + 1, false));
      } else {
        buf.writeln('$prefix$key: ${v is Map || v is List ? (v is Map ? '{}' : '[]') : _scalar(v)}');
      }
    }
    return buf.toString();
  }
  if (value is List) {
    if (value.isEmpty) return inline ? '[]' : '$pad[]';
    final buf = StringBuffer();
    for (final item in value) {
      if (item is Map && item.isNotEmpty) {
        buf.write('$pad- ');
        buf.write(_emit(item, indent + 1, true));
      } else if (item is List && item.isNotEmpty) {
        buf.writeln('$pad-');
        buf.write(_emit(item, indent + 1, false));
      } else {
        buf.writeln(
            '$pad- ${item is Map ? '{}' : item is List ? '[]' : _scalar(item)}');
      }
    }
    return buf.toString();
  }
  return '$pad${_scalar(value)}';
}
