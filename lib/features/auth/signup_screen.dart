import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../state/services/backend_service.dart';
import '../../app_routes.dart';
import '../../core/widgets/scorch_mascot.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../theme/app_colors.dart';
import '../../state/models/sign_up_draft.dart';
import '../../theme/app_text_styles.dart';
import 'otp_verification_screen.dart';

/// First sign-up step: collects a name and contact, then asks the backend
/// to send an OTP to that contact. The account itself is only created on
/// the last step (see [SignUpDraft]).
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _nameController = TextEditingController();
  final _contactController = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _canContinue =>
      !_busy &&
      _nameController.text.trim().isNotEmpty &&
      _contactController.text.trim().isNotEmpty;

  @override
  void dispose() {
    _nameController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  void _onEdited(String _) => setState(() => _error = null);

  Future<void> _onContinue() async {
    final contact = _contactController.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verificationId =
          await ref.read(backendServiceProvider).requestSignUpCode(contact);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OtpVerificationScreen(
              draft: SignUpDraft(
                  displayName: _nameController.text.trim(),
                  contact: contact,
                  verificationId: verificationId)),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              child: Column(
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
                  Text('Create your account', style: AppText.pageTitle),
                  const SizedBox(height: 8),
                  Text("Let's get your Money OS set up.",
                      style: AppText.bodyMuted),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _nameController,
                    enabled: !_busy,
                    onChanged: _onEdited,
                    decoration: const InputDecoration(
                      labelText: 'Full name',
                      hintText: 'e.g. Scorche Abu',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _contactController,
                    enabled: !_busy,
                    onChanged: _onEdited,
                    decoration: const InputDecoration(
                      labelText: 'Phone number or email',
                      hintText: 'e.g. +234 801 234 5678',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: AppColors.loss)),
                  ],
                  const SizedBox(height: 28),
                  PrimaryButton(
                    label: 'Continue',
                    loading: _busy,
                    onPressed: _canContinue ? _onContinue : null,
                  ),
                  const Spacer(),
                  Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Already have an account?',
                            style: AppText.bodyMuted),
                        GestureDetector(
                          onTap: () => context.go(AppRoutes.login),
                          child: Text(
                            ' Log in',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
