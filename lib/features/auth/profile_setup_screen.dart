import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../state/services/backend_service.dart';
import '../../core/widgets/scorch_mascot.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../core/widgets/photo_picker_sheet.dart';
import '../../state/models/sign_up_draft.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'biometric_prompt_screen.dart';

/// Profile step of sign-up — picture, name and username, after the
/// contact is verified and the PIN is set. The backend checks the
/// username is free here; the account is created on the next (last) step,
/// and the photo is uploaded to it then.
/// KYC isn't part of sign-up: accounts start at tier 0 and verify later,
/// when they hit a tier limit.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key, required this.draft});

  final SignUpDraft draft;

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _usernameController = TextEditingController();
  late final _nameController =
      TextEditingController(text: widget.draft.displayName);
  late Uint8List? _photo = widget.draft.photo;
  bool _busy = false;
  String? _usernameError;

  bool get _canContinue =>
      !_busy && _usernameController.text.trim().length >= 3;

  @override
  void dispose() {
    _usernameController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final result = await showPhotoPickerSheet(context,
        title: 'Profile photo', hasPhoto: _photo != null);
    if (result == null || !mounted) return;
    // Read once: the preview and the upload both use the bytes.
    final bytes = result.removed ? null : await result.file?.readAsBytes();
    if (!mounted) return;
    setState(() => _photo = bytes);
  }

  Future<void> _onContinue() async {
    final uname = _usernameController.text.trim();
    final name = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : uname;
    setState(() {
      _busy = true;
      _usernameError = null;
    });
    try {
      await ref.read(backendServiceProvider).checkUsernameAvailable(uname);
    } catch (error) {
      if (mounted) setState(() => _usernameError = error.toString());
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BiometricPromptScreen(
            draft: widget.draft.copyWith(
                username: uname,
                displayName: name,
                photo: _photo,
                clearPhoto: _photo == null))));
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
                      onTap: () => Navigator.of(context).pop()),
                  const Align(
                      alignment: Alignment.centerRight,
                      child: ScorchMascot(
                          activity: ScorchActivity.protect, size: 64)),
                  Text('Set up your profile', style: AppText.pageTitle),
                  const SizedBox(height: 8),
                  Text(
                      'Add a photo from your device and pick a username people will recognize.',
                      style: AppText.bodyMuted),
                  const SizedBox(height: 32),
                  Center(
                    child: GestureDetector(
                      onTap: _pickPhoto,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 104,
                            height: 104,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: _photo == null
                                  ? null
                                  : AppColors.accentGradient,
                              color: _photo == null ? AppColors.surface2 : null,
                              border: Border.all(
                                  color: AppColors.borderStrong, width: 2),
                              image: _photo == null
                                  ? null
                                  : DecorationImage(
                                      image: MemoryImage(_photo!),
                                      fit: BoxFit.cover,
                                    ),
                            ),
                            alignment: Alignment.center,
                            child: _photo == null
                                ? Icon(AppIcons.user,
                                    size: 40, color: AppColors.muted)
                                : null,
                          ),
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: AppColors.page, width: 3),
                              ),
                              child: const Icon(AppIcons.camera,
                                  size: 15, color: Colors.white),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _nameController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Full Name',
                      hintText: 'e.g. Scorche Okafor',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _usernameController,
                    enabled: !_busy,
                    onChanged: (_) => setState(() => _usernameError = null),
                    decoration: InputDecoration(
                      labelText: 'Username',
                      hintText: 'e.g. scorche',
                      prefixText: '@',
                      errorText: _usernameError,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('You can change this later in Profile settings.',
                      style: AppText.caption),
                  const Spacer(),
                  PrimaryButton(
                      label: 'Continue',
                      loading: _busy,
                      onPressed: _canContinue ? _onContinue : null),
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
