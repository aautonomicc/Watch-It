import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/publish_api.dart';
import '../theme/tokens.dart';

/// Settings → Wallet: the internal upload wallet behind Upload.
///
/// Two ways in — generate (BIP-39 seed words shown once, confirm-by-
/// retyping ceremony, only the derived key persists) or import an
/// existing private key / seed phrase. The screen never sees the private
/// key itself; the Rust core keeps it in the OS keychain (or its file
/// fallback, which is called out when in use).
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, this.apiBase, this.apiToken});

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  late final PublishApi _api =
      PublishApi(base: widget.apiBase, token: widget.apiToken);

  WalletStatus? _status;
  String? _error;
  WalletBalances? _balances;
  String? _balancesError;
  bool _balancesLoading = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _status = null;
      _error = null;
      _balances = null;
      _balancesError = null;
    });
    try {
      final status = await _api.walletStatus();
      if (!mounted) return;
      setState(() => _status = status);
      if (status.configured) await _loadBalances();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _loadBalances() async {
    setState(() {
      _balancesLoading = true;
      _balancesError = null;
    });
    try {
      final balances = await _api.balances();
      if (mounted) setState(() => _balances = balances);
    } catch (e) {
      if (mounted) setState(() => _balancesError = '$e');
    } finally {
      if (mounted) setState(() => _balancesLoading = false);
    }
  }

  Future<void> _create() async {
    final GeneratedWallet generated;
    try {
      generated = await _api.generateWallet();
    } catch (e) {
      _snack('$e');
      return;
    }
    if (!mounted) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => SeedBackupScreen(wallet: generated, api: _api),
    ));
    if (done == true) {
      _snack('Wallet created');
      await _reload();
    }
  }

  Future<void> _import() async {
    final imported = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportWalletDialog(api: _api),
    );
    if (imported == true) {
      _snack('Wallet imported');
      await _reload();
    }
  }

  Future<void> _remove() async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Remove wallet?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'This deletes the wallet key from this computer. Any funds stay '
          'on the address, but you can only reach them again with the '
          'seed words or private key — make sure you have that backup '
          'before removing.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Remove wallet', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.removeWallet();
      _snack('Wallet removed');
    } catch (e) {
      _snack('$e');
    }
    await _reload();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _sectionHeader(WiTokens t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
            color: t.ash,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Wallet', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: _error != null
          ? _ErrorRetry(message: _error!, onRetry: _reload)
          : status == null
              ? const Center(child: CircularProgressIndicator())
              : status.configured
                  ? _configuredBody(t, status)
                  : _setupBody(t),
    );
  }

  Widget _setupBody(WiTokens t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Uploading to the Autonomi network is paid in ANT, from a '
          'wallet that lives on this computer.',
          style: TextStyle(color: t.bone, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 12),
        Text(
          'Treat it as a hot wallet: use a dedicated wallet just for '
          'W@tch and keep only small amounts in it — not your main '
          'holdings.',
          style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add),
          label: const Text('Create new wallet'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _import,
          icon: const Icon(Icons.key_outlined),
          label: const Text('Import existing wallet'),
        ),
      ],
    );
  }

  Widget _configuredBody(WiTokens t, WalletStatus status) {
    final balances = _balances;
    return ListView(
      children: [
        _sectionHeader(t, 'ADDRESS'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  status.address ?? '',
                  style: TextStyle(
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback,
                    fontSize: 12.5,
                    color: t.accent,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy address',
                icon: Icon(Icons.copy, color: t.ash, size: 18),
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: status.address ?? ''));
                  _snack('Address copied');
                },
              ),
            ],
          ),
        ),
        if (status.storage == 'file')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'No system keychain was found, so the key is stored in an '
              'app file on this computer.',
              style: TextStyle(color: t.rust, fontSize: 12),
            ),
          ),
        _sectionHeader(t, 'BALANCE'),
        ListTile(
          leading: Icon(Icons.toll_outlined, color: t.accent),
          title: Text(
            _balancesLoading || balances == null
                ? '—'
                : '${formatUnits(balances.antAtto)} ANT',
            style: TextStyle(color: t.bone, fontSize: 15),
          ),
          subtitle: Text('Pays for storage',
              style: TextStyle(color: t.ash, fontSize: 12)),
        ),
        ListTile(
          leading: Icon(Icons.local_gas_station_outlined, color: t.accent),
          title: Text(
            _balancesLoading || balances == null
                ? '—'
                : '${formatUnits(balances.ethWei)} ETH',
            style: TextStyle(color: t.bone, fontSize: 15),
          ),
          subtitle: Text('Pays transaction gas',
              style: TextStyle(color: t.ash, fontSize: 12)),
          trailing: IconButton(
            tooltip: 'Refresh balances',
            icon: Icon(Icons.refresh, color: t.ash, size: 18),
            onPressed: _balancesLoading ? null : _loadBalances,
          ),
        ),
        if (_balancesError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('Balance check failed: $_balancesError',
                style: TextStyle(color: t.rust, fontSize: 12)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'Balances live on the Arbitrum One network. To fund the '
            'wallet, send ANT (for storage) and a little ETH (for gas) '
            'to the address above — from an exchange or another wallet, '
            'choosing Arbitrum One as the network.',
            style: TextStyle(color: t.boneDim, fontSize: 12, height: 1.4),
          ),
        ),
        _sectionHeader(t, 'DANGER ZONE'),
        ListTile(
          leading: Icon(Icons.delete_forever_outlined, color: t.rust),
          title: Text('Remove wallet from this computer',
              style: TextStyle(color: t.rust, fontSize: 15)),
          subtitle: Text(
            'Funds stay on the address; only the local key is deleted',
            style: TextStyle(color: t.ash, fontSize: 12),
          ),
          onTap: _remove,
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.boneDim, fontSize: 13)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// Full-screen, one-time display of the 12 seed words, then a
/// confirm-by-retyping step before anything is stored. Pops `true` once
/// the wallet is imported.
class SeedBackupScreen extends StatefulWidget {
  const SeedBackupScreen({
    super.key,
    required this.wallet,
    required this.api,
    this.confirmIndices,
  });

  final GeneratedWallet wallet;
  final PublishApi api;

  /// Word positions (0-based) the confirm step asks for; random when
  /// null. Fixed in tests.
  final List<int>? confirmIndices;

  @override
  State<SeedBackupScreen> createState() => _SeedBackupScreenState();
}

class _SeedBackupScreenState extends State<SeedBackupScreen> {
  bool _confirming = false;
  late final List<String> _words =
      widget.wallet.mnemonic.split(RegExp(r'\s+'));
  late final List<int> _indices = _pickIndices();
  final List<TextEditingController> _controllers =
      List.generate(3, (_) => TextEditingController());
  String? _mismatch;
  bool _importing = false;

  List<int> _pickIndices() {
    final given = widget.confirmIndices;
    if (given != null) return List.of(given)..sort();
    final all = List<int>.generate(_words.length, (i) => i)..shuffle(Random());
    return all.take(3).toList()..sort();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _finish() async {
    for (var i = 0; i < _indices.length; i++) {
      if (_controllers[i].text.trim().toLowerCase() != _words[_indices[i]]) {
        setState(() => _mismatch =
            'Word #${_indices[i] + 1} does not match — check your notes.');
        return;
      }
    }
    setState(() {
      _mismatch = null;
      _importing = true;
    });
    try {
      await widget.api.importWallet(mnemonic: widget.wallet.mnemonic);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _importing = false;
          _mismatch = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(_confirming ? 'Confirm backup' : 'Back up your wallet',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: _confirming ? _confirmBody(t) : _wordsBody(t),
    );
  }

  Widget _wordsBody(WiTokens t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Write these 12 words down on paper, in order, and keep them '
          'somewhere safe. They are the only backup of this wallet.',
          style: TextStyle(color: t.bone, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 8),
        Text(
          'Anyone who has the words controls the funds. W@tch does not '
          'store them and cannot recover them for you.',
          style: TextStyle(color: t.rust, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _words.length; i++)
              Container(
                width: 150,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: t.ink2,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: t.line),
                ),
                child: Text(
                  '${i + 1}. ${_words[i]}',
                  style: TextStyle(
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback,
                    fontSize: 13,
                    color: t.bone,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Wallet address: ${widget.wallet.address}',
          style: TextStyle(
            fontFamily: wiMonoFamily,
            fontFamilyFallback: wiMonoFallback,
            fontSize: 11.5,
            color: t.boneDim,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => setState(() => _confirming = true),
          child: const Text("I've written them down"),
        ),
      ],
    );
  }

  Widget _confirmBody(WiTokens t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Enter the requested words from your notes to prove the backup '
          'exists. The wallet is created only after this step.',
          style: TextStyle(color: t.bone, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _indices.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: _controllers[i],
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(
                fontFamily: wiMonoFamily,
                fontFamilyFallback: wiMonoFallback,
                color: t.bone,
              ),
              decoration: InputDecoration(
                labelText: 'Word #${_indices[i] + 1}',
                labelStyle: TextStyle(color: t.ash),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        if (_mismatch != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_mismatch!,
                style: TextStyle(color: t.rust, fontSize: 13)),
          ),
        Row(
          children: [
            TextButton(
              onPressed: _importing
                  ? null
                  : () => setState(() => _confirming = false),
              child:
                  Text('Show words again', style: TextStyle(color: t.ash)),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _importing ? null : _finish,
              child: Text(_importing ? 'Creating…' : 'Create wallet'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ImportWalletDialog extends StatefulWidget {
  const _ImportWalletDialog({required this.api});
  final PublishApi api;

  @override
  State<_ImportWalletDialog> createState() => _ImportWalletDialogState();
}

class _ImportWalletDialogState extends State<_ImportWalletDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // ≥2 whitespace-separated tokens → seed phrase; else a private key.
    final isMnemonic = text.split(RegExp(r'\s+')).length >= 2;
    try {
      await widget.api.importWallet(
        mnemonic: isMnemonic ? text : null,
        privateKey: isMnemonic ? null : text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Import wallet',
          style: TextStyle(color: t.bone, fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paste a 12- or 24-word seed phrase, or a private key '
              '(64 hex characters). Use a dedicated upload wallet with '
              'small amounts — the key will live on this computer.',
              style: TextStyle(color: t.boneDim, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 3,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(
                fontFamily: wiMonoFamily,
                fontFamilyFallback: wiMonoFallback,
                fontSize: 13,
                color: t.bone,
              ),
              decoration: InputDecoration(
                hintText: 'seed phrase or private key',
                hintStyle: TextStyle(color: t.ash),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!,
                    style: TextStyle(color: t.rust, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Importing…' : 'Import',
              style: TextStyle(color: t.accent)),
        ),
      ],
    );
  }
}
