import 'package:flutter/material.dart';
import '../../core/widgets/scorch_mascot.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../core/widgets/pin_dots.dart';
import '../../state/models/sign_up_draft.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'profile_setup_screen.dart';

/// Second half of PIN setup — re-enter the PIN to confirm it matches.
class ConfirmPinScreen extends StatefulWidget {
  const ConfirmPinScreen(
      {super.key, required this.draft, required this.originalPin});

  final SignUpDraft draft;
  final String originalPin;

  @override
  State<ConfirmPinScreen> createState() => _ConfirmPinScreenState();
}

class _ConfirmPinScreenState extends State<ConfirmPinScreen> {
  String _pin = '';
  bool _mismatch = false;

  void _onKey(String digit) {
    if (_pin.length >= 4 || _mismatch) return;
    setState(() => _pin += digit);
    if (_pin.length == 4) {
      if (_pin == widget.originalPin) {
        Future.delayed(const Duration(milliseconds: 250), () {
          if (mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => ProfileSetupScreen(
                      draft: widget.draft.copyWith(pin: _pin))),
            );
          }
        });
      } else {
        setState(() => _mismatch = true);
        Future.delayed(const Duration(milliseconds: 900), () {
          if (mounted) {
            setState(() {
              _mismatch = false;
              _pin = '';
            });
          }
        });
      }
    }
  }

  void _onBackspace() {
    if (_pin.isEmpty || _mismatch) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
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
                  const Align(alignment: Alignment.centerRight, child: ScorchMascot(activity: ScorchActivity.protect, size: 64)),
                  Text('Confirm your PIN', style: AppText.pageTitle),
                  const SizedBox(height: 8),
                  Text('Enter it again to confirm.',
                      style: AppText.bodyMuted),
                  const SizedBox(height: 40),
                  Center(child: PinDots(length: 4, filled: _pin.length)),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 18,
                    child: _mismatch
                        ? const Center(
                            child: Text(
                              "PINs didn't match — try again",
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.loss,
                              ),
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 24),
                  NumericKeypad(onKey: _onKey, onBackspace: _onBackspace),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
