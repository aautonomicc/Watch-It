import 'package:flutter/material.dart';

import '../services/network_pause.dart';
import '../theme/tokens.dart';
import 'mobile_data_screen.dart';

/// Choices for Data saving → Auto-pause when idle (minutes of idle time
/// before [NetworkPause] pauses the network; 0 = off).
const kAutoPauseOptionsMinutes = [0, 10, 20, 30, 60];

/// Human label for an auto-pause threshold: `30 minutes`, `1 hour`.
String idleMinutesLabel(int minutes) =>
    minutes >= 60 ? '1 hour' : '$minutes minutes';

/// Settings → Network → Data saving: the rules that limit when and how
/// the app uses the network — auto-pause when idle and the mobile-data
/// policies — grouped on one page (2026-09-05 Network-section reorg;
/// the always-manual Offline mode switch stays at the section's top).
class DataSavingScreen extends StatelessWidget {
  const DataSavingScreen({super.key});

  Future<void> _pickAutoPause(BuildContext context) async {
    final t = WiTokens.of(context);
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Auto-pause when idle',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<int>(
            groupValue: NetworkPause.instance.idleMinutes,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mins in kAutoPauseOptionsMinutes)
                  RadioListTile<int>(
                    value: mins,
                    activeColor: t.accent,
                    title: Text(
                      mins <= 0
                          ? 'Off'
                          : 'After ${idleMinutesLabel(mins)}'
                              '${mins == 30 ? '  ·  default' : ''}',
                      style: TextStyle(color: t.bone, fontSize: 14),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await NetworkPause.instance.setIdleMinutes(picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Data saving',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'Rules that keep the app quiet when you are not using it. '
              'They act on their own — to stop all network activity '
              'right now, use Offline mode in Settings → Network.',
              style: TextStyle(fontSize: 12.5, color: t.boneDim),
            ),
          ),
          ListenableBuilder(
            listenable: NetworkPause.instance,
            builder: (context, _) => ListTile(
              leading: Icon(Icons.timer_outlined, color: t.accent),
              title: Text('Auto-pause when idle',
                  style: TextStyle(color: t.bone, fontSize: 15)),
              subtitle: Text(
                NetworkPause.instance.idleMinutes <= 0
                    ? 'Off — stays connected while the app is open'
                    : 'After ${idleMinutesLabel(NetworkPause.instance.idleMinutes)} '
                        'with nothing playing, downloading or '
                        'uploading. Playing something resumes '
                        'automatically.',
                style: TextStyle(color: t.ash, fontSize: 12),
              ),
              trailing: Icon(Icons.chevron_right, color: t.ash),
              onTap: () => _pickAutoPause(context),
            ),
          ),
          // One door for everything mobile data (2026-08-30): streaming,
          // downloads, and the two x0x features.
          ListTile(
            leading: Icon(Icons.network_cell_outlined, color: t.accent),
            title: Text('Mobile data',
                style: TextStyle(color: t.bone, fontSize: 15)),
            subtitle: Text(
              'What may use it — streaming, downloads, Channels, '
              'My W@tch',
              style: TextStyle(color: t.ash, fontSize: 12),
            ),
            trailing: Icon(Icons.chevron_right, color: t.ash),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MobileDataScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
