import 'package:flutter/material.dart';
import '../services/tv_settings.dart';

/// Owns the controller until the dialog route is actually disposed.
class DeviceNameDialog extends StatefulWidget {
  const DeviceNameDialog({
    super.key,
    required this.title,
    required this.initialName,
  });
  final String title;
  final String initialName;

  @override
  State<DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<DeviceNameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: TextField(
      controller: _controller,
      autofocus: !TvSettings.instance.enabled,
      maxLength: 48,
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => _submit(),
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(
        labelText: 'Device name',
        helperText: 'The name your other devices will see',
        helperMaxLines: 2,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        autofocus: TvSettings.instance.enabled,
        onPressed: _controller.text.trim().isEmpty ? null : _submit,
        child: const Text('Continue'),
      ),
    ],
  );
}
