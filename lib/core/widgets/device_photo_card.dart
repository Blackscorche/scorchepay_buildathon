import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../app_icons.dart';
import 'photo_picker_sheet.dart';

/// Reusable high-standard photo picker card backed by device camera & photo library.
/// Shows an interactive placeholder when empty and a cover preview with actions when filled.
class DevicePhotoCard extends StatelessWidget {
  const DevicePhotoCard({
    super.key,
    required this.label,
    required this.photo,
    required this.onChanged,
    this.hint = 'Take a photo or choose from library',
    this.icon = AppIcons.camera,
    this.height = 140,
    this.title = 'Add Photo',
  });

  final String label;
  final String hint;
  final XFile? photo;
  final ValueChanged<XFile?> onChanged;
  final IconData icon;
  final double height;
  final String title;

  Future<void> _pick(BuildContext context) async {
    final res = await showPhotoPickerSheet(
      context,
      title: title,
      hasPhoto: photo != null,
    );
    if (res == null) return;
    onChanged(res.removed ? null : res.file);
  }

  void _viewFullScreen(BuildContext context) {
    final currentPhoto = photo;
    if (currentPhoto == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(AppIcons.chevronLeft, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
          ),
          body: Center(
            child: InteractiveViewer(
              child: Image(
                  image: pickedPhotoImage(currentPhoto), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentPhoto = photo;
    final hasPhoto = currentPhoto != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: AppText.sectionTitle),
            if (hasPhoto)
              GestureDetector(
                onTap: () => _pick(context),
                child: Text(
                  'Change',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => hasPhoto ? _viewFullScreen(context) : _pick(context),
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: height,
            width: double.infinity,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: hasPhoto
                  ? AppColors.surface2
                  : AppColors.surface2.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: hasPhoto
                    ? AppColors.accent.withValues(alpha: 0.4)
                    : AppColors.borderStrong,
                width: hasPhoto ? 1.5 : 1,
              ),
            ),
            child: hasPhoto
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Image(
                          image: pickedPhotoImage(currentPhoto),
                          fit: BoxFit.cover),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [
                                Colors.black.withValues(alpha: 0.8),
                                Colors.transparent
                              ],
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(AppIcons.check,
                                  size: 14, color: AppColors.gain),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  'Photo attached · Tap to view full size',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              GestureDetector(
                                onTap: () => onChanged(null),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color:
                                        AppColors.loss.withValues(alpha: 0.8),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(AppIcons.trash,
                                      size: 12, color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.accentSoft,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, size: 20, color: AppColors.accent),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Tap to upload photo',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hint,
                        style:
                            TextStyle(fontSize: 11.5, color: AppColors.muted),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
