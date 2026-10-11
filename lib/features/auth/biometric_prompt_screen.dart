import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_icons.dart';
import '../../core/async_action.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../state/models/sign_up_draft.dart';
import '../../state/providers/app_state_notifier.dart';
import '../../state/services/passkey_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// Final sign-up step — offers biometric login with a passkey. Either
/// choice creates the account from [draft] and signs in; Enable also adds
/// a passkey, which shows the OS biometric prompt. Where passkeys aren't
/// available, this only explains that and continues.
class BiometricPromptScreen extends ConsumerStatefulWidget {
  const BiometricPromptScreen({super.key, required this.draft});

  final SignUpDraft draft;

  @override
  ConsumerState<BiometricPromptScreen> createState() =>
      _BiometricPromptScreenState();
}

class _BiometricPromptScreenState extends ConsumerState<BiometricPromptScreen>
    with AsyncActionMixin {
  Future<void> _proceed({required bool addPasskey}) async {
    // The app-wide messenger outlives this screen, which the router
    // replaces with home once signed in, so it's captured up front.
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(appStateProvider.notifier);
    final result = await runAction(
        () => notifier.signUp(widget.draft, registerPasskey: addPasskey));
    // Failure: shown on this screen via actionError.
    final signUp = result.valueOrNull;
    if (signUp == null) return;
    final problems = [
      if (signUp.photoError != null)
        "Your photo wasn't saved: ${signUp.photoError}",
      if (signUp.passkeyError != null)
        'No passkey was added: ${signUp.passkeyError}',
    ];
    if (problems.isNotEmpty) {
      messenger.showSnackBar(SnackBar(
          content: Text("You're signed up. ${problems.join(' ')}")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = ref.watch(passkeysAvailableProvider);
    return Scaffold(
      backgroundColor: AppColors.page,
      body: Stack(
        children: [
          const Positioned.fill(child: AuthBackdrop()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(AppIcons.faceId,
                        size: 40, color: AppColors.accent),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Enable biometric login',
                    textAlign: TextAlign.center,
                    style: AppText.detailTitle,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    available
                        ? 'Add a passkey to log in with Face ID or your fingerprint instead of your PIN.'
                        : "Biometric login isn't available on this device yet. You'll log in with your PIN.",
                    textAlign: TextAlign.center,
                    style: AppText.bodyMuted,
                  ),
                  const Spacer(flex: 4),
                  if (actionError case final error?) ...[
                    Text(error,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppColors.loss)),
                    const SizedBox(height: 12),
                  ],
                  if (available) ...[
                    PrimaryButton(
                        label: 'Enable',
                        loading: actionRunning,
                        onPressed:
                            actionRunning ? null : () => _proceed(addPasskey: true)),
                    const SizedBox(height: 10),
                    SecondaryButton(
                        label: 'Maybe later',
                        onPressed:
                            actionRunning ? null : () => _proceed(addPasskey: false)),
                  ] else
                    PrimaryButton(
                        label: 'Continue',
                        loading: actionRunning,
                        onPressed:
                            actionRunning ? null : () => _proceed(addPasskey: false)),
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
