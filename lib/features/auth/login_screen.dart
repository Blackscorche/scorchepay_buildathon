import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../state/providers/app_state_notifier.dart';
import '../../state/services/backend_service.dart';
import '../../core/widgets/scorch_mascot.dart';
import '../../app_routes.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../core/widgets/pin_dots.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// Returning-user login — username field plus a 4-digit PIN keypad.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _contactController = TextEditingController();
  String _pin = '';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _contactController.dispose();
    super.dispose();
  }

  void _onKey(String digit) {
    if (_busy || _pin.length >= 4) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == 4) _login();
  }

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(appStateProvider.notifier)
          .login(_contactController.text, _pin);
      if (mounted) {
        Navigator.of(context)
            .pushNamedAndRemoveUntil(AppRoutes.home, (_) => false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _pin = '';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Back to Welcome (e.g. to create a new account). Welcome is normally
  /// already underneath — see `openAuthEntry` — but fall back to opening
  /// it if Login is ever the only route.
  void _back() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.pushReplacementNamed(AppRoutes.welcome);
    }
  }

  void _onBackspace() {
    if (_busy || _pin.isEmpty) return;
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
                        enabled: !_busy,
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
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
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
                      ),
                      if (_busy) const LinearProgressIndicator(),
                      if (_error != null)
                        Text(_error!, style: TextStyle(color: AppColors.loss)),
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
