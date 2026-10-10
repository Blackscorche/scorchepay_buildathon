import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/widgets/scorch_mascot.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../core/widgets/photo_picker_sheet.dart';
import '../../state/providers/profile_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'kyc_screen.dart';

/// Profile step of onboarding — picture and username, shown once the
/// account exists (contact verified, PIN set) but before identity
/// verification.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _usernameController = TextEditingController();
  final _nameController = TextEditingController(text: 'Scorche');
  File? _photo;

  bool get _canContinue => _usernameController.text.trim().length >= 3;

  @override
  void dispose() {
    _usernameController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final result = await showPhotoPickerSheet(context, title: 'Profile photo', hasPhoto: _photo != null);
    if (result == null || !mounted) return;
    setState(() => _photo = result.removed ? null : result.file);
  }

  Future<void> _onContinue() async {
    final uname = _usernameController.text.trim();
    final name = _nameController.text.trim().isNotEmpty ? _nameController.text.trim() : uname;
    final notifier = ref.read(userProfileProvider.notifier);
    await notifier.updateProfile(username: uname, displayName: name);
    if (_photo != null) {
      await notifier.setPhoto(_photo!.path);
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const KycScreen()));
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
                  const Align(alignment: Alignment.centerRight, child: ScorchMascot(activity: ScorchActivity.protect, size: 64)),
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
                              gradient: _photo == null ? null : AppColors.accentGradient,
                              color: _photo == null ? AppColors.surface2 : null,
                              border: Border.all(color: AppColors.borderStrong, width: 2),
                              image: _photo == null
                                  ? null
                                  : DecorationImage(
                                      image: FileImage(_photo!),
                                      fit: BoxFit.cover,
                                    ),
                            ),
                            alignment: Alignment.center,
                            child: _photo == null
                                ? Icon(AppIcons.user, size: 40, color: AppColors.muted)
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
                                border: Border.all(color: AppColors.page, width: 3),
                              ),
                              child: const Icon(AppIcons.camera, size: 15, color: Colors.white),
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
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      hintText: 'e.g. scorche',
                      prefixText: '@',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('You can change this later in Profile settings.',
                      style: AppText.caption),
                  const Spacer(),
                  PrimaryButton(
                      label: 'Continue',
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
