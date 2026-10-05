import 'package:flutter/material.dart';
import '../../core/app_icons.dart';
import '../../core/widgets/app_modal.dart';
import '../../core/widgets/buttons.dart';
import '../../core/widgets/detail_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import 'telecom_network.dart';

const _quickAmounts = ['100', '200', '500', '1,000', '2,000', '5,000'];

/// Airtime top-up flow: pick a network, enter a number, choose an
/// amount, confirm. Reached from Bills → Airtime.
class AirtimeScreen extends StatefulWidget {
  const AirtimeScreen({super.key});

  @override
  State<AirtimeScreen> createState() => _AirtimeScreenState();
}

class _AirtimeScreenState extends State<AirtimeScreen> {
  int _network = 0;
  int? _amountIndex;
  final _phoneController = TextEditingController();

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  void _buy() {
    final phone = _phoneController.text.trim();
    if (phone.isEmpty || _amountIndex == null) {
      showAppModal(
        context,
        icon: AppIcons.warning,
        iconColor: AppColors.warn,
        title: 'Missing details',
        message: 'Enter a phone number and choose an amount to continue.',
      );
      return;
    }
    showAppModal(
      context,
      icon: AppIcons.check,
      iconColor: AppColors.gain,
      title: 'Airtime purchased',
      message:
          '₦${_quickAmounts[_amountIndex!]} airtime was sent to $phone on ${kTelecomNetworks[_network].name}.',
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
                title: 'Buy Airtime',
                subtitle: 'Top up any Nigerian network instantly'),
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
            Text('Amount', style: AppText.sectionTitle),
            const SizedBox(height: 10),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                for (int i = 0; i < _quickAmounts.length; i++)
                  _AmountChip(
                      label: '₦${_quickAmounts[i]}',
                      selected: i == _amountIndex,
                      onTap: () => setState(() => _amountIndex = i)),
              ],
            ),
            const SizedBox(height: 28),
            PrimaryButton(
                label: 'Buy airtime', icon: AppIcons.bolt, onPressed: _buy),
          ],
        ),
      ),
    );
  }
}

class _AmountChip extends StatelessWidget {
  const _AmountChip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface2,
          border: Border.all(
              color: selected
                  ? AppColors.accent.withValues(alpha: 0.5)
                  : AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? AppColors.accent : AppColors.textSecondary),
        ),
      ),
    );
  }
}
