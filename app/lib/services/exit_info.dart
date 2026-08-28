import 'dart:io';

import 'package:flutter/services.dart';

/// One prior death of this app's process, as recorded by Android
/// (`ActivityManager.getHistoricalProcessExitReasons` via the
/// `watchit/exitinfo` channel). The record survives the death itself,
/// so a device with no adb access can report its own last crash from
/// inside the app — Settings → About → "Why did the app close?".
class ExitRecord {
  const ExitRecord({
    required this.timestampMs,
    required this.reason,
    required this.reasonName,
    required this.status,
    required this.description,
    required this.trace,
  });

  factory ExitRecord.fromMap(Map<Object?, Object?> map) => ExitRecord(
        timestampMs: (map['timestampMs'] as num?)?.toInt() ?? 0,
        reason: (map['reason'] as num?)?.toInt() ?? -1,
        reasonName: map['reasonName'] as String? ?? 'unknown',
        status: (map['status'] as num?)?.toInt() ?? 0,
        description: map['description'] as String? ?? '',
        trace: map['trace'] as String? ?? '',
      );

  /// Wall-clock of the death, from the OS record.
  final int timestampMs;

  /// `ApplicationExitInfo.REASON_*` value.
  final int reason;

  /// Human name for [reason], mapped on the platform side.
  final String reasonName;

  /// Exit status — for signaled deaths this is the signal number.
  final int status;

  /// The OS's free-text note (e.g. the `am_kill` reason).
  final String description;

  /// Tombstone head for native crashes / ANR dump head; empty otherwise.
  final String trace;

  /// True for deaths the user did not ask for — the ones worth reporting.
  bool get isAbnormal =>
      reasonName != 'exit-self' &&
      reasonName != 'user-requested' &&
      reasonName != 'user-stopped';

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(timestampMs).toLocal();

  /// One record as report text, ready to copy into a bug report.
  String get reportText {
    final b = StringBuffer()
      ..writeln('when: $time')
      ..writeln('reason: $reasonName (code $reason, status $status)');
    if (description.isNotEmpty) b.writeln('description: $description');
    if (trace.isNotEmpty) {
      b
        ..writeln('trace:')
        ..writeln(trace);
    }
    return b.toString();
  }
}

/// Fetches the OS's record of previous app exits. Android-only — the
/// tile is hidden elsewhere and [fetch] answers an empty list.
class ExitInfoService {
  ExitInfoService({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel('watchit/exitinfo'),
        _isAndroid = isAndroid ?? Platform.isAndroid;

  /// Replaceable for tests.
  static ExitInfoService instance = ExitInfoService();

  final MethodChannel _channel;
  final bool _isAndroid;

  bool get supported => _isAndroid;

  Future<List<ExitRecord>> fetch() async {
    if (!_isAndroid) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>('getExitReasons');
      return [
        for (final entry in raw ?? const <Object?>[])
          if (entry is Map) ExitRecord.fromMap(entry.cast<Object?, Object?>()),
      ];
    } catch (_) {
      // Older platform build without the channel, or the OS refused —
      // diagnostics must never break Settings.
      return const [];
    }
  }
}
