import 'package:flutter/material.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/app_modal.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/detail_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'telecom_network.dart';

class _DataPlan {
  const _DataPlan(this.size, this.validity, this.price);
  final String size;
  final String validity;
  final String price;
}

const _dataPlans = [
  _DataPlan('500MB', '30 days', '₦350'),
  _DataPlan('1GB', '30 days', '₦550'),
  _DataPlan('2GB', '30 days', '₦1,000'),
  _DataPlan('5GB', '30 days', '₦2,500'),
  _DataPlan('10GB', '30 days', '₦4,500'),
  _DataPlan('20GB', '30 days', '₦8,000'),
];

/// Data bundle purchase flow: pick a network, enter a number, pick a
/// plan, confirm. Reached from Bills → Data.
class DataScreen extends StatefulWidget {
  const DataScreen({super.key});

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  int _network = 0;
  int? _planIndex;
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  void _buy() {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty || _planIndex == null) {
      showAppModal(
        context,
        icon: AppIcons.warning,
        iconColor: AppColors.warn,
        title: 'Missing details',
        message: 'Enter a phone number and choose a data plan to continue.',
      );
      return;
    }
    final plan = _dataPlans[_planIndex!];
    showAppModal(
      context,
      icon: AppIcons.check,
      iconColor: AppColors.gain,
      title: 'Data purchased',
      message:
          '${plan.size} (${plan.validity}) was sent to $phone on ${kTelecomNetworks[_network].name}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.page,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
          children: [
            const DetailHeader(
                icon: AppIcons.bill,
                title: 'Buy Data',
                subtitle: 'Data bundles for any Nigerian network'),
            const SizedBox(height: 22),
            Text('Network', style: AppText.sectionTitle),
            const SizedBox(height: 10),
            Row(
              children: [
                for (int i = 0; i < kTelecomNetworks.length; i++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                          right: i != kTelecomNetworks.length - 1 ? 8 : 0),
                      child: NetworkTile(
                          network: kTelecomNetworks[i],
                          selected: i == _network,
                          onTap: () => setState(() => _network = i)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 22),
            Text('Phone number', style: AppText.sectionTitle),
            const SizedBox(height: 10),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13.5),
              decoration: InputDecoration(
                hintText: '080X XXX XXXX',
                prefixIcon:
                    Icon(AppIcons.phone, size: 18, color: AppColors.muted),
              ),
            ),
            const SizedBox(height: 22),
            Text('Choose a plan', style: AppText.sectionTitle),
            const SizedBox(height: 10),
            for (int i = 0; i < _dataPlans.length; i++)
              _PlanRow(
                  plan: _dataPlans[i],
                  selected: i == _planIndex,
                  onTap: () => setState(() => _planIndex = i)),
            const SizedBox(height: 12),
            PrimaryButton(
                label: 'Buy data', icon: AppIcons.wifi, onPressed: _buy),
          ],
        ),
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow(
      {required this.plan, required this.selected, required this.onTap});

  final _DataPlan plan;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(plan.size,
                      style: AppText.body.copyWith(
                          color: selected
                              ? AppColors.textPrimary
                              : AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text('Valid for ${plan.validity}', style: AppText.caption),
                ],
              ),
            ),
            Text(plan.price,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color:
                        selected ? AppColors.accent : AppColors.textPrimary)),
            const SizedBox(width: 10),
            Icon(
              selected ? AppIcons.check : AppIcons.chevronRight,
              size: 16,
              color: selected ? AppColors.accent : AppColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}
