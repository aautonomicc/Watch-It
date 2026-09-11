import 'dart:async';
import 'package:flutter/material.dart';
import '../services/tv_settings.dart';

class TvDisplayScreen extends StatelessWidget {
  const TvDisplayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tv = TvSettings.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('TV display')),
      body: ListenableBuilder(
        listenable: tv,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Keep every control in view',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            const Text(
              'Increase the margins if your TV cuts off the edges. '
              'The change applies to every screen, including dialogs and playback.',
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                OutlinedButton.icon(
                  autofocus: true,
                  onPressed: tv.marginPercent > 0
                      ? () => unawaited(tv.setMargin(tv.marginPercent - 1))
                      : null,
                  icon: const Icon(Icons.remove),
                  label: const Text('Less margin'),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '${tv.marginPercent}%',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: tv.marginPercent < 10
                      ? () => unawaited(tv.setMargin(tv.marginPercent + 1))
                      : null,
                  icon: const Icon(Icons.add),
                  label: const Text('More margin'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => unawaited(tv.setMargin(5)),
              child: const Text('Reset margins to 5%'),
            ),
            const Divider(height: 48),
            SwitchListTile(
              title: const Text('Grove palette'),
              subtitle: const Text(
                'Soft green surfaces with W@tch blue. Applies in dark mode.',
              ),
              value: tv.grove,
              onChanged: (value) => unawaited(tv.setGrove(value)),
            ),
            const SizedBox(height: 24),
            const Text(
              'Use the directional pad to move the bright focus outline. '
              'Press the centre button to select. Back returns to the previous screen.',
            ),
          ],
        ),
      ),
    );
  }
}
