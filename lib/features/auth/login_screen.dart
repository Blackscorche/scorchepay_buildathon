import 'package:flutter/material.dart';
import '../../core/widgets/scorch_mascot.dart';
import '../../app_routes.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../core/widgets/pin_dots.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// Returning-user login — contact field plus a 4-digit PIN keypad.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
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
      await Future.delayed(const Duration(milliseconds: 300));
      if (_pin != '1234') throw Exception('Demo PIN is 1234');
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
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Align(
                          alignment: Alignment.centerRight,
                          child: ScorchMascot(
                              activity: ScorchActivity.protect, size: 64)),
                      Text('Welcome back', style: AppText.pageTitle),
                      const SizedBox(height: 8),
                      Text('Explore demo mode. PIN: 1234.',
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
