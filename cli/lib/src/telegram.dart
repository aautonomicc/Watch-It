import 'dart:io';

import 'package:http/http.dart' as http;

/// Completion/failure ping over the existing Telegram bot credentials
/// (`~/telegram-bot/.env`: TELEGRAM_BOT_TOKEN + TELEGRAM_USER_ID).
/// Fail-soft everywhere — a missing .env or network hiccup never touches
/// the upload run's outcome.
Future<bool> telegramPing(String message, {String? envPath}) async {
  envPath ??=
      '${Platform.environment['HOME'] ?? ''}/telegram-bot/.env';
  final file = File(envPath);
  if (!file.existsSync()) return false;
  String? token, chatId;
  for (final line in file.readAsLinesSync()) {
    final m = RegExp(r'^\s*(?:export\s+)?([A-Z_]+)\s*=\s*"?([^"#]*)"?\s*$')
        .firstMatch(line);
    if (m == null) continue;
    if (m.group(1) == 'TELEGRAM_BOT_TOKEN') token = m.group(2)!.trim();
    if (m.group(1) == 'TELEGRAM_USER_ID') chatId = m.group(2)!.trim();
  }
  if (token == null || token.isEmpty || chatId == null || chatId.isEmpty) {
    return false;
  }
  try {
    final res = await http.post(
      Uri.parse('https://api.telegram.org/bot$token/sendMessage'),
      body: {'chat_id': chatId, 'text': message},
    ).timeout(const Duration(seconds: 20));
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}
