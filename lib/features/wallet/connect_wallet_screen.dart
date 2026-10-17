import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_env_vars.dart';
import '../../core/app_icons.dart';
import '../../core/async_action.dart';
import '../../core/widgets/buttons.dart';
import '../../state/models/connected_wallet.dart';
import '../../state/providers/wallets_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// Opens [ConnectWalletScreen]; resolves to the connected wallet, or null if
/// the user backed out.
Future<ConnectedWallet?> openConnectWallet(BuildContext context) {
  return Navigator.of(context).push<ConnectedWallet>(
    MaterialPageRoute(builder: (_) => const ConnectWalletScreen()),
  );
}

/// Connects a Lightning wallet with a Nostr Wallet Connect string pasted
/// from the user's wallet app. (QR scanning can come later.)
class ConnectWalletScreen extends ConsumerStatefulWidget {
  const ConnectWalletScreen({super.key});

  @override
  ConsumerState<ConnectWalletScreen> createState() =>
      _ConnectWalletScreenState();
}

class _ConnectWalletScreenState extends ConsumerState<ConnectWalletScreen>
    with AsyncActionMixin {
  static const _mockWallets = bool.fromEnvironment(AppEnvVars.mockWallets);

  final _uriController = TextEditingController();

  @override
  void dispose() {
    _uriController.dispose();
    super.dispose();
  }

  void _onEdited(String _) {
    clearActionError();
    setState(() {}); // re-evaluate the Connect button
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    _uriController.text = text;
    _onEdited(text);
  }

  /// Mock mode only: a well-formed connection string with random keys.
  void _useDemoConnection() {
    final random = Random.secure();
    String hex() => List.generate(
            32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    _uriController.text = 'nostr+walletconnect://${hex()}'
        '?relay=wss%3A%2F%2Frelay.example.com&secret=${hex()}';
    _onEdited(_uriController.text);
  }

  Future<void> _connect() async {
    final notifier = ref.read(walletsProvider.notifier);
    final result = await runAction(() => notifier.connect(_uriController.text));
    if (!mounted || !result.hasValue) return;
    final wallet = result.requireValue;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('${wallet.name} connected.')));
    Navigator.of(context).pop(wallet);
  }

  @override
  Widget build(BuildContext context) {
    final canConnect = !actionRunning && _uriController.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: AppColors.page,
      body: SafeArea(
        // SingleChildScrollView + Column (not ListView) so the groups can use
        // `spacing`. Stretch matches ListView's full-width children.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 24,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 20,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconCircleButton(
                      icon: AppIcons.chevronLeft,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 8,
                    children: [
                      Text('Connect a wallet', style: AppText.pageTitle),
                      Text(
                          'Pay for top-ups straight from your own Lightning '
                          'wallet. ScorchePay never holds your funds.',
                          style: AppText.bodyMuted),
                    ],
                  ),
                ],
              ),
              const Column(
                spacing: 12,
                children: [
                  _Step(
                      number: 1,
                      text: 'In your wallet app, open its app connections. '
                          'They are often called Nostr Wallet Connect or NWC.'),
                  _Step(
                      number: 2,
                      text: 'Create a connection for ScorchePay that can read '
                          'your balance and pay invoices. Set a budget, or ask '
                          'to approve each payment, if your wallet offers it.'),
                  _Step(
                      number: 3,
                      text: 'Copy the connection string and paste it below.'),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  TextField(
                    controller: _uriController,
                    enabled: !actionRunning,
                    onChanged: _onEdited,
                    minLines: 3,
                    maxLines: 5,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    style: AppText.body.copyWith(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Connection string',
                      hintText: 'nostr+walletconnect://…',
                      alignLabelWithHint: true,
                      errorText: actionError,
                      errorMaxLines: 3,
                    ),
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: actionRunning ? null : _paste,
                        icon: Icon(AppIcons.copy,
                            size: 16, color: AppColors.accent),
                        label: Text('Paste',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: AppColors.accent)),
                      ),
                      if (_mockWallets)
                        TextButton(
                          onPressed: actionRunning ? null : _useDemoConnection,
                          child: Text('Use a demo connection',
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.accent)),
                        ),
                    ],
                  ),
                  Text(
                      'The connection string can spend from your wallet up to '
                      'its budget. It stays on this device.',
                      style: AppText.caption),
                ],
              ),
              PrimaryButton(
                label: 'Connect',
                loading: actionRunning,
                onPressed: canConnect ? _connect : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AppColors.accentSoft, shape: BoxShape.circle),
          child: Text('$number',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accent)),
        ),
        Expanded(child: Text(text, style: AppText.body)),
      ],
    );
  }
}
