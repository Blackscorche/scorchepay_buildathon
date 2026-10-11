import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../app_icons.dart';
import 'app_modal.dart';

/// The outcome of [showPhotoPickerSheet]: either a newly picked file, or
/// an explicit removal. `null` from the function itself means no
/// change — the sheet was dismissed without picking or removing, so the
/// caller should leave whatever photo state it already had alone.
class PhotoPickResult {
  const PhotoPickResult.picked(XFile this.file) : removed = false;
  const PhotoPickResult.removed()
      : file = null,
        removed = true;

  /// The picked image. Works on every platform, web included: read it with
  /// `readAsBytes()` (e.g. to upload it) and show it with
  /// [pickedPhotoImage].
  final XFile? file;
  final bool removed;
}

/// An [ImageProvider] for a picked photo, for previews. On web the
/// [XFile]'s path is a blob URL; elsewhere it's a file on disk.
ImageProvider<Object> pickedPhotoImage(XFile file) {
  if (kIsWeb) return NetworkImage(file.path);
  return FileImage(File(file.path));
}

/// Bottom sheet offering "take photo" / "choose from library" / "remove"
/// — backed by the real device camera and photo library via
/// `image_picker`. [hasPhoto] controls whether "Remove photo" is shown.
Future<PhotoPickResult?> showPhotoPickerSheet(
  BuildContext context, {
  String title = 'Add a photo',
  bool hasPhoto = false,
}) async {
  final action = await showAppSheet<String>(
    context,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppText.detailTitle),
        const SizedBox(height: 14),
        _SheetAction(icon: AppIcons.camera, label: 'Take photo', onTap: () => Navigator.of(ctx).pop('camera')),
        _SheetAction(icon: AppIcons.image, label: 'Choose from library', onTap: () => Navigator.of(ctx).pop('gallery')),
        if (hasPhoto)
          _SheetAction(
            icon: AppIcons.trash,
            label: 'Remove photo',
            destructive: true,
            showDivider: false,
            onTap: () => Navigator.of(ctx).pop('remove'),
          ),
      ],
    ),
  );

  if (action == null) return null;
  if (action == 'remove') return const PhotoPickResult.removed();

  try {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(
      source: action == 'camera' ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (xfile == null) return null;
    return PhotoPickResult.picked(xfile);
  } catch (_) {
    if (!context.mounted) return null;
    await showAppModal(
      context,
      icon: AppIcons.warning,
      title: 'Camera unavailable',
      message: action == 'camera'
          ? "Couldn't access the camera — check that ScorchePay has camera permission in Settings."
          : "Couldn't access your photo library — check permissions in Settings.",
    );
    return null;
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({required this.icon, required this.label, required this.onTap, this.destructive = false, this.showDivider = true});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.loss : AppColors.textPrimary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          border: showDivider ? Border(bottom: BorderSide(color: AppColors.hairline)) : null,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: destructive ? AppColors.statusSoft(AppColors.loss) : AppColors.surface3,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 17, color: color),
            ),
            const SizedBox(width: 12),
            Text(label, style: AppText.body.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}
