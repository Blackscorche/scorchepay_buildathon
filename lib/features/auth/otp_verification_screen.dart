import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/scorch_mascot.dart';
import '../../core/app_icons.dart';
import '../../core/async_action.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../core/widgets/otp_boxes.dart';
import '../../state/models/sign_up_draft.dart';
import '../../state/services/backend_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'create_pin_screen.dart';

/// Verifies the contact provided during sign up with a 6-digit code,
/// checked by the backend.
class OtpVerificationScreen extends ConsumerStatefulWidget {
  const OtpVerificationScreen({super.key, required this.draft});

  final SignUpDraft draft;

  @override
  ConsumerState<OtpVerificationScreen> createState() =>
      _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends ConsumerState<OtpVerificationScreen>
    with AsyncActionMixin {
  late SignUpDraft _draft = widget.draft;
  String _code = '';
  int _secondsLeft = 30;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    setState(() => _secondsLeft = 30);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onCompleted(String code) {
    setState(() => _code = code);
    _verify();
  }

  Future<void> _verify() async {
    final result = await runAction(() => ref
        .read(backendServiceProvider)
        .verifySignUpCode(_draft.verificationId, _code));
    if (!mounted || !result.hasValue) return;
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => CreatePinScreen(
              draft: _draft.copyWith(signUpToken: result.requireValue))),
    );
  }

  Future<void> _resend() async {
    final result = await runAction(() =>
        ref.read(backendServiceProvider).requestSignUpCode(_draft.contact));
    if (!mounted || !result.hasValue) return;
    _draft = _draft.copyWith(verificationId: result.requireValue);
    _startTimer();
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
                  Text('Verify your number', style: AppText.pageTitle),
                  const SizedBox(height: 8),
                  Text(
                    'Enter the 6-digit code we sent to ${_draft.contact}. '
                    'Demo code: ${BackendService.demoOtp}.',
                    style: AppText.bodyMuted,
                  ),
                  const SizedBox(height: 32),
                  OtpBoxes(
                    length: 6,
                    onChanged: (v) {
                      clearActionError();
                      setState(() => _code = v);
                    },
                    onCompleted: _onCompleted,
                  ),
                  if (actionError case final error?) ...[
                    const SizedBox(height: 12),
                    Text(error, style: TextStyle(color: AppColors.loss)),
                  ],
                  const SizedBox(height: 20),
                  Center(
                    child: _secondsLeft > 0
                        ? Text(
                            'Resend code in 0:${_secondsLeft.toString().padLeft(2, '0')}',
                            style: AppText.caption)
                        : GestureDetector(
                            onTap: _resend,
                            child: Text(
                              'Resend code',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.accent,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 32),
                  PrimaryButton(
                    label: 'Verify',
                    loading: actionRunning,
                    onPressed:
                        _code.length == 6 && !actionRunning ? _verify : null,
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
