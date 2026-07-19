import 'package:flutter/material.dart';

import 'theme/tokens.dart';

void main() {
  runApp(const WatchItApp());
}

class WatchItApp extends StatelessWidget {
  const WatchItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'watch-it',
      debugShowCheckedModeBanner: false,
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(
          'watch-it',
          style: TextStyle(
            fontFamily: wiMonoFamily,
            fontFamilyFallback: wiMonoFallback,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: t.bone,
          ),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_circle_outline, size: 64, color: t.copper),
            const SizedBox(height: 16),
            Text(
              'Your library is empty',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: t.bone,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'etch it. fetch it. watch it.',
              style: TextStyle(fontSize: 12, color: t.ash),
            ),
          ],
        ),
      ),
    );
  }
}
