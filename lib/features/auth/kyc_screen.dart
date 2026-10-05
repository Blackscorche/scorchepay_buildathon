import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/app_modal.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/decorative_rings.dart';
import '../../core/widgets/photo_picker_sheet.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'biometric_prompt_screen.dart';

class _IdType {
  const _IdType(this.label);
  final String label;
}

const _idTypes = [
  _IdType('National ID (NIN)'),
  _IdType('International Passport'),
  _IdType("Driver's License"),
  _IdType("Voter's Card"),
];

const _stepTitles = ['Identity document', 'Upload documents', 'Take a selfie'];
const _stepSubtitles = [
  'Choose an ID type and enter its number.',
  'Clear photos of the front and back of your ID.',
  'Make sure your face is well-lit and centered.',
];

/// KYC verification — reached once the account, PIN and profile exist.
/// Three steps in one screen (ID type/number, document photos, selfie)
/// rather than separate pushed routes, since it's one continuous task
/// with a shared progress indicator. Fully mocked: no real camera/upload,
/// matches the rest of the app's mocked backend.
class KycScreen extends StatefulWidget {
  const KycScreen({super.key});

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  int _step = 0;
  int? _idType;
  final _idNumberController = TextEditingController();
  File? _frontPhoto;
  File? _backPhoto;
  File? _selfiePhoto;
  bool _submitting = false;

  @override
  void dispose() {
    _idNumberController.dispose();
    super.dispose();
  }

  bool get _canContinue {
    switch (_step) {
      case 0:
        return _idType != null && _idNumberController.text.trim().isNotEmpty;
      case 1:
        return _frontPhoto != null && _backPhoto != null;
      default:
        return _selfiePhoto != null;
    }
  }

  void _back() {
    if (_step == 0) {
      Navigator.of(context).pop();
    } else {
      setState(() => _step -= 1);
    }
  }

  Future<void> _continue() async {
    if (_step < 2) {
      setState(() => _step += 1);
      return;
    }
    setState(() => _submitting = true);
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _submitting = false);
    await showAppModal(
      context,
      icon: AppIcons.shieldCheck,
      iconColor: AppColors.gain,
      title: 'Verification submitted',
      message:
          "We're reviewing your documents — this usually takes less than 24 hours. You can keep using ScorchePay in the meantime.",
      actionLabel: 'Continue',
    );
    if (mounted) {
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const BiometricPromptScreen()));
    }
  }

  Future<void> _pickDoc({required bool isFront}) async {
    final existing = isFront ? _frontPhoto : _backPhoto;
    final result = await showPhotoPickerSheet(context,
        title: isFront ? 'Front of ID' : 'Back of ID',
        hasPhoto: existing != null);
    if (result == null || !mounted) return;
    final file = result.removed ? null : result.file;
    setState(() => isFront ? _frontPhoto = file : _backPhoto = file);
  }

  Future<void> _pickSelfie() async {
    final result = await showPhotoPickerSheet(context,
        title: 'Take a selfie', hasPhoto: _selfiePhoto != null);
    if (result == null || !mounted) return;
    setState(() => _selfiePhoto = result.removed ? null : result.file);
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
                  IconCircleButton(icon: AppIcons.chevronLeft, onTap: _back),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      for (int i = 0; i < 3; i++)
                        Expanded(
                          child: Container(
                            height: 4,
                            margin: EdgeInsets.only(right: i != 2 ? 6 : 0),
                            decoration: BoxDecoration(
                              color: i <= _step
                                  ? AppColors.accent
                                  : AppColors.surface3,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(_stepTitles[_step], style: AppText.pageTitle),
                  const SizedBox(height: 8),
                  Text(_stepSubtitles[_step], style: AppText.bodyMuted),
                  const SizedBox(height: 28),
                  Expanded(child: SingleChildScrollView(child: _buildStep())),
                  PrimaryButton(
                    label: _step == 2 ? 'Submit for verification' : 'Continue',
                    loading: _submitting,
                    onPressed: _canContinue && !_submitting ? _continue : null,
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

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _idStep();
      case 1:
        return _documentsStep();
      default:
        return _selfieStep();
    }
  }

  Widget _idStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < _idTypes.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: _IdTypeTile(
              label: _idTypes[i].label,
              selected: i == _idType,
              onTap: () => setState(() => _idType = i),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          controller: _idNumberController,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
              labelText: 'ID number', hintText: 'Enter the number on your ID'),
        ),
      ],
    );
  }

  Widget _documentsStep() {
    return Row(
      children: [
        Expanded(
            child: _DocTile(
                label: 'Front of ID',
                photo: _frontPhoto,
                onTap: () => _pickDoc(isFront: true))),
        const SizedBox(width: 12),
        Expanded(
            child: _DocTile(
                label: 'Back of ID',
                photo: _backPhoto,
                onTap: () => _pickDoc(isFront: false))),
      ],
    );
  }

  Widget _selfieStep() {
    final hasSelfie = _selfiePhoto != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: GestureDetector(
          onTap: _pickSelfie,
          child: Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasSelfie ? null : AppColors.surface2,
              image: hasSelfie
                  ? DecorationImage(
                      image: FileImage(_selfiePhoto!), fit: BoxFit.cover)
                  : null,
              border: Border.all(
                  color: hasSelfie ? AppColors.accent : AppColors.borderStrong,
                  width: 2),
            ),
            alignment: Alignment.center,
            child: hasSelfie
                ? Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.35),
                    ),
                    padding: const EdgeInsets.all(10),
                    child: const Icon(AppIcons.check,
                        size: 24, color: Colors.white),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.camera, size: 40, color: AppColors.muted),
                      SizedBox(height: 8),
                      Text(
                        'Tap to capture',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.muted),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _IdTypeTile extends StatelessWidget {
  const _IdTypeTile(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface2,
          border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(AppIcons.idCard,
                size: 18,
                color: selected ? AppColors.accent : AppColors.textSecondary),
            const SizedBox(width: 12),
            Expanded(
                child: Text(label,
                    style: AppText.body.copyWith(
                        color: selected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary))),
            if (selected)
              Icon(AppIcons.check, size: 17, color: AppColors.accent),
          ],
        ),
      ),
    );
  }
}

class _DocTile extends StatelessWidget {
  const _DocTile(
      {required this.label, required this.photo, required this.onTap});

  final String label;
  final File? photo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final uploaded = photo != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 130,
          decoration: BoxDecoration(
            color: uploaded ? AppColors.accentSoft : AppColors.surface2,
            border: Border.all(
                color: uploaded
                    ? AppColors.accent.withValues(alpha: 0.5)
                    : AppColors.border),
            borderRadius: BorderRadius.circular(16),
            image: uploaded
                ? DecorationImage(image: FileImage(photo!), fit: BoxFit.cover)
                : null,
          ),
          alignment: Alignment.center,
          child: uploaded
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(20)),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.check, size: 13, color: Colors.white),
                      SizedBox(width: 5),
                      Text('Uploaded',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(AppIcons.camera, size: 26, color: AppColors.muted),
                    const SizedBox(height: 9),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
