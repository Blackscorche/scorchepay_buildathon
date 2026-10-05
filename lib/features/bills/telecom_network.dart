import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// A mobile network option shared by the airtime and data purchase
/// screens, so the two flows stay visually and behaviorally identical.
class TelecomNetwork {
  const TelecomNetwork(this.name, this.color);
  final String name;
  final Color color;
}

const kTelecomNetworks = [
  TelecomNetwork('MTN', Color(0xFFFFCC08)),
  TelecomNetwork('Airtel', Color(0xFFFF3B30)),
  TelecomNetwork('Glo', Color(0xFF00A651)),
  TelecomNetwork('9mobile', Color(0xFF00A99D)),
];

class NetworkTile extends StatelessWidget {
  const NetworkTile(
      {super.key,
      required this.network,
      required this.selected,
      required this.onTap});

  final TelecomNetwork network;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.surface3 : AppColors.surface2,
          border: Border.all(
              color: selected
                  ? network.color.withValues(alpha: 0.55)
                  : AppColors.border),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration:
                  BoxDecoration(color: network.color, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text(
                network.name[0],
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Colors.black87),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              network.name,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
