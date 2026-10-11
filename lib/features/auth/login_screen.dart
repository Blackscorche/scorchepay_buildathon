import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../state/providers/app_state_notifier.dart';
import '../../state/services/backend_service.dart';
import '../../state/services/passkey_service.dart';
import '../../core/widgets/scorch_mascot.dart';
import '../../app_routes.dart';
import '../../core/app_icons.dart';
import '../../core/async_action.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../core/widgets/pin_dots.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// Returning-user login — username field plus a 4-digit PIN keypad, or a
/// passkey where available.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with AsyncActionMixin {
  late final TextEditingController _contactController;
  String _pin = '';

  @override
  void initState() {
    super.initState();
    _contactController = TextEditingController(
        text: ref.read(appStateProvider).requireValue.localState.username);
  }

  @override
  void dispose() {
    _contactController.dispose();
    super.dispose();
  }

  void _onKey(String digit) {
    if (actionRunning || _pin.length >= 4) return;
    clearActionError();
    setState(() => _pin += digit);
    if (_pin.length == 4) _login();
  }

  // On success the router navigates on once the session is signed in;
  // failures show via actionError.
  Future<void> _login() async {
    final result = await runAction(() => ref
        .read(appStateProvider.notifier)
        .login(_contactController.text, _pin));
    if (mounted && result.hasError) setState(() => _pin = '');
  }

  Future<void> _loginWithPasskey() async {
    setState(() => _pin = '');
    await runAction(
        () => ref.read(appStateProvider.notifier).loginWithPasskey());
  }

  /// Back to Welcome (e.g. to create a new account). Login is nested
  /// under Welcome, so this is normally a pop; go() covers the case where
  /// nothing is underneath.
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.welcome);
    }
  }

  void _onBackspace() {
    if (actionRunning || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  void _forgotPin() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              'PIN recovery is not available yet. Please contact support.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final passkeysAvailable = ref.watch(passkeysAvailableProvider);
    return Scaffold(
      backgroundColor: AppColors.page,
      body: Stack(
        children: [
          const Positioned.fill(child: AuthBackdrop()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ListView(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      IconCircleButton(
                        icon: AppIcons.chevronLeft,
                        onTap: _back,
                      ),
                      const Align(
                          alignment: Alignment.centerRight,
                          child: ScorchMascot(
                              activity: ScorchActivity.protect, size: 64)),
                      Text('Welcome back', style: AppText.pageTitle),
                      const SizedBox(height: 8),
                      Text(
                          'Demo account: username "${BackendService.demoUsername}" '
                          '(or leave it blank), PIN ${BackendService.demoPin}.',
                          style: AppText.bodyMuted),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _contactController,
                        enabled: !actionRunning,
                        decoration:
                            const InputDecoration(labelText: 'Username'),
                      ),
                      const SizedBox(height: 28),
                      Center(
                          child:
                              Text('Enter your PIN', style: AppText.bodyMuted)),
                      const SizedBox(height: 16),
                      Center(child: PinDots(length: 4, filled: _pin.length)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (passkeysAvailable)
                            TextButton.icon(
                              onPressed: actionRunning ? null : _loginWithPasskey,
                              icon: Icon(AppIcons.fingerprint,
                                  size: 18, color: AppColors.accent),
                              label: Text(
                                'Use a passkey',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.accent,
                                ),
                              ),
                            ),
                          const Spacer(),
                          TextButton(
                            onPressed: _forgotPin,
                            child: Text(
                              'Forgot PIN?',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.accent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (actionRunning) const LinearProgressIndicator(),
                      if (actionError case final error?)
                        Text(error, style: TextStyle(color: AppColors.loss)),
                      NumericKeypad(onKey: _onKey, onBackspace: _onBackspace),
                      const SizedBox(height: 8),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
